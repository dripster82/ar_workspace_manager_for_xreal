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

/// Shared chrome for HUD widgets: tinted content on a pill / solid / no background.
private struct WidgetPill<Content: View>: View {
    let style: WidgetStyle
    @ViewBuilder let content: () -> Content

    var body: some View {
        let inner = content()
            .foregroundStyle(style.tint.color)
            .padding(.horizontal, style.background == .none ? 4 : 26)
            .padding(.vertical, style.background == .none ? 2 : 14)
        switch style.background {
        case .pill:
            inner.background(Color.black.opacity(0.55), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
        case .solid:
            inner.background(Color.black.opacity(0.92), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
        case .none:
            inner.shadow(color: .black.opacity(0.85), radius: 3, x: 0, y: 1)
        }
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
        WidgetPill(style: style) {
            Text(text)
                .font(.system(size: 46, weight: .semibold, design: .rounded).monospacedDigit())
        }
    }
}

struct SlackWidgetView: View {
    let style: WidgetStyle
    let connected: Bool
    let unreads: [SlackUnread]
    var nextIn: Int? = nil

    private func countLabel(_ n: Int) -> String { n > 9 ? "9+" : "\(n)" }

    var body: some View {
        WidgetPill(style: style) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "message.badge.fill").font(.system(size: 16))
                    Text("Slack").font(.system(size: 16, weight: .semibold, design: .rounded))
                    Spacer(minLength: 12)
                    if let nextIn, connected {
                        Label("\(nextIn)s", systemImage: "arrow.clockwise")
                            .font(.system(size: 11, weight: .medium)).opacity(0.6)
                    }
                }
                if !connected {
                    Text("Not connected").font(.system(size: 14)).opacity(0.7)
                } else if unreads.isEmpty {
                    Text("All caught up").font(.system(size: 14)).opacity(0.7)
                } else {
                    ForEach(unreads.prefix(8)) { item in
                        HStack(spacing: 8) {
                            Image(systemName: item.isChannel ? "number" : "person.fill")
                                .font(.system(size: 12)).opacity(0.7).frame(width: 14)
                            Text(item.name).font(.system(size: 16, weight: .medium)).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(countLabel(item.count))
                                .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
                        }
                    }
                }
            }
            .frame(minWidth: 150, alignment: .leading)
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
        WidgetPill(style: style) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 32))
                Text(label)
                    .font(.system(size: 38, weight: .semibold, design: .rounded).monospacedDigit())
            }
        }
    }
}
