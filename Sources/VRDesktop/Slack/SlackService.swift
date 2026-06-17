import Foundation
import SwiftUI

enum SlackConnState: Equatable {
    case disconnected
    case connecting
    case connected(user: String)
    case error(String)
}

/// One unread conversation for the Slack widget (a person DM or a starred channel).
struct SlackUnread: Identifiable, Equatable {
    let id: String
    let name: String
    let count: Int
    let isChannel: Bool
}

private enum SlackError: Error, LocalizedError {
    case api(String)
    var errorDescription: String? { if case .api(let m) = self { return m } else { return nil } }
}

/// Owns Slack auth (clean OAuth user token) and polls per-conversation unread counts for the
/// widget: DMs with unread + starred channels with unread. Uses official methods only.
@MainActor
final class SlackService: ObservableObject {
    @Published private(set) var state: SlackConnState = .disconnected
    @Published private(set) var unreads: [SlackUnread] = []
    /// Poll interval in seconds; persisted. Restarts the timer live when changed.
    @Published var pollSeconds: Int = UserDefaults.standard.object(forKey: "slackPollSeconds") as? Int ?? 30 {
        didSet {
            UserDefaults.standard.set(pollSeconds, forKey: "slackPollSeconds")
            if pollTimer != nil { stopPolling(); startPolling() }
        }
    }
    static let pollOptions: [(label: String, seconds: Int)] = [
        ("10s", 10), ("15s", 15), ("30s", 30), ("1 min", 60), ("2 min", 120), ("5 min", 300),
    ]

    static let redirectPort: UInt16 = 53682
    static var redirectURI: String { "http://localhost:\(redirectPort)/oauth/callback" }
    static let scopes = "channels:read,groups:read,im:read,mpim:read,users:read"

    /// When the next poll tick is scheduled — drives the widget's "next update" countdown.
    @Published private(set) var nextRefreshAt: Date?

    private var pollTimer: Timer?
    private var userNameCache: [String: String] = [:]
    private let session = URLSession(configuration: .ephemeral)
    private var refreshing = false
    /// Last-seen `updated` (last-activity) timestamp per conversation, so we only re-check ones
    /// that changed. Avoids re-scanning all ~80 conversations every poll (which hit the rate limit).
    private var seenUpdated: [String: Double] = [:]
    /// Current unread per conversation, kept across polls; only re-checked conversations are updated.
    private var unreadByID: [String: SlackUnread] = [:]
    /// Cap on conversations probed for unread per sweep (recent-activity first) — keeps under limits.
    private let maxScanPerSweep = 25

    // MARK: Stored credentials

    var clientID: String {
        get { UserDefaults.standard.string(forKey: "slackClientID") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "slackClientID") }
    }
    var clientSecret: String {
        get { SlackKeychain.get("clientSecret") ?? "" }
        set { SlackKeychain.set(newValue.isEmpty ? nil : newValue, for: "clientSecret") }
    }
    private var token: String? { SlackKeychain.get("userToken") }

    var isConnected: Bool { if case .connected = state { return true } else { return false } }

    init() {
        if token != nil {
            state = .connected(user: UserDefaults.standard.string(forKey: "slackUser") ?? "Slack")
            startPolling()
        }
    }

    // MARK: Connect / disconnect

    func connect() { Task { await runConnect() } }

    func disconnect() {
        SlackKeychain.set(nil, for: "userToken")
        UserDefaults.standard.removeObject(forKey: "slackUser")
        stopPolling()
        unreads = []
        state = .disconnected
    }

    private func runConnect() async {
        guard !clientID.isEmpty, !clientSecret.isEmpty else {
            state = .error("Enter Client ID and Secret first."); return
        }
        state = .connecting
        let csrf = UUID().uuidString
        var comps = URLComponents(string: "https://slack.com/oauth/v2/authorize")!
        comps.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "user_scope", value: Self.scopes),
            .init(name: "redirect_uri", value: Self.redirectURI),
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
            "client_id": clientID,
            "client_secret": clientSecret,
            "code": code,
            "redirect_uri": Self.redirectURI,
        ]
        var req = URLRequest(url: URL(string: "https://slack.com/api/oauth.v2.access")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form.map { "\($0)=\($1.addingPercentEncoding(withAllowedCharacters: .formValueAllowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        let (data, _) = try await session.data(for: req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (json?["ok"] as? Bool) == true,
              let authed = json?["authed_user"] as? [String: Any],
              let accessToken = authed["access_token"] as? String else {
            throw SlackError.api((json?["error"] as? String) ?? "OAuth exchange failed")
        }
        SlackKeychain.set(accessToken, for: "userToken")
        let userID = authed["id"] as? String
        let name = await resolveUserName(userID, token: accessToken) ?? "Slack"
        UserDefaults.standard.set(name, forKey: "slackUser")
        state = .connected(user: name)
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
        guard let token, !refreshing else { return }   // never overlap sweeps
        refreshing = true
        defer { refreshing = false }
        do {
            let convos = try await listConversations(token: token)
            // conversations.info only returns unread counts for DMs (is_im) — channels/mpims come
            // back with no unread fields under these scopes — so we only scan DMs. Probe the
            // most-recently-active DMs whose activity changed since we last looked, plus any we
            // currently show as unread (to catch reads). Keeps each sweep to a few calls, not ~80.
            let dms = convos.filter { $0.isIM }
            let recent = dms.sorted { $0.updated > $1.updated }.prefix(maxScanPerSweep)
            var candidates: [Convo] = recent.filter { $0.updated > (seenUpdated[$0.id] ?? -1) }
            let candidateIDs = Set(candidates.map { $0.id })
            candidates += dms.filter { unreadByID[$0.id] != nil && !candidateIDs.contains($0.id) }
            DebugLog.shared.log("slack refresh: \(dms.count) DMs, probing \(candidates.count)")

            for c in candidates {
                guard let info = try await conversationInfo(id: c.id, token: token) else { continue }
                seenUpdated[c.id] = c.updated
                if info.unread > 0 {
                    let name = await resolveUserName(c.userID, token: token) ?? "Direct message"
                    unreadByID[c.id] = SlackUnread(id: c.id, name: name, count: info.unread, isChannel: false)
                } else {
                    unreadByID[c.id] = nil
                }
                try? await Task.sleep(nanoseconds: 1_200_000_000) // ~1.2s spacing → stay under ~50/min
            }
            unreads = unreadByID.values.sorted { $0.count > $1.count }
        } catch SlackError.api(let msg) where msg == "invalid_auth" || msg == "token_revoked" || msg == "account_inactive" {
            state = .error("Slack token expired — reconnect.")
            stopPolling()
        } catch {
            DebugLog.shared.log("slack refresh error: \(error.localizedDescription)")
        }
    }

    // MARK: API

    private struct Convo { let id: String; let isIM: Bool; let name: String?; let userID: String?; let updated: Double }
    private struct Info { let unread: Int; let name: String?; let isStarred: Bool }

    private func listConversations(token: String) async throws -> [Convo] {
        let json = try await call("users.conversations", token: token, query: [
            "types": "im,mpim,public_channel,private_channel",
            "exclude_archived": "true",
            "limit": "500",
        ])
        let channels = json["channels"] as? [[String: Any]] ?? []
        return channels.map { ch in
            Convo(id: ch["id"] as? String ?? "",
                  isIM: (ch["is_im"] as? Bool) ?? false,
                  name: ch["name"] as? String,
                  userID: ch["user"] as? String,
                  updated: (ch["updated"] as? Double) ?? 0)
        }.filter { !$0.id.isEmpty }
    }

    private func conversationInfo(id: String, token: String) async throws -> Info? {
        let json = try await call("conversations.info", token: token, query: ["channel": id])
        guard let ch = json["channel"] as? [String: Any] else { return nil }
        let unread = (ch["unread_count_display"] as? Int) ?? (ch["unread_count"] as? Int) ?? 0
        return Info(unread: unread, name: ch["name"] as? String, isStarred: (ch["is_starred"] as? Bool) ?? false)
    }

    private func resolveUserName(_ userID: String?, token: String) async -> String? {
        guard let userID else { return nil }
        if let cached = userNameCache[userID] { return cached }
        guard let json = try? await call("users.info", token: token, query: ["user": userID]),
              let user = json["user"] as? [String: Any] else { return nil }
        let profile = user["profile"] as? [String: Any]
        let name = (profile?["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (user["real_name"] as? String)
            ?? (user["name"] as? String)
        if let name { userNameCache[userID] = name }
        return name
    }

    /// GET a Slack Web API method with the bearer token; throws SlackError.api on `ok:false`.
    private func call(_ method: String, token: String, query: [String: String]) async throws -> [String: Any] {
        var comps = URLComponents(string: "https://slack.com/api/\(method)")!
        comps.queryItems = query.map { URLQueryItem(name: $0, value: $1) }
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        for _ in 0..<3 {
            let (data, resp) = try await session.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode == 429 {
                let retry = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 3
                try await Task.sleep(nanoseconds: UInt64((retry + 0.5) * 1_000_000_000))
                continue   // back off and retry, don't abort the sweep
            }
            let json = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
            guard (json["ok"] as? Bool) == true else {
                throw SlackError.api((json["error"] as? String) ?? "request failed")
            }
            return json
        }
        throw SlackError.api("ratelimited")
    }
}
