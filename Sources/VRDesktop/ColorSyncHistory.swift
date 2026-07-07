import AppKit

/// Rolling 3-hour history of `colorsync.displayservices` CPU, sampled every 10 s from app launch
/// (so the Diagnostics graph has data whenever you look, not just after opening the page). The
/// burst-vs-wedge signature only reads at this timescale: benign bursts are ~2–3 min cycles,
/// a wedge is a sustained plateau — a single live percentage can't show the difference.
/// Its own ObservableObject so only the chart view re-renders on each sample.
@MainActor
final class ColorSyncHistory: ObservableObject {
    struct Point: Identifiable {
        let id = UUID()
        let time: Date
        let cpu: Double
    }

    static let window: TimeInterval = 3 * 3600
    static let interval: TimeInterval = 10

    @Published private(set) var points: [Point] = []
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        sample()
        let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func sample() {
        // ps is cheap but not free — sample off-main (same pattern as ColorSyncWatchdog).
        DispatchQueue.global(qos: .utility).async {
            let cpu = SystemHealth.processCPU(matching: ["colorsync.displayservices"]).first?.cpu ?? 0
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let now = Date()
                self.points.append(Point(time: now, cpu: cpu))
                let cutoff = now.addingTimeInterval(-Self.window)
                if let i = self.points.firstIndex(where: { $0.time >= cutoff }), i > 0 {
                    self.points.removeFirst(i)
                }
            }
        }
    }
}
