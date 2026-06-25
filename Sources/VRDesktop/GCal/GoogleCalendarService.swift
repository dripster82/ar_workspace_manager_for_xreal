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

/// Calendar secret (iCal URL), stored in the shared single-item SecretStore (keys prefixed "gcal.").
private enum GCalKeychain {
    static func set(_ value: String?, for key: String) { SecretStore.set("gcal.\(key)", value) }
    static func get(_ key: String) -> String? { SecretStore.get("gcal.\(key)") }
}

/// Reads a Google Calendar via its private iCal (.ics) URL — no Google Cloud project or OAuth.
/// The secret URL is stored in the Keychain; events (incl. expanded recurrences) are polled.
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

    // MARK: Meeting alarms
    static let leadOptions: [(label: String, minutes: Int)] = [
        ("Off", -1), ("At time", 0), ("5 min before", 5), ("10 min before", 10), ("15 min before", 15),
        ("30 min before", 30), ("1 hr before", 60), ("2 hrs before", 120), ("1 day before", 1440),
    ]
    @Published var alarmsEnabled: Bool = UserDefaults.standard.bool(forKey: "gcalAlarmsEnabled") {
        didSet { UserDefaults.standard.set(alarmsEnabled, forKey: "gcalAlarmsEnabled") }
    }
    /// Meeting alarms are gated behind a running AR session by default (they show in the glasses).
    /// Turn this on to let them still fire — as a centred desktop panel + tone — when AR is off.
    @Published var allowAlarmsWhenAROff: Bool = UserDefaults.standard.bool(forKey: "gcalAlarmsWhenAROff") {
        didSet { UserDefaults.standard.set(allowAlarmsWhenAROff, forKey: "gcalAlarmsWhenAROff") }
    }
    @Published var alarm1Lead: Int = UserDefaults.standard.object(forKey: "gcalAlarm1") as? Int ?? 5 {
        didSet { UserDefaults.standard.set(alarm1Lead, forKey: "gcalAlarm1") }
    }
    @Published var alarm2Lead: Int = UserDefaults.standard.object(forKey: "gcalAlarm2") as? Int ?? -1 {
        didSet { UserDefaults.standard.set(alarm2Lead, forKey: "gcalAlarm2") }
    }
    /// Called when a meeting alarm becomes due: (event, lead minutes).
    var onAlarm: ((CalEvent, Int) -> Void)?
    private var firedAlarms: Set<String> = []
    private var alarmTimer: Timer?

    /// Fire any alarms whose time has just arrived (checked frequently; tolerant window so a coarse
    /// tick never misses one, de-duplicated per event+lead).
    private func checkAlarms() {
        guard alarmsEnabled, let onAlarm else { return }
        let now = Date()
        // Drop fired keys for events no longer in the window so the set doesn't grow unbounded.
        let liveKeys = Set(events.flatMap { e in [alarm1Lead, alarm2Lead].map { "\(e.id)#\($0)" } })
        firedAlarms.formIntersection(liveKeys)
        for event in events {
            for lead in [alarm1Lead, alarm2Lead] where lead >= 0 {
                let at = event.start.addingTimeInterval(-Double(lead * 60))
                let key = "\(event.id)#\(lead)"
                if now >= at, now < at.addingTimeInterval(120), !firedAlarms.contains(key) {
                    firedAlarms.insert(key)
                    DebugLog.shared.log("gcal alarm: '\(event.title)' lead=\(lead)min start=\(event.start)")
                    onAlarm(event, lead)
                }
            }
        }
    }

    private let session = URLSession(configuration: .ephemeral)
    private var pollTimer: Timer?
    private var refreshing = false

    /// The secret iCal URL (contains a private token) — stored in the Keychain.
    var icalURL: String {
        get { GCalKeychain.get("icalURL") ?? "" }
        set { GCalKeychain.set(newValue.isEmpty ? nil : newValue, for: "icalURL") }
    }
    var isConnected: Bool { if case .connected = state { return true } else { return false } }

    init() {
        if !icalURL.isEmpty {
            state = .connected(account: UserDefaults.standard.string(forKey: "gcalAccount") ?? "Calendar")
            startPolling()
        }
        // Frequent alarm check (independent of the slow event poll).
        let at = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAlarms() }
        }
        RunLoop.main.add(at, forMode: .common)
        alarmTimer = at
    }

    func connect() {
        Task {
            guard let url = URL(string: icalURL.trimmingCharacters(in: .whitespacesAndNewlines)),
                  url.scheme == "https" || url.scheme == "http" || url.scheme == "webcal" else {
                state = .error("Enter a valid iCal URL."); return
            }
            state = .connecting
            await refresh()
            if case .connecting = state { state = .connected(account: "Calendar") }
            startPolling()
        }
    }

    func disconnect() {
        icalURL = ""
        UserDefaults.standard.removeObject(forKey: "gcalAccount")
        stopPolling()
        events = []
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
        guard !icalURL.isEmpty, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        // webcal:// is just https for fetching.
        let urlStr = icalURL.replacingOccurrences(of: "webcal://", with: "https://")
        guard let url = URL(string: urlStr.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            state = .error("Invalid iCal URL."); return
        }
        do {
            let (data, resp) = try await session.data(from: url)
            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                state = .error("Feed error (HTTP \(http.statusCode)).")
                return
            }
            guard let text = String(data: data, encoding: .utf8) else { state = .error("Bad feed encoding."); return }
            let now = Date()
            events = ICS.parseEvents(text, windowStart: now, windowEnd: now.addingTimeInterval(7 * 86400))
            let n = events.count, bytes = data.count
            DebugLog.shared.log("gcal: feed \(bytes)B, parsed \(n) upcoming events")
            let name = ICS.calendarName(text) ?? "Calendar"
            UserDefaults.standard.set(name, forKey: "gcalAccount")
            state = .connected(account: name)
        } catch {
            DebugLog.shared.log("gcal refresh error: \(error.localizedDescription)")
            state = .error("Couldn't load the calendar feed.")
        }
    }
}
