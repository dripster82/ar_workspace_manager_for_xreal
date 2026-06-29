import Foundation

/// Kinds of HUD widget. v1: a clock and a power/battery indicator.
public enum WidgetKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case clock, power, slack, github, calendar, list
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .clock: return "Clock"
        case .power: return "Power"
        case .slack: return "Slack unreads"
        case .github: return "GitHub PRs"
        case .calendar: return "Calendar"
        case .list: return "List"
        }
    }
    public var symbol: String {
        switch self {
        case .clock: return "clock"
        case .power: return "battery.100"
        case .slack: return "message.badge"
        case .github: return "chevron.left.forwardslash.chevron.right"
        case .calendar: return "calendar"
        case .list: return "checklist"
        }
    }
}

/// Accent colour for a widget's text/icon.
public enum WidgetTint: String, Codable, CaseIterable, Sendable, Identifiable {
    case white, blue, green, orange, pink, yellow
    public var id: String { rawValue }
    public var displayName: String { rawValue.capitalized }
}

/// Card background behind a widget.
public enum WidgetBackground: String, Codable, CaseIterable, Sendable, Identifiable {
    case pill    // translucent dark capsule
    case solid   // opaque dark capsule
    case none    // no background (text/icon only, with a shadow for legibility)
    public var id: String { rawValue }
    public var displayName: String { self == .none ? "None" : rawValue.capitalized }
}

/// Per-widget styling.
public struct WidgetStyle: Codable, Hashable, Sendable {
    public var tint: WidgetTint
    public var background: WidgetBackground
    public var clock24h: Bool
    public var showSeconds: Bool
    /// Slack: show the "next refresh in Xs" countdown footer (off by default).
    public var showRefreshCountdown: Bool

    public init(tint: WidgetTint = .white, background: WidgetBackground = .pill,
                clock24h: Bool = true, showSeconds: Bool = false, showRefreshCountdown: Bool = false) {
        self.tint = tint
        self.background = background
        self.clock24h = clock24h
        self.showSeconds = showSeconds
        self.showRefreshCountdown = showRefreshCountdown
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tint = try c.decodeIfPresent(WidgetTint.self, forKey: .tint) ?? .white
        background = try c.decodeIfPresent(WidgetBackground.self, forKey: .background) ?? .pill
        clock24h = try c.decodeIfPresent(Bool.self, forKey: .clock24h) ?? true
        showSeconds = try c.decodeIfPresent(Bool.self, forKey: .showSeconds) ?? false
        showRefreshCountdown = try c.decodeIfPresent(Bool.self, forKey: .showRefreshCountdown) ?? false
    }
}

/// Where a List widget gets its items: typed into the control panel (persisted in the workspace JSON)
/// or linked to an Apple Reminders list (EventKit, iCloud-synced).
public enum ListSource: String, Codable, CaseIterable, Sendable, Identifiable {
    case inApp, reminders
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .inApp: return "In-app"
        case .reminders: return "Apple Reminders"
        }
    }
}

/// One checklist item. For in-app lists `id` is a generated UUID string; for Apple Reminders it is the
/// reminder's `calendarItemIdentifier`, so write-back can find the original.
public struct ListItem: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var text: String
    public var done: Bool

    public init(id: String = UUID().uuidString, text: String = "", done: Bool = false) {
        self.id = id
        self.text = text
        self.done = done
    }
}

/// Per-widget configuration for a List widget. `items` (in-app) and `reminderListID` (Reminders) are
/// kept independently so switching `source` preserves both.
public struct ListConfig: Codable, Hashable, Sendable {
    public var source: ListSource
    public var items: [ListItem]
    public var reminderListID: String?
    public var showCompleted: Bool
    public var title: String

    public init(source: ListSource = .inApp, items: [ListItem] = [],
                reminderListID: String? = nil, showCompleted: Bool = false, title: String = "List") {
        self.source = source
        self.items = items
        self.reminderListID = reminderListID
        self.showCompleted = showCompleted
        self.title = title
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decodeIfPresent(ListSource.self, forKey: .source) ?? .inApp
        items = try c.decodeIfPresent([ListItem].self, forKey: .items) ?? []
        reminderListID = try c.decodeIfPresent(String.self, forKey: .reminderListID)
        showCompleted = try c.decodeIfPresent(Bool.self, forKey: .showCompleted) ?? false
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "List"
    }
}

/// Where the Calendar widget reads events from. `nil` on a widget is treated as `.google` so existing
/// saved widgets keep today's behaviour.
public enum CalendarSource: String, Codable, CaseIterable, Sendable, Identifiable {
    case google, apple, both
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .google: return "Google"
        case .apple: return "Apple"
        case .both: return "Both"
        }
    }
}

/// How far ahead the Calendar widget lists events. `nil` on a widget is treated as `.all` (the existing
/// behaviour: whatever upcoming events the service holds, within its fetch window).
public enum CalendarRange: String, Codable, CaseIterable, Sendable, Identifiable {
    case all, today, todayTomorrow
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .all: return "All upcoming"
        case .today: return "Today only"
        case .todayTomorrow: return "Today + tomorrow"
        }
    }
}

/// A head-locked HUD widget that floats in the field of view. Placement mirrors a floating screen:
/// a yaw/pitch offset in view space, a distance, and a size scale. When `stackID` is set the
/// widget is laid out by that stack instead of its own yaw/pitch.
public struct HUDWidget: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var kind: WidgetKind
    public var yawDegrees: Double      // negative = left of centre
    public var pitchDegrees: Double    // positive = up
    public var distanceMeters: Double
    public var scale: Double
    public var style: WidgetStyle
    public var stackID: UUID?          // when set, this widget lives inside a HUDStack
    public var list: ListConfig?       // List widget only; nil → defaults via `list ?? ListConfig()`
    public var calendarSource: CalendarSource?  // Calendar widget only; nil treated as .google
    public var calendarRange: CalendarRange?    // Calendar widget only; nil treated as .all
    public var calendarMaxEvents: Int?          // Calendar widget only; nil treated as 4

    public init(id: UUID = UUID(), kind: WidgetKind,
                yawDegrees: Double = -14, pitchDegrees: Double = 8,
                distanceMeters: Double = 1.5, scale: Double = 1.0,
                style: WidgetStyle = WidgetStyle(), stackID: UUID? = nil,
                list: ListConfig? = nil, calendarSource: CalendarSource? = nil,
                calendarRange: CalendarRange? = nil, calendarMaxEvents: Int? = nil) {
        self.id = id
        self.kind = kind
        self.yawDegrees = yawDegrees
        self.pitchDegrees = pitchDegrees
        self.distanceMeters = distanceMeters
        self.scale = scale
        self.style = style
        self.stackID = stackID
        self.list = list
        self.calendarSource = calendarSource
        self.calendarRange = calendarRange
        self.calendarMaxEvents = calendarMaxEvents
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(WidgetKind.self, forKey: .kind)
        yawDegrees = try c.decodeIfPresent(Double.self, forKey: .yawDegrees) ?? -14
        pitchDegrees = try c.decodeIfPresent(Double.self, forKey: .pitchDegrees) ?? 8
        distanceMeters = try c.decodeIfPresent(Double.self, forKey: .distanceMeters) ?? 1.5
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 1.0
        style = try c.decodeIfPresent(WidgetStyle.self, forKey: .style) ?? WidgetStyle()
        stackID = try c.decodeIfPresent(UUID.self, forKey: .stackID)
        list = try c.decodeIfPresent(ListConfig.self, forKey: .list)
        calendarSource = try c.decodeIfPresent(CalendarSource.self, forKey: .calendarSource)
        calendarRange = try c.decodeIfPresent(CalendarRange.self, forKey: .calendarRange)
        calendarMaxEvents = try c.decodeIfPresent(Int.self, forKey: .calendarMaxEvents)
    }
}

/// Layout axis for a HUD stack.
public enum StackAxis: String, Codable, Sendable, CaseIterable, Identifiable {
    case vertical, horizontal
    public var id: String { rawValue }
}

/// Alignment within a stack. Interpreted per axis: vertical → left/centre/right,
/// horizontal → top/centre/bottom.
public enum StackAlign: String, Codable, Sendable, CaseIterable, Identifiable {
    case start, center, end
    public var id: String { rawValue }
}

/// A container that lays its member widgets out in a vertical or horizontal stack at one placement.
/// Members reflow automatically (a card growing pushes the others); members are the workspace's
/// widgets whose `stackID` is this stack, in workspace order.
public struct HUDStack: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var axis: StackAxis
    public var align: StackAlign
    public var yawDegrees: Double
    public var pitchDegrees: Double
    public var distanceMeters: Double
    public var scale: Double

    public init(id: UUID = UUID(), name: String = "Stack", axis: StackAxis = .vertical,
                align: StackAlign = .start, yawDegrees: Double = -14, pitchDegrees: Double = 8,
                distanceMeters: Double = 1.5, scale: Double = 1.0) {
        self.id = id; self.name = name; self.axis = axis; self.align = align
        self.yawDegrees = yawDegrees; self.pitchDegrees = pitchDegrees
        self.distanceMeters = distanceMeters; self.scale = scale
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Stack"
        axis = try c.decodeIfPresent(StackAxis.self, forKey: .axis) ?? .vertical
        align = try c.decodeIfPresent(StackAlign.self, forKey: .align) ?? .start
        yawDegrees = try c.decodeIfPresent(Double.self, forKey: .yawDegrees) ?? -14
        pitchDegrees = try c.decodeIfPresent(Double.self, forKey: .pitchDegrees) ?? 8
        distanceMeters = try c.decodeIfPresent(Double.self, forKey: .distanceMeters) ?? 1.5
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 1.0
    }
}
