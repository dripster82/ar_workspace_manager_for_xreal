import Foundation
import EventKit
import DisplayManager

/// Reads (and writes completion back to) Apple Reminders via EventKit for the List HUD widget.
/// Owns its own `EKEventStore`; access is gated by the Reminders TCC permission + the
/// `NSRemindersFullAccessUsageDescription` Info.plist string (no entitlement needed). Live updates
/// arrive via `.EKEventStoreChanged` rather than a poll timer.
@MainActor
final class RemindersService: ObservableObject {
    enum RemindersAuth { case notDetermined, denied, restricted, authorized }

    /// A user-visible Reminders list (an `EKCalendar` of type `.reminder`).
    struct ReminderList: Identifiable, Equatable {
        let id: String      // EKCalendar.calendarIdentifier
        let title: String
    }

    @Published private(set) var auth: RemindersAuth = .notDetermined
    @Published private(set) var lists: [ReminderList] = []
    /// Items keyed by reminder-list id (`EKCalendar.calendarIdentifier`).
    @Published private(set) var itemsByList: [String: [ListItem]] = [:]

    private let store = EKEventStore()
    /// Live `EKReminder` objects keyed by `calendarItemIdentifier` so write-back finds the original.
    private var reminderObjectsByID: [String: EKReminder] = [:]
    private var observing = false

    var isConnected: Bool { auth == .authorized }

    init() {
        auth = Self.map(EKEventStore.authorizationStatus(for: .reminder))
        if auth == .authorized {
            subscribeChanges()
            refreshAll()
        }
    }

    private static func map(_ status: EKAuthorizationStatus) -> RemindersAuth {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .fullAccess: return .authorized
        default: return .denied
        }
    }

    /// Prompt for (or re-check) full access. On grant, start observing changes and load lists/items.
    func requestAccess() {
        store.requestFullAccessToReminders { [weak self] _, error in
            Task { @MainActor in
                guard let self else { return }
                if let error { DebugLog.shared.log("reminders access error: \(error.localizedDescription)") }
                self.auth = Self.map(EKEventStore.authorizationStatus(for: .reminder))
                if self.auth == .authorized {
                    self.subscribeChanges()
                    self.refreshAll()
                }
            }
        }
    }

    private func subscribeChanges() {
        guard !observing else { return }
        observing = true
        NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAll() }
        }
    }

    /// Reload the available lists and all their reminders.
    func refreshAll() {
        guard auth == .authorized else { return }
        let calendars = store.calendars(for: .reminder)
        lists = calendars.map { ReminderList(id: $0.calendarIdentifier, title: $0.title) }
        let predicate = store.predicateForReminders(in: calendars)
        store.fetchReminders(matching: predicate) { [weak self] reminders in
            let reminders = reminders ?? []
            Task { @MainActor in
                guard let self else { return }
                var byList: [String: [ListItem]] = [:]
                var cache: [String: EKReminder] = [:]
                for r in reminders {
                    let listID = r.calendar.calendarIdentifier
                    let id = r.calendarItemIdentifier
                    cache[id] = r
                    let item = ListItem(id: id, text: r.title ?? "", done: r.isCompleted)
                    byList[listID, default: []].append(item)
                }
                self.itemsByList = byList
                self.reminderObjectsByID = cache
            }
        }
    }

    /// Tick a reminder off (or back on). EventKit is the source of truth; `.EKEventStoreChanged`
    /// then re-syncs `itemsByList`.
    func setCompleted(reminderID: String, done: Bool) {
        guard let reminder = reminderObjectsByID[reminderID] else { return }
        reminder.isCompleted = done
        do {
            try store.save(reminder, commit: true)
        } catch {
            DebugLog.shared.log("reminders save error: \(error.localizedDescription)")
        }
    }
}
