import Foundation

/// Always-on guard against the macOS ColorSync runaway: `colorsync.displayservices` periodically
/// gets stuck re-parsing the display registry and pins a CPU core at ~75%, which makes the whole
/// machine sluggish after a few hours (AR frames drop, the cursor stutters). See
/// `Docs/ColorSync-AirII-investigation.md`.
///
/// The watchdog samples the daemon's CPU on a slow timer; when it stays pinned for a sustained
/// window it remediates by (1) sweeping orphaned per-display profiles and (2) bouncing the ColorSync
/// daemons so launchd relaunches them clean (root-only, via the privileged helper). It's rate-limited
/// so it can't thrash the daemons, and if remediation repeatedly fails to settle things — the pure
/// Air-2 self-loop, which only unplugging the glasses or a reboot cures — it gives up and reports it
/// once via `onPersistentRunaway` rather than looping forever.
@MainActor
final class ColorSyncWatchdog {
    /// Sustained CPU (%) of colorsync.displayservices that counts as "pinned". The runaway sits at
    /// ~74%; benign AR-time bursts peak ~30–53% and decay, so 65% over several samples avoids them.
    private let pinThreshold = 65.0
    /// Consecutive over-threshold samples before remediating (× interval = sustained time required).
    private let samplesToTrigger = 3
    private let interval: TimeInterval = 30
    /// Minimum seconds between two remediations, so the daemons aren't bounced every tick.
    private let remediationCooldown: TimeInterval = 300
    /// After this many remediations that don't settle it, stop bouncing and warn the user once.
    private let maxRemediations = 3

    /// Called (once per runaway episode) when remediation has repeatedly failed — the OS-side Air-2
    /// self-loop that only a replug/reboot fixes. The app surfaces this to the user.
    var onPersistentRunaway: (() -> Void)?

    private var timer: Timer?
    private var consecutiveHigh = 0
    private var lastRemediation = Date.distantPast
    private var failedRemediations = 0
    private var warnedUser = false

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
        DebugLog.shared.log("ColorSync watchdog on (≥\(Int(self.pinThreshold))% for \(self.samplesToTrigger)×\(Int(self.interval))s → remediate)")
    }

    private func stop() {
        timer?.invalidate(); timer = nil
        consecutiveHigh = 0
        DebugLog.shared.log("ColorSync watchdog off")
    }

    private func tick() {
        // ps + the file scan inside remediation are cheap but not free — sample off-main.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let cpu = SystemHealth.processCPU(matching: ["colorsync.displayservices"]).first?.cpu ?? 0
            DispatchQueue.main.async { self?.evaluate(cpu: cpu) }
        }
    }

    private func evaluate(cpu: Double) {
        guard cpu >= pinThreshold else {
            consecutiveHigh = 0
            // Fully recovered — reset the episode so a future runaway starts its attempt count clean.
            if cpu < 25 { failedRemediations = 0; warnedUser = false }
            return
        }
        consecutiveHigh += 1
        guard consecutiveHigh >= samplesToTrigger else { return }
        consecutiveHigh = 0
        remediate(cpu: cpu)
    }

    private func remediate(cpu: Double) {
        let now = Date()
        guard now.timeIntervalSince(lastRemediation) >= remediationCooldown else { return }

        // Tried enough times without it settling → it's the OS-side Air-2 self-loop. Warn once, stop.
        if failedRemediations >= maxRemediations {
            if !warnedUser {
                warnedUser = true
                DebugLog.shared.log("ColorSync watchdog: runaway persists after \(self.maxRemediations) remediations — likely the Air 2 self-loop (needs replug/reboot)")
                onPersistentRunaway?()
            }
            return
        }
        lastRemediation = now
        failedRemediations += 1

        let removed = SystemHealth.sweepOrphanProfiles()
        DebugLog.shared.log("ColorSync watchdog: pinned at \(Int(cpu))% — swept \(removed) orphan profile(s), bouncing daemons (attempt \(self.failedRemediations)/\(self.maxRemediations))")
        PrivilegedHelperClient.shared.bounceColorSyncDaemons { ok in
            DebugLog.shared.log("ColorSync watchdog: daemon bounce \(ok ? "done" : "unavailable (helper not approved?)")")
        }
    }
}
