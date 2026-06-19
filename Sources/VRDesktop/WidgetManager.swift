import SwiftUI
import IOKit.ps
import Compositor
import DisplayManager

/// Battery / power snapshot for the power widget.
struct PowerStatus: Equatable {
    var percent: Int?
    var charging: Bool
    var hasBattery: Bool
}

enum PowerMonitor {
    static func current() -> PowerStatus {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
              !sources.isEmpty else {
            return PowerStatus(percent: nil, charging: false, hasBattery: false)
        }
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue()
                    as? [String: Any] else { continue }
            let type = desc[kIOPSTypeKey as String] as? String
            guard type == (kIOPSInternalBatteryType as String) else { continue }
            let cur = desc[kIOPSCurrentCapacityKey as String] as? Int
            let max = desc[kIOPSMaxCapacityKey as String] as? Int
            let state = desc[kIOPSPowerSourceStateKey as String] as? String
            let charging = (desc[kIOPSIsChargingKey as String] as? Bool)
                ?? (state == (kIOPSACPowerValue as String))
            if let cur, let max, max > 0 {
                return PowerStatus(percent: Int((Double(cur) / Double(max) * 100).rounded()),
                                   charging: charging, hasBattery: true)
            }
        }
        return PowerStatus(percent: nil, charging: false, hasBattery: false)
    }
}

/// Rasterises the active workspace's HUD widgets to textures and pushes them to the renderer,
/// refreshing once a second while AR is running so the clock ticks and battery stays current.
@MainActor
final class WidgetManager {
    private weak var renderer: GlassesRenderer?
    weak var slack: SlackService?
    weak var github: GitHubService?
    weak var calendar: GoogleCalendarService?
    private var widgets: [HUDWidget] = []
    private var stacks: [HUDStack] = []
    private var timer: Timer?
    /// When true the HUD is hidden: nothing is pushed to the renderer (toggled by ⌃⌥I).
    private(set) var hidden = false
    /// Apparent width (metres) of a standalone widget card at scale 1; height follows the aspect.
    private let baseWidthMeters: Float = 0.225
    /// Metres per logical point for content-sized stacks (so a stack grows with its contents).
    private let metersPerPoint: Float = 0.225 / 240

    init(renderer: GlassesRenderer?) { self.renderer = renderer }

    /// Update the widgets + stacks (e.g. on workspace change or edit) and push immediately.
    func setLayout(widgets: [HUDWidget], stacks: [HUDStack]) {
        self.widgets = widgets
        self.stacks = stacks
        push()
    }

    /// Begin the 1 Hz content refresh (call when AR starts).
    func start() {
        push()
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.push() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Stop refreshing and clear the widgets from the scene (call when AR stops).
    func stop() {
        timer?.invalidate()
        timer = nil
        renderer?.setWidgets([])
    }

    /// Hide / show the HUD widgets in the AR scene (⌃⌥I). Pushes immediately so it takes effect.
    func toggleHidden() {
        hidden.toggle()
        push()
    }

    private func push() {
        guard let renderer else { return }
        guard !hidden else { renderer.setWidgets([]); return }
        let date = Date()
        let power = PowerMonitor.current()
        var placements: [GlassesRenderer.WidgetPlacement] = []

        // Standalone widgets (not in any stack): one quad each, fixed apparent width.
        for w in widgets where w.stackID == nil {
            guard let image = render(view(for: w, date: date, power: power)) else { continue }
            placements.append(.init(id: w.id,
                                    yaw: Float(w.yawDegrees * .pi / 180),
                                    pitch: Float(w.pitchDegrees * .pi / 180),
                                    distance: Float(w.distanceMeters),
                                    widthMeters: baseWidthMeters * Float(w.scale),
                                    image: image))
        }

        // Stacks: compose member widgets (each at its own scale) into one V/H stack image, sized by
        // content. `align` controls the anchor so the stack grows the right way: vertical → top /
        // bottom / centre, horizontal → left / right / centre.
        for stack in stacks {
            let members = widgets.filter { $0.stackID == stack.id }
            guard !members.isEmpty else { continue }
            // Natural point size of each member (for the per-widget scale layout).
            let sized: [(HUDWidget, CGSize)] = members.compactMap { m in
                guard let (_, sz) = renderSized(view(for: m, date: date, power: power)) else { return nil }
                return (m, sz)
            }
            guard !sized.isEmpty else { continue }
            guard let (image, pt) = renderSized(stackBody(stack, sized: sized, date: date, power: power)) else { continue }
            let widthMeters = Float(pt.width) * metersPerPoint * Float(stack.scale)
            let heightMeters = pt.height > 0 ? widthMeters * Float(pt.height / pt.width) : widthMeters
            let (ox, oy) = anchorOffset(stack, widthMeters: widthMeters, heightMeters: heightMeters)
            placements.append(.init(id: stack.id,
                                    yaw: Float(stack.yawDegrees * .pi / 180),
                                    pitch: Float(stack.pitchDegrees * .pi / 180),
                                    distance: Float(stack.distanceMeters),
                                    widthMeters: widthMeters, offsetX: ox, offsetY: oy, image: image))
        }
        renderer.setWidgets(placements)
    }

    /// Local-plane shift so the stack is anchored at the requested edge (and grows away from it).
    private func anchorOffset(_ stack: HUDStack, widthMeters: Float, heightMeters: Float) -> (Float, Float) {
        if stack.axis == .vertical {
            switch stack.align {     // top / centre / bottom
            case .start: return (0, -heightMeters / 2)   // anchor top, grow down
            case .end:   return (0,  heightMeters / 2)   // anchor bottom, grow up
            case .center: return (0, 0)
            }
        } else {
            switch stack.align {     // left / centre / right
            case .start: return ( widthMeters / 2, 0)    // anchor left, grow right
            case .end:   return (-widthMeters / 2, 0)    // anchor right, grow left
            case .center: return (0, 0)
            }
        }
    }

    @ViewBuilder
    private func stackBody(_ stack: HUDStack, sized: [(HUDWidget, CGSize)], date: Date, power: PowerStatus) -> some View {
        let cards = sized.map { (m, sz) in
            AnyView(view(for: m, date: date, power: power)
                .frame(width: sz.width, height: sz.height)
                .scaleEffect(CGFloat(m.scale))
                .frame(width: sz.width * CGFloat(m.scale), height: sz.height * CGFloat(m.scale)))
        }
        if stack.axis == .vertical {
            VStack(spacing: 10) { ForEach(cards.indices, id: \.self) { cards[$0] } }
        } else {
            HStack(spacing: 10) { ForEach(cards.indices, id: \.self) { cards[$0] } }
        }
    }

    /// The widget's SwiftUI content (used standalone and inside stacks).
    private func view(for widget: HUDWidget, date: Date, power: PowerStatus) -> AnyView {
        switch widget.kind {
        case .clock: return AnyView(ClockWidgetView(style: widget.style, date: date))
        case .power: return AnyView(PowerWidgetView(style: widget.style, power: power))
        case .slack:
            let nextIn = slack?.nextRefreshAt.map { max(0, Int($0.timeIntervalSinceNow.rounded())) }
            return AnyView(SlackWidgetView(style: widget.style,
                                           connected: slack?.isConnected ?? false,
                                           unreads: slack?.unreads ?? [], nextIn: nextIn))
        case .github:
            return AnyView(GitHubWidgetView(style: widget.style,
                                            connected: github?.isConnected ?? false,
                                            counts: github?.counts ?? GitHubCounts()))
        case .calendar:
            return AnyView(CalendarWidgetView(style: widget.style,
                                              connected: calendar?.isConnected ?? false,
                                              events: calendar?.events ?? []))
        }
    }

    private func render<V: View>(_ content: V) -> CGImage? {
        let r = ImageRenderer(content: content); r.scale = 2; r.isOpaque = false
        return r.cgImage
    }

    /// Render and also return the content's logical (point) size, for content-based sizing.
    private func renderSized<V: View>(_ content: V) -> (CGImage, CGSize)? {
        let r = ImageRenderer(content: content); r.scale = 2; r.isOpaque = false
        guard let image = r.cgImage else { return nil }
        return (image, CGSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2))
    }
}
