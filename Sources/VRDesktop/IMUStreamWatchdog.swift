import Foundation

/// Detector for a silently dead IMU stream (issue #3): the glasses' display link is fine and the
/// device is "connected", but no head-tracking samples arrive — so anchored screens freeze at the
/// last pose and behave exactly like follow mode, with no error anywhere. Two known causes: the
/// glasses' own onboard follow/smoothing mode (some firmwares stop streaming raw IMU to the host),
/// and a wedged HID/network stream after an unplug–re-wear cycle. The driver can't see either —
/// `device_imu_read` just times out forever without returning an error.
///
/// This is a pure state machine, deliberately not self-timed: it is fed the already-computed IMU
/// rate from `AppCoordinator.updateStats()`'s 0.5s tick (a second reader of the PoseStore sample
/// delta would corrupt both rates). Episode semantics follow the ColorSyncWatchdog precedent:
/// consecutive-sample trigger, one alert per episode, re-arm only after recovery.
///
/// Escalation ladder per episode: after `ticksToStall` stalled ticks it requests an IMU restart
/// (up to `maxRestartAttempts`, each followed by a grace window and a fresh accumulation), and only
/// when all restarts fail does it fire `onStallAlert`. Any healthy tick recovers the episode.
@MainActor
final class IMUStreamWatchdog {
    /// Below this the stream counts as stalled. Healthy streams run ~500–1000 Hz; > 0 rather than
    /// == 0 so a stray straggler sample in a 0.5s window can't mask a dead stream.
    private let stallRateHz = 5.0
    /// Consecutive stalled ticks (× the 0.5s stats tick) before acting — 4 ticks = 2s.
    private let ticksToStall = 4
    /// Restart attempts before alerting the user.
    private let maxRestartAttempts = 3
    /// Ignore ticks for this long after AR start / wake / each restart attempt, so device reopen
    /// and USB re-enumeration can't read as a stall.
    private let graceAfterRestart: TimeInterval = 5

    /// Called for each automatic restart attempt (1-based attempt number).
    var onRestartRequested: ((Int) -> Void)?
    /// Called once per episode when all restart attempts have failed to revive the stream.
    var onStallAlert: (() -> Void)?
    /// Called when a previously-alerted episode recovers (samples flowing again).
    var onRecovered: (() -> Void)?

    var enabled = true

    private var consecutiveStalled = 0
    private var restartAttempts = 0
    private var alertedThisEpisode = false
    private var graceUntil: TimeInterval = 0

    /// Suppress evaluation until `now + seconds` — call on AR start, system wake, and display-mode
    /// switches, where a rate gap is expected and benign.
    func deferChecks(for seconds: TimeInterval, now: TimeInterval) {
        graceUntil = max(graceUntil, now + seconds)
    }

    /// Forget the current episode (counters, attempts, alert latch). Call on AR stop.
    func reset() {
        consecutiveStalled = 0
        restartAttempts = 0
        alertedThisEpisode = false
        graceUntil = 0
    }

    /// Feed one stats tick. `rate` is the measured IMU sample rate (Hz); `gatesOpen` is whether a
    /// stall would be abnormal right now (AR active, glasses connected, not mid mode-switch).
    func evaluate(rate: Double, gatesOpen: Bool, now: TimeInterval) {
        guard enabled, gatesOpen else {
            consecutiveStalled = 0
            return
        }

        if rate >= stallRateHz {
            consecutiveStalled = 0
            restartAttempts = 0
            if alertedThisEpisode {          // recovered — next episode can alert again
                alertedThisEpisode = false
                onRecovered?()
            }
            return
        }

        guard now >= graceUntil else { return }
        consecutiveStalled += 1
        guard consecutiveStalled >= ticksToStall else { return }
        consecutiveStalled = 0

        if restartAttempts < maxRestartAttempts {
            restartAttempts += 1
            deferChecks(for: graceAfterRestart, now: now)
            onRestartRequested?(restartAttempts)
        } else if !alertedThisEpisode {
            alertedThisEpisode = true
            onStallAlert?()
        }
    }
}
