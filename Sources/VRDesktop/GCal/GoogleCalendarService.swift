import Foundation
import Security
import SwiftUI

enum GCalState: Equatable {
    case disconnected
    case connecting
    case connected(account: String)
    case error(String)
}

/// One upcoming calendar event for the widget.
struct CalEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
}

private enum GCalError: Error { case notAuthed; case api(String) }

private enum GCalKeychain {
    private static let service = "VRDesktop.GoogleCalendar"
    static func set(_ value: String?, for key: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        var add = base; add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }
    static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: key,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
}

/// Google Calendar OAuth (user-entered Desktop-app credentials) + polling of upcoming events.
@MainActor
final class GoogleCalendarService: ObservableObject {
    @Published private(set) var state: GCalState = .disconnected
    @Published private(set) var events: [CalEvent] = []
    @Published private(set) var nextRefreshAt: Date?
    @Published var pollSeconds: Int = UserDefaults.standard.object(forKey: "gcalPollSeconds") as? Int ?? 300 {
        didSet {
            UserDefaults.standard.set(pollSeconds, forKey: "gcalPollSeconds")
            if pollTimer != nil { stopPolling(); startPolling() }
        }
    }
    static let pollOptions: [(label: String, seconds: Int)] = [
        ("1 min", 60), ("5 min", 300), ("15 min", 900), ("30 min", 1800),
    ]

    static let redirectPort: UInt16 = 53684
    static var redirectURI: String { "http://localhost:\(redirectPort)/oauth/callback" }
    static let scope = "https://www.googleapis.com/auth/calendar.events.readonly"

    private let session = URLSession(configuration: .ephemeral)
    private var pollTimer: Timer?
    private var refreshing = false

    // Credentials & tokens
    var clientID: String {
        get { UserDefaults.standard.string(forKey: "gcalClientID") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "gcalClientID") }
    }
    var clientSecret: String {
        get { GCalKeychain.get("clientSecret") ?? "" }
        set { GCalKeychain.set(newValue.isEmpty ? nil : newValue, for: "clientSecret") }
    }
    private var refreshToken: String? { GCalKeychain.get("refreshToken") }
    private var accessToken: String? { GCalKeychain.get("accessToken") }
    private var accessExpiry: Date {
        Date(timeIntervalSinceReferenceDate: UserDefaults.standard.double(forKey: "gcalAccessExpiry"))
    }

    var isConnected: Bool { if case .connected = state { return true } else { return false } }

    init() {
        if refreshToken != nil {
            state = .connected(account: UserDefaults.standard.string(forKey: "gcalAccount") ?? "Calendar")
            startPolling()
        }
    }

    // MARK: Connect / disconnect

    func connect() { Task { await runConnect() } }

    func disconnect() {
        GCalKeychain.set(nil, for: "refreshToken")
        GCalKeychain.set(nil, for: "accessToken")
        UserDefaults.standard.removeObject(forKey: "gcalAccount")
        stopPolling()
        events = []
        state = .disconnected
    }

    private func runConnect() async {
        guard !clientID.isEmpty, !clientSecret.isEmpty else {
            state = .error("Enter Client ID and Secret first."); return
        }
        state = .connecting
        let csrf = UUID().uuidString
        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Self.scope),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
            .init(name: "state", value: csrf),
        ]
        guard let authURL = comps.url else { state = .error("Bad authorize URL"); return }
        do {
            let params = try await LoopbackOAuth().authorize(authURL, port: Self.redirectPort)
            guard params["state"] == csrf, let code = params["code"] else {
                state = .error(params["error"] ?? "Sign-in cancelled."); return
            }
            try await exchange(code: code)
            startPolling()
            await refresh()
        } catch {
            state = .error("Connect failed: \(error.localizedDescription)")
        }
    }

    private func exchange(code: String) async throws {
        let form = [
            "code": code, "client_id": clientID, "client_secret": clientSecret,
            "redirect_uri": Self.redirectURI, "grant_type": "authorization_code",
        ]
        let json = try await postToken(form)
        guard let access = json["access_token"] as? String else { throw GCalError.api("no access token") }
        GCalKeychain.set(access, for: "accessToken")
        if let refresh = json["refresh_token"] as? String { GCalKeychain.set(refresh, for: "refreshToken") }
        storeExpiry(json["expires_in"] as? Double ?? 3600)
        let account = (try? await primaryCalendarSummary(token: access)) ?? "Calendar"
        UserDefaults.standard.set(account, forKey: "gcalAccount")
        state = .connected(account: account)
    }

    private func storeExpiry(_ seconds: Double) {
        UserDefaults.standard.set(Date().addingTimeInterval(seconds).timeIntervalSinceReferenceDate,
                                  forKey: "gcalAccessExpiry")
    }

    /// A valid access token, refreshing via the refresh token if the current one is near expiry.
    private func validAccessToken() async throws -> String {
        if let access = accessToken, Date() < accessExpiry.addingTimeInterval(-60) { return access }
        guard let refresh = refreshToken else { throw GCalError.notAuthed }
        let json = try await postToken([
            "client_id": clientID, "client_secret": clientSecret,
            "refresh_token": refresh, "grant_type": "refresh_token",
        ])
        guard let access = json["access_token"] as? String else { throw GCalError.api("refresh failed") }
        GCalKeychain.set(access, for: "accessToken")
        storeExpiry(json["expires_in"] as? Double ?? 3600)
        return access
    }

    // MARK: Polling

    func startPolling() {
        guard pollTimer == nil else { return }
        scheduleNext()
        let t = Timer(timeInterval: TimeInterval(pollSeconds), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scheduleNext(); await self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
        Task { await refresh() }
    }

    func stopPolling() { pollTimer?.invalidate(); pollTimer = nil; nextRefreshAt = nil }

    private func scheduleNext() { nextRefreshAt = Date().addingTimeInterval(TimeInterval(pollSeconds)) }

    private func refresh() async {
        guard refreshToken != nil, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let token = try await validAccessToken()
            events = try await fetchUpcoming(token: token)
        } catch GCalError.notAuthed {
            state = .error("Sign-in expired — reconnect."); stopPolling()
        } catch {
            DebugLog.shared.log("gcal refresh error: \(error.localizedDescription)")
        }
    }

    // MARK: API

    private func postToken(_ form: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form.map { "\($0)=\($1.addingPercentEncoding(withAllowedCharacters: .formValueAllowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        let (data, _) = try await session.data(for: req)
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw GCalError.api("bad token response")
        }
        if let err = json["error"] as? String { throw GCalError.api(err) }
        return json
    }

    private func primaryCalendarSummary(token: String) async throws -> String {
        let data = try await apiGet("https://www.googleapis.com/calendar/v3/calendars/primary", token: token)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["summary"] as? String) ?? "Calendar"
    }

    private func fetchUpcoming(token: String) async throws -> [CalEvent] {
        let now = ISO8601DateFormatter().string(from: Date())
        let timeMax = ISO8601DateFormatter().string(from: Date().addingTimeInterval(7 * 86400))
        var comps = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
        comps.queryItems = [
            .init(name: "timeMin", value: now),
            .init(name: "timeMax", value: timeMax),
            .init(name: "singleEvents", value: "true"),
            .init(name: "orderBy", value: "startTime"),
            .init(name: "maxResults", value: "10"),
        ]
        let data = try await apiGet(comps.url!.absoluteString, token: token)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let items = json?["items"] as? [[String: Any]] ?? []
        let iso = ISO8601DateFormatter()
        let dayFmt = DateFormatter(); dayFmt.dateFormat = "yyyy-MM-dd"
        return items.compactMap { item -> CalEvent? in
            guard let id = item["id"] as? String else { return nil }
            let title = (item["summary"] as? String) ?? "(no title)"
            let startObj = item["start"] as? [String: Any]
            let endObj = item["end"] as? [String: Any]
            if let dt = startObj?["dateTime"] as? String, let start = iso.date(from: dt) {
                let end = (endObj?["dateTime"] as? String).flatMap(iso.date(from:)) ?? start
                return CalEvent(id: id, title: title, start: start, end: end, allDay: false)
            }
            if let d = startObj?["date"] as? String, let start = dayFmt.date(from: d) {
                let end = (endObj?["date"] as? String).flatMap(dayFmt.date(from:)) ?? start
                return CalEvent(id: id, title: title, start: start, end: end, allDay: true)
            }
            return nil
        }
    }

    private func apiGet(_ urlString: String, token: String) async throws -> Data {
        var req = URLRequest(url: URL(string: urlString)!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode == 401 { throw GCalError.notAuthed }
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw GCalError.api("HTTP \(http.statusCode)")
        }
        return data
    }
}
