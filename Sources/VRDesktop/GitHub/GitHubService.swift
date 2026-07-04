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

private enum GHError: Error {
    case unauthorized                 // 401 — credentials actually bad/expired
    case rateLimited(until: Date?)    // 403/429 from rate limiting — NOT an auth failure
    case api(String)
}

/// GitHub token, stored in the shared single-item SecretStore (keys prefixed "github.").
private enum GHKeychain {
    static func set(_ value: String?, for key: String) { SecretStore.set("github.\(key)", value) }
    static func get(_ key: String) -> String? { SecretStore.get("github.\(key)") }
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

    /// Editable search queries, one per row. `{fresh}` expands to `updated:>=<one month ago>`;
    /// the Org field is appended automatically. Defaults match the verified GitHub queries.
    static let queryDefs: [(key: String, label: String, def: String)] = [
        ("needsReview", "Needs your review", "is:pr user-review-requested:@me state:open archived:false {fresh}"),
        ("teamReview", "Team review", "is:pr review-requested:@me -user-review-requested:@me state:open -is:draft archived:false {fresh}"),
        ("changesRequested", "Changes requested", "is:pr author:@me state:open review:changes_requested archived:false -is:draft {fresh}"),
        ("failingChecks", "Failing checks", "is:pr author:@me state:open status:failure archived:false -is:draft {fresh}"),
        ("readyToMerge", "Ready to merge", "is:pr author:@me state:open -is:draft review:approved -review:changes_requested -status:failure -is:queued archived:false {fresh}"),
    ]
    func query(_ key: String) -> String {
        UserDefaults.standard.string(forKey: "ghQ_\(key)") ?? Self.queryDefs.first { $0.key == key }?.def ?? ""
    }
    func setQuery(_ key: String, _ value: String) {
        UserDefaults.standard.set(value, forKey: "ghQ_\(key)"); objectWillChange.send()
    }
    func resetQueries() {
        Self.queryDefs.forEach { UserDefaults.standard.removeObject(forKey: "ghQ_\($0.key)") }
        objectWillChange.send()
    }

    private let session = URLSession(configuration: .ephemeral)
    private var pollTimer: Timer?
    private var refreshing = false
    /// When rate-limited, skip refreshes until this time instead of disconnecting. nil = not limited.
    private var rateLimitedUntil: Date?

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
                if GoogleCalendarService.isNetworkDown(error) {
                    // Launch races the Wi-Fi at login: a saved token's connect failed once and
                    // polling never started, so the failure looked permanent. Keep retrying
                    // every 20s until the network is back.
                    state = .error("Waiting for the network — retrying…")
                    scheduleConnectRetry()
                } else {
                    state = .error("Connect failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private var connectRetryPending = false
    private func scheduleConnectRetry() {
        guard !connectRetryPending else { return }
        connectRetryPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self else { return }
            self.connectRetryPending = false
            guard !self.token.isEmpty else { return }
            // Connect never succeeded → retry the connect; a mid-session network blip while
            // connected → just refresh early. User disconnect (.disconnected) ends the loop.
            if case .error = self.state { self.connect() }
            else if self.isConnected { self.refreshNow() }
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

    /// Manual "refresh now" trigger.
    func refreshNow() { scheduleNext(); Task { await refresh() } }

    private func scheduleNext() { nextRefreshAt = Date().addingTimeInterval(TimeInterval(pollSeconds)) }

    private func refresh() async {
        guard case .connected = state, !refreshing else { return }
        // Backing off after a rate-limit: stay connected, just skip until the limit resets.
        if let until = rateLimitedUntil {
            if Date() < until { return }
            rateLimitedUntil = nil
        }
        refreshing = true
        defer { refreshing = false }
        do {
            // {fresh} → ignore PRs not touched in the last month. Queries are user-editable.
            let fresh = "updated:>=\(Self.oneMonthAgo())"
            func run(_ key: String) async throws -> Int {
                try await searchCount(query(key).replacingOccurrences(of: "{fresh}", with: fresh))
            }
            // Run the Search queries serially with a small gap. The Search API has a strict secondary
            // rate limit that a back-to-back burst of 5 trips (returning 403), so we space them out.
            let needsReview = try await run("needsReview");              await Self.spaceRequests()
            let teamReview = try await run("teamReview");                await Self.spaceRequests()
            let changesRequested = try await run("changesRequested");    await Self.spaceRequests()
            let failingChecks = try await run("failingChecks");          await Self.spaceRequests()
            let readyToMerge = try await run("readyToMerge")
            counts = GitHubCounts(needsReview: needsReview, teamReview: teamReview,
                                  changesRequested: changesRequested, failingChecks: failingChecks,
                                  readyToMerge: readyToMerge)
        } catch GHError.unauthorized {
            // Only a real 401 means the token is bad/expired.
            state = .error("Token expired — reconnect.")
            stopPolling()
        } catch GHError.rateLimited(let until) {
            // 403/429 rate limiting is NOT an auth failure — stay connected and back off.
            rateLimitedUntil = until ?? Date().addingTimeInterval(60)
            DebugLog.shared.log("github: rate-limited, backing off until \(self.rateLimitedUntil.map { "\($0)" } ?? "?") (staying connected)")
        } catch {
            DebugLog.shared.log("github refresh error: \(error.localizedDescription)")
            if GoogleCalendarService.isNetworkDown(error) { scheduleConnectRetry() }
        }
    }

    /// Small spacer between Search calls to stay under GitHub's secondary rate limit.
    private static func spaceRequests() async { try? await Task.sleep(nanoseconds: 350_000_000) }

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
            switch http.statusCode {
            case 200..<300:
                break
            case 401:
                throw GHError.unauthorized                 // credentials genuinely bad/expired
            case 403, 429:
                // GitHub uses 403/429 for rate limiting, NOT (usually) auth. Only call it an auth
                // failure if it's clearly not a rate limit; otherwise surface a back-off time.
                let remaining = http.value(forHTTPHeaderField: "X-RateLimit-Remaining")
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                let reset = http.value(forHTTPHeaderField: "X-RateLimit-Reset")
                let body = (String(data: data, encoding: .utf8) ?? "").lowercased()
                let isRateLimit = http.statusCode == 429 || remaining == "0" || retryAfter != nil
                    || body.contains("rate limit") || body.contains("secondary rate")
                if isRateLimit {
                    let until: Date?
                    if let s = retryAfter, let secs = Double(s) { until = Date().addingTimeInterval(secs) }
                    else if let s = reset, let epoch = Double(s) { until = Date(timeIntervalSince1970: epoch) }
                    else { until = nil }
                    throw GHError.rateLimited(until: until)
                }
                // A genuine 403 (e.g. token lacks a needed scope) — not expiry, surface as an API error.
                throw GHError.api("HTTP 403 (forbidden — check the token's scopes)")
            default:
                throw GHError.api("HTTP \(http.statusCode)")
            }
        }
        return data
    }
}
