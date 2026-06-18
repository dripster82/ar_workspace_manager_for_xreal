import AppKit
import SwiftUI

/// Presents a meeting alarm: a looping audio tone plus a card dead-centre of the FOV (in-AR
/// overlay, or a centred panel when AR is off). Dismissed by Esc (armed via `escArmer`).
@MainActor
final class AlarmController {
    private let coordinator: AppCoordinator
    private var panel: NSPanel?
    private var sound: NSSound?
    private var autoHide: Timer?
    private(set) var showing = false
    /// Set by the app delegate to register/unregister the global Esc-to-dismiss hotkey.
    var escArmer: ((Bool) -> Void)?

    init(coordinator: AppCoordinator) { self.coordinator = coordinator }

    func fire(event: CalEvent, leadMinutes: Int) {
        let view = AlarmView(title: event.title, when: Self.whenText(event: event, lead: leadMinutes),
                             time: Self.timeText(event))
        if coordinator.arActive, let renderer = coordinator.renderer,
           let image = render(view) {
            renderer.setHelpImage(image)   // centre overlay slot
            panel?.orderOut(nil)
        } else {
            showPanel(view)
        }
        playSound()
        if !showing { escArmer?(true) }
        showing = true
        autoHide?.invalidate()
        autoHide = Timer(timeInterval: 90, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }   // safety auto-stop
        }
        if let autoHide { RunLoop.main.add(autoHide, forMode: .common) }
    }

    func dismiss() {
        guard showing else { return }
        showing = false
        sound?.stop(); sound = nil
        autoHide?.invalidate(); autoHide = nil
        coordinator.renderer?.clearHelp()
        panel?.orderOut(nil)
        escArmer?(false)
    }

    private func playSound() {
        sound?.stop()
        let s = NSSound(named: NSSound.Name("Submarine")) ?? NSSound(named: NSSound.Name("Glass"))
        s?.loops = true
        s?.play()
        sound = s
    }

    private func render(_ view: AlarmView) -> CGImage? {
        let r = ImageRenderer(content: view)
        r.scale = 2; r.isOpaque = false
        return r.cgImage
    }

    private func showPanel(_ view: AlarmView) {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        let screen = NSScreen.screens.first {
            AppCoordinator.screenDisplayID($0) != coordinator.arOutputDisplayID
        } ?? NSScreen.main
        if let f = screen?.frame {
            let s = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: f.midX - s.width / 2, y: f.midY - s.height / 2))
        }
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 200),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true; p.level = .floating; p.hidesOnDeactivate = false
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
        return p
    }

    private static func timeText(_ e: CalEvent) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return e.allDay ? "all-day" : f.string(from: e.start)
    }

    private static func whenText(event: CalEvent, lead: Int) -> String {
        switch lead {
        case 0: return "starting now"
        case 1..<60: return "in \(lead) minutes"
        case 60: return "in 1 hour"
        case 61..<1440: return "in \(lead / 60) hours"
        case 1440: return "tomorrow"
        default: return "soon"
        }
    }
}

/// The alarm card shown in the centre of the field of view.
struct AlarmView: View {
    let title: String
    let when: String
    let time: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "alarm.fill").font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.orange)
            Text(title).font(.system(size: 30, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center).lineLimit(2)
            Text("\(when) · \(time)").font(.system(size: 20, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            Text("Press Esc to dismiss").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
        }
        .padding(36)
        .frame(width: 460)
        .background(Color.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.orange.opacity(0.6), lineWidth: 2))
        .foregroundStyle(.white)
    }
}
