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

    private let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)

    var body: some View {
        let inner = content()
            .foregroundStyle(style.tint.color)
            .padding(.horizontal, style.background == .none ? 4 : 22)
            .padding(.vertical, style.background == .none ? 2 : 14)
        switch style.background {
        case .pill:
            inner.background(Color.black.opacity(0.55), in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.15)))
        case .solid:
            inner.background(Color.black.opacity(0.92), in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.18)))
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
                }
                if !connected {
                    Text("Not connected").font(.system(size: 14)).opacity(0.7)
                } else if unreads.isEmpty {
                    Text("All caught up").font(.system(size: 14)).opacity(0.7)
                } else {
                    ForEach(unreads.prefix(8)) { item in
                        HStack(spacing: 8) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 12)).opacity(0.7).frame(width: 14)
                            Text(item.name).font(.system(size: 16, weight: .medium)).lineLimit(1)
                            Spacer(minLength: 8)
                            if item.showsCount {
                                Text(countLabel(item.count))
                                    .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
                            } else {
                                Circle().frame(width: 8, height: 8) // unread highlight, no count
                            }
                        }
                    }
                }
                if connected && style.showRefreshCountdown {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 10))
                        Text(nextIn.map { "next in \($0)s" } ?? "refreshing…")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .opacity(0.55).padding(.top, 2)
                }
            }
            .frame(minWidth: 150, alignment: .leading)
        }
    }
}

struct CalendarWidgetView: View {
    let style: WidgetStyle
    let connected: Bool
    let events: [CalEvent]

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    private func relative(_ e: CalEvent) -> String {
        let now = Date()
        if now >= e.start && now < e.end { return "now" }
        let secs = e.start.timeIntervalSince(now)
        guard secs > 0 else { return "" }
        if secs < 3600 { return "in \(max(1, Int(secs / 60)))m" }
        if secs < 86400 { return "in \(Int(secs / 3600))h" }
        return ""
    }

    private var upcoming: [CalEvent] {
        let now = Date()
        return events.filter { $0.end > now }.prefix(4).map { $0 }
    }

    private func dayLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        let f = DateFormatter(); f.dateFormat = "EEEE d"; return f.string(from: date)
    }

    /// Wrap a title to lines of at most `limit` characters, breaking at whitespace where possible and
    /// hard-breaking any single word longer than the limit.
    static func wrapTitle(_ text: String, limit: Int = 25) -> String {
        var lines: [String] = []
        var current = ""
        for token in text.split(whereSeparator: { $0.isWhitespace }) {
            var word = String(token)
            // Hard-break a word that can't fit on its own line.
            while word.count > limit {
                if !current.isEmpty { lines.append(current); current = "" }
                let cut = word.index(word.startIndex, offsetBy: limit)
                lines.append(String(word[..<cut]))
                word = String(word[cut...])
            }
            if current.isEmpty {
                current = word
            } else if current.count + 1 + word.count <= limit {
                current += " " + word
            } else {
                lines.append(current)
                current = word
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.joined(separator: "\n")
    }

    /// Meeting length, e.g. "15m", "1hr", "1h30m".
    private func durationLabel(_ e: CalEvent) -> String {
        let mins = Int(e.end.timeIntervalSince(e.start) / 60)
        guard mins > 0 else { return "" }
        if mins < 60 { return "\(mins)m" }
        let h = mins / 60, m = mins % 60
        return m == 0 ? "\(h)hr" : "\(h)h\(m)m"
    }

    var body: some View {
        let items = upcoming
        return WidgetPill(style: style) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "calendar").font(.system(size: 15))
                    Text("Calendar").font(.system(size: 16, weight: .semibold, design: .rounded))
                }
                if !connected {
                    Text("Not connected").font(.system(size: 14)).opacity(0.7)
                } else if items.isEmpty {
                    Text("No upcoming events").font(.system(size: 14)).opacity(0.7)
                } else {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, e in
                        let cal = Calendar.current
                        let newDay = idx == 0 || !cal.isDate(items[idx - 1].start, inSameDayAs: e.start)
                        let isNext = idx == 0
                        if newDay {
                            Text(dayLabel(e.start)).font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundStyle(.secondary).padding(.top, idx == 0 ? 2 : 6)
                        }
                        HStack(alignment: .top, spacing: 6) {
                            Text(e.allDay ? "all-day" : Self.timeFmt.string(from: e.start))
                                .font(.system(size: 13, weight: .medium, design: .rounded).monospacedDigit())
                                .frame(width: 42, alignment: .leading).opacity(0.8)
                            if !e.allDay, case let d = durationLabel(e), !d.isEmpty {
                                Text("(\(d))").font(.system(size: 11, weight: .medium, design: .rounded))
                                    .frame(width: 46, alignment: .leading).opacity(0.55)
                            }
                            Text(Self.wrapTitle(e.title)).font(.system(size: 15, weight: isNext ? .semibold : .medium))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            let r = relative(e)
                            if !r.isEmpty {
                                Text(r).font(.system(size: 13, weight: .bold, design: .rounded))
                                    .foregroundStyle(r == "now" ? .green : style.tint.color.opacity(0.85))
                            }
                        }
                        .opacity(isNext ? 1 : 0.8)
                    }
                }
            }
            .frame(minWidth: 200, alignment: .leading)
        }
    }
}

/// The in-FOV recording indicator (top-centre). Not composited into the recorded video.
struct RecordingIndicatorView: View {
    let muted: Bool
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(.red).frame(width: 14, height: 14)
            Text("REC").font(.system(size: 18, weight: .bold, design: .rounded))
            if muted { Image(systemName: "mic.slash.fill").font(.system(size: 15)) }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18).padding(.vertical, 8)
        .background(Color.black.opacity(0.55), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
    }
}

struct GitHubWidgetView: View {
    let style: WidgetStyle
    let connected: Bool
    let counts: GitHubCounts

    private struct Row { let label: String; let count: Int; let symbol: String; let hot: Color? }

    private var rows: [Row] {
        [
            Row(label: "Needs your review", count: counts.needsReview, symbol: "eye", hot: .yellow),
            Row(label: "Team review", count: counts.teamReview, symbol: "person.2", hot: nil),
            Row(label: "Changes requested", count: counts.changesRequested, symbol: "pencil.line", hot: .orange),
            Row(label: "Failing checks", count: counts.failingChecks, symbol: "xmark.octagon", hot: .red),
            Row(label: "Ready to merge", count: counts.readyToMerge, symbol: "checkmark.seal", hot: .green),
        ]
    }

    var body: some View {
        WidgetPill(style: style) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 15))
                    Text("GitHub").font(.system(size: 16, weight: .semibold, design: .rounded))
                }
                if !connected {
                    Text("Not connected").font(.system(size: 14)).opacity(0.7)
                } else {
                    ForEach(rows.indices, id: \.self) { i in
                        let row = rows[i]
                        let active = row.count > 0
                        HStack(spacing: 8) {
                            Image(systemName: row.symbol)
                                .font(.system(size: 12)).frame(width: 16)
                                .foregroundStyle(active ? (row.hot ?? style.tint.color) : style.tint.color.opacity(0.55))
                            Text(row.label).font(.system(size: 15, weight: .medium))
                                .opacity(active ? 1 : 0.6)
                            Spacer(minLength: 8)
                            Text("\(row.count)")
                                .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
                                .foregroundStyle(active ? (row.hot ?? style.tint.color) : style.tint.color.opacity(0.6))
                        }
                    }
                }
            }
            .frame(minWidth: 190, alignment: .leading)
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
