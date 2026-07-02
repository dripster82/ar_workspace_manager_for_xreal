import Foundation

/// Detector for the macOS ColorSync runaway: `colorsync.displayservices` gets stuck re-parsing the
/// display registry (the Air 2 self-loop) and pins a CPU core at ~75–100%. Left alone it doesn't
/// just make the machine sluggish — twice now (2026-07-01/02) it starved WindowServer's main thread
/// until the OS watchdog killed it, resetting the whole login session.
///
/// This used to auto-remediate (sweep orphan profiles + bounce the daemons via the privileged
/// helper), but the 2026-07-02 incident proved bouncing does NOT cure the self-loop: three bounces,
/// each re-pegged within ~2 minutes, then WindowServer died 29 minutes later. Only physically
/// replugging the glasses (or a reboot) clears it. So the watchdog is now detection-only: when the
/// daemon stays pinned for a sustained window it fires `onRunawayDetected` (once per episode) and
/// the app tells the user to replug — the only fix that works.
@MainActor
final class ColorSyncWatchdog {
    /// Sustained CPU (%) of colorsync.displayservices that counts as "pinned". The runaway sits at
    /// ~74–100%; benign AR-time bursts peak ~30–53% and decay, so 65% over several samples avoids them.
    private let pinThreshold = 65.0
    /// Consecutive over-threshold samples before alerting (× interval = sustained time required).
    private let samplesToTrigger = 3
    private let interval: TimeInterval = 30

    /// Called once per runaway episode when the daemon has been pinned for the sustained window.
    /// Resets (and can fire again) only after the CPU fully recovers (< 25%).
    var onRunawayDetected: ((Double) -> Void)?

    private var timer: Timer?
    private var consecutiveHigh = 0
    private var alertedThisEpisode = false

    private(set) var enabled = false

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on { start() } else { stop() }
    }

    private func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        DebugLog.shared.log("ColorSync alert on (≥\(Int(self.pinThreshold))% for \(self.samplesToTrigger)×\(Int(self.interval))s → warn)")
    }

    private func stop() {
        timer?.invalidate(); timer = nil
        consecutiveHigh = 0
        alertedThisEpisode = false
        DebugLog.shared.log("ColorSync alert off")
    }

    private func tick() {
        // ps is cheap but not free — sample off-main.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let cpu = SystemHealth.processCPU(matching: ["colorsync.displayservices"]).first?.cpu ?? 0
            DispatchQueue.main.async { self?.evaluate(cpu: cpu) }
        }
    }

    private func evaluate(cpu: Double) {
        guard cpu >= pinThreshold else {
            consecutiveHigh = 0
            if cpu < 25 { alertedThisEpisode = false }   // fully recovered — next episode alerts again
            return
        }
        consecutiveHigh += 1
        guard consecutiveHigh >= samplesToTrigger, !alertedThisEpisode else { return }
        alertedThisEpisode = true
        DebugLog.shared.log("ColorSync alert: pinned at \(Int(cpu))% — warning the user (replug/reboot is the only fix)")
        onRunawayDetected?(cpu)
    }
}
