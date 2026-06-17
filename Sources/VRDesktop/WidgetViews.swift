import SwiftUI
import DisplayManager

extension WidgetTint {
    var color: Color {
        switch self {
        case .white: return .white
        case .blue: return .blue
        case .green: return .green
        case .orange: return .orange
        case .pink: return .pink
        case .yellow: return .yellow
        }
    }
}

/// Shared translucent dark-pill chrome for HUD widgets.
private struct WidgetPill<Content: View>: View {
    let tint: WidgetTint
    @ViewBuilder let content: () -> Content
    var body: some View {
        content()
            .foregroundStyle(tint.color)
            .padding(.horizontal, 26)
            .padding(.vertical, 14)
            .background(Color.black.opacity(0.55), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
    }
}

struct ClockWidgetView: View {
    let style: WidgetStyle
    let date: Date

    private var text: String {
        let f = DateFormatter()
        f.dateFormat = style.clock24h
            ? (style.showSeconds ? "HH:mm:ss" : "HH:mm")
            : (style.showSeconds ? "h:mm:ss a" : "h:mm a")
        return f.string(from: date)
    }

    var body: some View {
        WidgetPill(tint: style.tint) {
            Text(text)
                .font(.system(size: 46, weight: .semibold, design: .rounded).monospacedDigit())
        }
    }
}

struct PowerWidgetView: View {
    let style: WidgetStyle
    let power: PowerStatus

    private var symbol: String {
        guard power.hasBattery else { return "powerplug.fill" }
        if power.charging { return "battery.100percent.bolt" }
        switch power.percent ?? 0 {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private var label: String {
        guard power.hasBattery else { return "AC" }
        return "\(power.percent ?? 0)%"
    }

    var body: some View {
        WidgetPill(tint: style.tint) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 32))
                Text(label)
                    .font(.system(size: 38, weight: .semibold, design: .rounded).monospacedDigit())
            }
        }
    }
}
