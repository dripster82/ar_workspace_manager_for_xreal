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
    private var widgets: [HUDWidget] = []
    private var timer: Timer?
    /// Apparent width (metres) of a widget card at scale 1; height follows the rendered aspect.
    private let baseWidthMeters: Float = 0.45

    init(renderer: GlassesRenderer?) { self.renderer = renderer }

    /// Update the widget set (e.g. on workspace change or edit) and push immediately.
    func setWidgets(_ widgets: [HUDWidget]) {
        self.widgets = widgets
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

    private func push() {
        guard let renderer else { return }
        let date = Date()
        let power = PowerMonitor.current()
        let placements: [GlassesRenderer.WidgetPlacement] = widgets.compactMap { w in
            guard let image = renderImage(for: w, date: date, power: power) else { return nil }
            return GlassesRenderer.WidgetPlacement(
                id: w.id,
                yaw: Float(w.yawDegrees * .pi / 180),
                pitch: Float(w.pitchDegrees * .pi / 180),
                distance: Float(w.distanceMeters),
                widthMeters: baseWidthMeters * Float(w.scale),
                image: image)
        }
        renderer.setWidgets(placements)
    }

    private func renderImage(for widget: HUDWidget, date: Date, power: PowerStatus) -> CGImage? {
        let content: AnyView
        switch widget.kind {
        case .clock: content = AnyView(ClockWidgetView(style: widget.style, date: date))
        case .power: content = AnyView(PowerWidgetView(style: widget.style, power: power))
        }
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        renderer.isOpaque = false
        return renderer.cgImage
    }
}
