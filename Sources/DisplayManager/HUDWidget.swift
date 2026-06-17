import Foundation

/// Kinds of HUD widget. v1: a clock and a power/battery indicator.
public enum WidgetKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case clock, power
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .clock: return "Clock"
        case .power: return "Power"
        }
    }
    public var symbol: String {
        switch self {
        case .clock: return "clock"
        case .power: return "battery.100"
        }
    }
}

/// Accent colour for a widget's text/icon.
public enum WidgetTint: String, Codable, CaseIterable, Sendable, Identifiable {
    case white, blue, green, orange, pink, yellow
    public var id: String { rawValue }
    public var displayName: String { rawValue.capitalized }
}

/// Per-widget styling.
public struct WidgetStyle: Codable, Hashable, Sendable {
    public var tint: WidgetTint
    public var clock24h: Bool
    public var showSeconds: Bool

    public init(tint: WidgetTint = .white, clock24h: Bool = true, showSeconds: Bool = false) {
        self.tint = tint
        self.clock24h = clock24h
        self.showSeconds = showSeconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tint = try c.decodeIfPresent(WidgetTint.self, forKey: .tint) ?? .white
        clock24h = try c.decodeIfPresent(Bool.self, forKey: .clock24h) ?? true
        showSeconds = try c.decodeIfPresent(Bool.self, forKey: .showSeconds) ?? false
    }
}

/// A head-locked HUD widget that floats in the field of view. Placement mirrors a floating screen:
/// a yaw/pitch offset in view space, a distance, and a size scale.
public struct HUDWidget: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var kind: WidgetKind
    public var yawDegrees: Double      // negative = left of centre
    public var pitchDegrees: Double    // positive = up
    public var distanceMeters: Double
    public var scale: Double
    public var style: WidgetStyle

    public init(id: UUID = UUID(), kind: WidgetKind,
                yawDegrees: Double = -14, pitchDegrees: Double = 8,
                distanceMeters: Double = 1.5, scale: Double = 1.0,
                style: WidgetStyle = WidgetStyle()) {
        self.id = id
        self.kind = kind
        self.yawDegrees = yawDegrees
        self.pitchDegrees = pitchDegrees
        self.distanceMeters = distanceMeters
        self.scale = scale
        self.style = style
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
    }
}
