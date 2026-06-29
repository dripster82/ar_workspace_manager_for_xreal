import Foundation
import EventKit

/// Reads Apple Calendar events via EventKit for the Calendar HUD widget. Owns its own `EKEventStore`;
/// access is gated by the Calendars TCC permission + the `NSCalendarsFullAccessUsageDescription`
/// Info.plist string (no entitlement needed). Publishes the same `CalEvent` shape as
/// `GoogleCalendarService` so `CalendarWidgetView` is reused unchanged. Live updates arrive via
/// `.EKEventStoreChanged`.
@MainActor
final class AppleCalendarService: ObservableObject {
    enum CalAuth { case notDetermined, denied, restricted, authorized }

    /// A user-visible calendar (an `EKCalendar` of type `.event`).
    struct CalendarInfo: Identifiable, Equatable {
        let id: String      // EKCalendar.calendarIdentifier
        let title: String
    }

    @Published private(set) var auth: CalAuth = .notDetermined
    @Published private(set) var calendars: [CalendarInfo] = []
    @Published private(set) var events: [CalEvent] = []
    /// Which calendars feed the widget. Global (mirrors the global Google iCal feed), persisted in
    /// UserDefaults. Empty → all selectable calendars are used.
    @Published var selectedCalendarIDs: [String] {
        didSet {
            UserDefaults.standard.set(selectedCalendarIDs, forKey: Self.selectedKey)
            refresh()
        }
    }

    private static let selectedKey = "appleCalendarSelectedIDs"
    private let store = EKEventStore()
    private var observing = false

    var isConnected: Bool { auth == .authorized }

    init() {
        selectedCalendarIDs = UserDefaults.standard.stringArray(forKey: Self.selectedKey) ?? []
        auth = Self.map(EKEventStore.authorizationStatus(for: .event))
        if auth == .authorized {
            subscribeChanges()
            loadCalendars()
            refresh()
        }
    }

    private static func map(_ status: EKAuthorizationStatus) -> CalAuth {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .fullAccess: return .authorized
        default: return .denied
        }
    }

    /// Prompt for (or re-check) full access. On grant, observe changes and load calendars + events.
    func requestAccess() {
        store.requestFullAccessToEvents { [weak self] _, error in
            Task { @MainActor in
                guard let self else { return }
                if let error { DebugLog.shared.log("calendar access error: \(error.localizedDescription)") }
                self.auth = Self.map(EKEventStore.authorizationStatus(for: .event))
                if self.auth == .authorized {
                    self.subscribeChanges()
                    self.loadCalendars()
                    self.refresh()
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
            MainActor.assumeIsolated {
                self?.loadCalendars()
                self?.refresh()
            }
        }
    }

    private func loadCalendars() {
        guard auth == .authorized else { return }
        calendars = store.calendars(for: .event)
            .map { CalendarInfo(id: $0.calendarIdentifier, title: $0.title) }
    }

    /// Reload the next ~7 days of events from the selected calendars (or all, if none selected).
    func refresh() {
        guard auth == .authorized else { return }
        let all = store.calendars(for: .event)
        let chosen = selectedCalendarIDs.isEmpty
            ? all
            : all.filter { selectedCalendarIDs.contains($0.calendarIdentifier) }
        guard !chosen.isEmpty else { events = []; return }
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now,
                                                 end: now.addingTimeInterval(7 * 86400),
                                                 calendars: chosen)
        events = store.events(matching: predicate)
            .map { ev in
                CalEvent(id: "apple_\(ev.eventIdentifier ?? UUID().uuidString)",
                         title: ev.title ?? "(no title)",
                         start: ev.startDate, end: ev.endDate, allDay: ev.isAllDay)
            }
            .sorted { $0.start < $1.start }
    }
}
