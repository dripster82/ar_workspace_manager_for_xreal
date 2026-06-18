import Foundation
import Security
import SwiftUI

enum GitHubState: Equatable {
    case disconnected
    case connecting
    case connected(login: String)
    case error(String)
}

/// The five PR-triage counts shown by the GitHub widget.
struct GitHubCounts: Equatable {
    var needsReview = 0       // review requested directly from you
    var teamReview = 0        // review requested via a team you're on
    var changesRequested = 0  // your open PRs a reviewer asked changes on
    var failingChecks = 0     // your open PRs with failing CI
    var readyToMerge = 0      // your open PRs approved + checks passing
}

private enum GHError: Error { case unauthorized; case api(String) }

/// Minimal Keychain string store for the GitHub token.
private enum GHKeychain {
    private static let service = "VRDesktop.GitHub"
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

/// Polls the GitHub Search API for PR-triage counts. Auth is a personal access token (classic:
/// `repo` scope for private repos) entered by the user and stored in the Keychain.
@MainActor
final class GitHubService: ObservableObject {
    @Published private(set) var state: GitHubState = .disconnected
    @Published private(set) var counts = GitHubCounts()
    @Published private(set) var nextRefreshAt: Date?
    @Published var pollSeconds: Int = UserDefaults.standard.object(forKey: "githubPollSeconds") as? Int ?? 60 {
        didSet {
            UserDefaults.standard.set(pollSeconds, forKey: "githubPollSeconds")
            if pollTimer != nil { stopPolling(); startPolling() }
        }
    }
    static let pollOptions: [(label: String, seconds: Int)] = [
        ("30s", 30), ("1 min", 60), ("2 min", 120), ("5 min", 300),
    ]

    private let session = URLSession(configuration: .ephemeral)
    private var pollTimer: Timer?
    private var refreshing = false

    /// GitHub org to scope every query to; blank = all repos the token can see.
    var org: String {
        get { UserDefaults.standard.string(forKey: "githubOrg") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "githubOrg") }
    }
    var token: String {
        get { GHKeychain.get("token") ?? "" }
        set { GHKeychain.set(newValue.isEmpty ? nil : newValue, for: "token") }
    }
    var isConnected: Bool { if case .connected = state { return true } else { return false } }

    init() {
        if !token.isEmpty {
            state = .connecting
            Task { await connect() }
        }
    }

    // MARK: Connect / disconnect

    func connect() {
        Task {
            guard !token.isEmpty else { state = .error("Enter a personal access token."); return }
            state = .connecting
            do {
                let login = try await currentLogin()
                state = .connected(login: login)
                startPolling()
            } catch GHError.unauthorized {
                state = .error("Token rejected — check it has repo scope.")
            } catch {
                state = .error("Connect failed: \(error.localizedDescription)")
            }
        }
    }

    func disconnect() {
        token = ""
        stopPolling()
        counts = GitHubCounts()
        state = .disconnected
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
        guard case .connected = state, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            // Ignore PRs not touched in the last month, and omit sort:updated-desc (a UI-only sort,
            // not a REST search qualifier — it doesn't affect total_count).
            let fresh = "updated:>=\(Self.oneMonthAgo())"
            let needsReview = try await searchCount("is:pr user-review-requested:@me state:open archived:false \(fresh)")
            let teamReview = try await searchCount("is:pr team-review-requested-user:@me state:open archived:false \(fresh)")
            let changes = try await searchCount("is:pr author:@me state:open review:changes_requested archived:false -is:draft \(fresh)")
            let failing = try await searchCount("is:pr author:@me state:open status:failure archived:false -is:draft \(fresh)")
            let ready = try await searchCount("is:pr author:@me state:open -is:draft review:approved -review:changes_requested -status:failure -is:queued archived:false \(fresh)")
            counts = GitHubCounts(needsReview: needsReview, teamReview: teamReview,
                                  changesRequested: changes, failingChecks: failing, readyToMerge: ready)
        } catch GHError.unauthorized {
            state = .error("Token expired — reconnect.")
            stopPolling()
        } catch {
            DebugLog.shared.log("github refresh error: \(error.localizedDescription)")
        }
    }

    // MARK: API

    private func currentLogin() async throws -> String {
        let data = try await get("/user")
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let login = json?["login"] as? String else { throw GHError.api("no login") }
        return login
    }

    /// Date a month ago as YYYY-MM-DD (UTC), for `updated:>=` filtering.
    private static func oneMonthAgo() -> String {
        let cutoff = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt.string(from: cutoff)
    }

    private func searchCount(_ query: String) async throws -> Int {
        let full = org.isEmpty ? query : "\(query) org:\(org)"
        let encoded = full.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let data = try await get("/search/issues?q=\(encoded)&per_page=1")
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["total_count"] as? Int) ?? 0
    }

    private func get(_ path: String) async throws -> Data {
        var req = URLRequest(url: URL(string: "https://api.github.com\(path)")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse {
            if http.statusCode == 401 || http.statusCode == 403 { throw GHError.unauthorized }
            guard (200..<300).contains(http.statusCode) else { throw GHError.api("HTTP \(http.statusCode)") }
        }
        return data
    }
}
