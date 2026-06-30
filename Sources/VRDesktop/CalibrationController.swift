import AppKit
import GlassesDriver
import SwiftUI

/// Drift-calibration popup: a centred panel that asks the user to lay the glasses flat and still,
/// waits for Enter to start, counts the measurement down, and plays a tone when it finishes. The
/// expected workflow is to take the glasses off, set them on a flat surface, press Enter, and wait
/// for the tone — so this is a normal Mac panel (the user isn't looking through the glasses).
@MainActor
final class CalibrationController: NSObject, ObservableObject {
    enum Phase: Equatable {
        case ready
        case running(Int)  // seconds remaining
        case done(ok: Bool, message: String)
    }
    @Published var phase: Phase = .ready

    private let coordinator: AppCoordinator
    let seconds: Int
    private var panel: NSPanel?
    private var timer: Timer?
    private var sound: NSSound?
    private var succeeded = false   // recenter on dismiss if the last run calibrated OK
    /// Whether this calibration is required before AR can start (first use of a new device).
    @Published private(set) var firstUse = false
    private var onSuccess: (() -> Void)?

    /// True for One-series glasses, which must be calibrated *worn and level* (the popup measures the
    /// per-device mount tilt). Air glasses are calibrated flat on a surface (drift only).
    var isOneSeries: Bool { IMUService.shared.usingNetworkIMU }

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        self.seconds = max(1, Int(coordinator.driftCalibrationSeconds))
        super.init()
    }

    /// Show (or re-show) the popup in its ready state. `firstUse` switches to the "required on first
    /// use" wording; `onSuccess` (if set) runs once a successful calibration is dismissed.
    func show(firstUse: Bool = false, onSuccess: (() -> Void)? = nil) {
        timer?.invalidate()
        timer = nil
        sound?.stop()
        sound = nil
        self.firstUse = firstUse
        self.onSuccess = onSuccess
        phase = .ready
        presentPanel()
    }

    /// Begin the countdown + the actual measurement (called by the Start button / Enter).
    func start() {
        guard !coordinator.driftCalibrating else { return }
        phase = .running(seconds)
        var remaining = seconds
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                remaining -= 1
                if remaining > 0, case .running = self.phase { self.phase = .running(remaining) }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        coordinator.calibrateDrift(duration: TimeInterval(seconds)) { [weak self] ok, message in
            self?.finish(ok: ok, message: message)
        }
    }

    func reset() { phase = .ready }

    /// Escape hatch for the first-use (pre-AR) flow: dismiss without a successful calibration but
    /// still run the continuation, so a user whose calibration won't pass isn't blocked from AR. The
    /// device stays uncalibrated (default mount correction) and is re-prompted next time.
    func skipAndContinue() {
        timer?.invalidate()
        timer = nil
        sound?.stop()
        sound = nil
        panel?.orderOut(nil)
        succeeded = false
        let cont = onSuccess
        onSuccess = nil
        cont?()
    }

    func close() {
        timer?.invalidate()
        timer = nil
        sound?.stop()
        sound = nil
        panel?.orderOut(nil)
        // Recenter once dismissed after a good run — by now the glasses are on and facing forward,
        // so the view snaps to where you're actually looking. Then run any continuation (e.g. resume
        // starting AR now that a first-use device is calibrated).
        if succeeded {
            succeeded = false
            coordinator.recenter()
            let cont = onSuccess
            onSuccess = nil
            cont?()
        }
    }

    private func finish(ok: Bool, message: String) {
        timer?.invalidate()
        timer = nil
        succeeded = ok
        phase = .done(ok: ok, message: message)
        // Tone signals "measurement finished — safe to pick the glasses back up".
        let s = NSSound(named: NSSound.Name("Glass")) ?? NSSound(named: NSSound.Name("Ping"))
        s?.play()
        sound = s
    }

    private func presentPanel() {
        let hosting = NSHostingView(rootView: CalibrationView(controller: self))
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        // Centre on a non-AR screen (the user is looking at the Mac, glasses off).
        let screen =
            NSScreen.screens.first {
                AppCoordinator.screenDisplayID($0) != coordinator.arOutputDisplayID
            } ?? NSScreen.main
        if let f = screen?.frame {
            let sz = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: f.midX - sz.width / 2, y: f.midY - sz.height / 2))
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)  // key so the Enter (default-action) button works
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        p.title = "Drift Calibration"
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        return p
    }
}

/// The calibration popup's content; observes the controller's phase.
struct CalibrationView: View {
    @ObservedObject var controller: CalibrationController

    /// One-series glasses measure the per-device mount tilt, so they must be *worn* and level; Air
    /// glasses measure drift only and are easiest flat on a surface.
    private var readyInstructions: String {
        if controller.isOneSeries {
            return "Put the glasses on, look straight ahead and keep your head level and still. "
                + "Then press Enter to start a \(controller.seconds)-second measurement, and hold "
                + "steady until you hear the tone."
        }
        return "Keep the glasses perfectly still and level — either hold your head steady or lay them "
            + "flat on a surface. Then press Enter to start a \(controller.seconds)-second measurement, "
            + "and don't move them until you hear the tone."
    }

    private var tip: String {
        controller.isOneSeries
            ? "Tip: face forward as if looking at the screen ahead of you, keep your head level, and "
              + "stay still until the tone."
            : "Tip: place the glasses on a flat surface, press Enter, and wait for the tone before "
              + "putting them back on."
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "gyroscope").font(.system(size: 38, weight: .semibold))
                .foregroundStyle(.tint)
            Text(controller.isOneSeries ? "Calibration" : "Drift Calibration")
                .font(.title3.weight(.semibold))

            switch controller.phase {
            case .ready:
                if controller.firstUse {
                    Text("Calibration is required on first use of a new device.")
                        .font(.callout.weight(.medium))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.tint)
                }
                Text(readyInstructions)
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button("Start") { controller.start() }
                    .keyboardShortcut(.defaultAction).controlSize(.large)
            case .running(let n):
                Text("\(n)")
                    .font(.system(size: 52, weight: .bold, design: .rounded).monospacedDigit())
                Text(controller.isOneSeries ? "Hold still — keep level…" : "Hold still…")
                    .foregroundStyle(.secondary)
            case .done(let ok, let message):
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 30)).foregroundStyle(ok ? .green : .orange)
                Text(message).multilineTextAlignment(.center)
                HStack(spacing: 10) {
                    if !ok { Button("Try Again") { controller.reset() } }
                    if controller.firstUse && !ok {
                        // Don't trap the user out of AR if calibration won't pass.
                        Button("Start AR anyway") { controller.skipAndContinue() }
                    }
                    Button(controller.firstUse && ok ? "Start AR" : "Done") { controller.close() }
                        .keyboardShortcut(.defaultAction)
                }
            }

            Spacer(minLength: 4)
            Text(tip)
                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(width: 390, height: 360)
        .preferredColorScheme(.dark)
        .tint(PanelTheme.accent)
    }
}
