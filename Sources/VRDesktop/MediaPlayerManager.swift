import AVFoundation
import CapturePipeline
import Compositor
import Metal
import SwiftUI

/// A head-locked video player with a playlist, pinned to one of five FOV positions: the four corners
/// (like the window hotspots) or full-FOV. Decodes with `AVPlayer` and renders as a head-locked
/// `SceneScreen` (corners) or a fullscreen blit (full view) — no ScreenCaptureKit, so none of the
/// screen-recording/DRM blackout. Sources are file URLs — local disk or a mounted network drive.
@MainActor
final class MediaPlayerManager: ObservableObject {
    enum Position: Int, CaseIterable, Identifiable {
        case off = 0, topLeft = 1, topRight = 2, bottomLeft = 3, bottomRight = 4, fullFOV = 5
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .off: return "Off"
            case .topLeft: return "Top-left"
            case .topRight: return "Top-right"
            case .bottomLeft: return "Bottom-left"
            case .bottomRight: return "Bottom-right"
            case .fullFOV: return "Full view"
            }
        }
    }

    struct Item: Identifiable, Hashable {
        let id = UUID()
        let url: URL
        /// Probed asynchronously (VLC header parse) when the item is added; nil until known.
        var duration: Double?
        var name: String { url.lastPathComponent }
    }

    /// Placement of a pinned screen: centre (yaw/pitch, radians; +yaw = left, +pitch = up), distance,
    /// and the max box (metres) the video is fit inside (aspect-preserved).
    private struct Slot { let yaw: Float; let pitch: Float; let distance: Float; let maxW: Float; let maxH: Float }

    @Published private(set) var position: Position = .fullFOV
    @Published private(set) var playing = false
    @Published private(set) var playlist: [Item] = []
    @Published private(set) var currentIndex: Int?
    /// Shown in the Media page when a file can't be played (unsupported container, missing file, …).
    @Published var errorMessage: String?
    /// Loop the playlist: when the last item ends, continue from the first (with shuffle, refill the
    /// shuffle order and keep going). Persisted.
    @Published var loopPlaylist: Bool = UserDefaults.standard.bool(forKey: "media.loop") {
        didSet { UserDefaults.standard.set(loopPlaylist, forKey: "media.loop") }
    }
    /// Play items in random order (no repeats until every item has played once). Persisted.
    @Published var shuffle: Bool = UserDefaults.standard.bool(forKey: "media.shuffle") {
        didSet {
            UserDefaults.standard.set(shuffle, forKey: "media.shuffle")
            if shuffle { refillShuffleBag() }
        }
    }
    /// Remaining not-yet-played indices for shuffle mode; refilled when exhausted (if looping) or
    /// when the playlist/shuffle state changes.
    private var shuffleBag: [Int] = []
    /// True from load until the first frame is decodable — network files can take a while, so the
    /// UI shows a spinner (and AR a "Loading…" card) instead of sitting silently blank.
    @Published private(set) var loading = false
    /// Fired with the item name when a load starts, nil when it's ready/failed (drives the AR card).
    var onLoading: ((String?) -> Void)?

    /// Playback is gated on AR being active (no point decoding when the glasses aren't showing it) and
    /// on the user's intent — so the video only plays in AR and pauses when AR stops.
    private var arActive = false
    private var wantsPlay = false

    // SPIKE: VLC backend (plays MKV/AVI/etc. and renders subtitles uniformly). The AVFoundation
    // backend (`MediaPlayerSource`) exposes the identical API — swap the type to switch back.
    private let source: VLCPlayerSource
    private let sceneID = UUID(uuidString: "0000B0B0-0000-0000-0000-0000000000A1")!
    /// Called when the pinned screen needs rebuilding (position/media change), so the owner re-renders.
    var onChange: (() -> Void)?
    /// Called with a user-facing message when a file can't be played.
    var onError: ((String) -> Void)?

    private var saveTimer: Timer?

    init(device: MTLDevice) {
        source = VLCPlayerSource(device: device)
        source.onEnded = { [weak self] in self?.handleEnded() }  // advance, or stop cleanly at the end
        source.onReady = { [weak self] in                        // rebuild scene once frames exist
            guard let self else { return }
            self.loading = false
            self.onLoading?(nil)
            self.onChange?()
        }
        source.onError = { [weak self] msg in
            guard let self else { return }
            self.errorMessage = msg
            self.loading = false
            self.onLoading?(nil)
            self.wantsPlay = false; self.playing = false
            self.onChange?()   // drop the (blank) screen → black
            self.onError?(msg)
        }
        restore()
        // Persist the play position every few seconds so a resume is at most a few seconds off.
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveTime() }
        }
        RunLoop.main.add(t, forMode: .common)
        saveTimer = t
    }

    // MARK: Persistence

    private enum Key {
        static let playlist = "media.playlist", index = "media.index"
        static let position = "media.position", time = "media.time"
    }

    private func persist() {
        let d = UserDefaults.standard
        d.set(playlist.map { $0.url.absoluteString }, forKey: Key.playlist)
        d.set(currentIndex ?? -1, forKey: Key.index)
        d.set(position.rawValue, forKey: Key.position)
    }

    private func saveTime() {
        // Only persist a MEANINGFUL position: during load/priming libvlc reports -1/0, and the 3s
        // timer used to overwrite the saved resume point with ~0 right after every launch — quit
        // (or update the app) inside that window and the resume data was lost.
        guard source.hasMedia, source.isReady else { return }
        let t = source.currentTime
        guard t > 0 else { return }
        UserDefaults.standard.set(t, forKey: Key.time)
    }

    /// Restore the saved playlist + position + resume point on launch. The current item is loaded
    /// PAUSED at its saved time, so pressing Play (or ⌃⌥K) picks up where you left off.
    private func restore() {
        let d = UserDefaults.standard
        guard let paths = d.stringArray(forKey: Key.playlist), !paths.isEmpty else { return }
        playlist = paths.compactMap { URL(string: $0) }.map { Item(url: $0) }
        playlist.forEach { probeDuration($0) }
        if let p = Position(rawValue: d.integer(forKey: Key.position)) { position = p }
        let idx = d.integer(forKey: Key.index)
        if playlist.indices.contains(idx) {
            currentIndex = idx
            loading = true   // cleared by onReady once the resume frame is decoded
            restoredResumeTime = d.double(forKey: Key.time)
            source.load(url: playlist[idx].url, startAt: restoredResumeTime, autoplay: false)
            playing = false
        }
    }

    var hasMedia: Bool { source.hasMedia }
    var currentName: String? { currentIndex.flatMap { playlist.indices.contains($0) ? playlist[$0].name : nil } }
    /// The resume position restored at launch. libvlc reports position 0 until playback actually
    /// runs (the :start-time seek applies at play), so the UI would read 0:00 before the first
    /// Play — this fills the gap. Cleared once real playback reports a position.
    private var restoredResumeTime: Double = 0
    /// Playback position for the scrubber / progress bar.
    var progress: (current: Double, duration: Double) {
        let c = source.currentTime
        return (c > 0.5 ? c : max(c, restoredResumeTime), source.duration)
    }

    // MARK: Playlist

    /// Add files to the playlist; start playing the first new one if nothing is playing yet.
    func addFiles(_ urls: [URL]) {
        let wasEmpty = playlist.isEmpty
        let items = urls.map { Item(url: $0) }
        playlist.append(contentsOf: items)
        items.forEach { probeDuration($0) }
        if shuffle { refillShuffleBag() }   // new items join the pool
        if wasEmpty, let first = playlist.indices.first { play(at: first) }
        persist()
        onChange?()
    }

    /// Fill in an item's duration via a cheap VLC header parse (async, main-queue completion).
    private func probeDuration(_ item: Item) {
        source.probeDuration(url: item.url) { [weak self] duration in
            guard let self, let duration,
                  let idx = self.playlist.firstIndex(where: { $0.id == item.id }) else { return }
            self.playlist[idx].duration = duration
        }
    }

    func play(at index: Int) {
        guard playlist.indices.contains(index) else { return }
        // Clicking the item that's already loaded RESUMES it (post-restart, the restored item sits
        // paused at its saved position — a row click used to reload it from zero, losing the resume
        // point). Only choosing a different item, or re-clicking one that failed to load, reloads.
        if index == currentIndex, source.hasMedia, errorMessage == nil {
            wantsPlay = true
            applyPlayback()
            onChange?()
            return
        }
        currentIndex = index
        errorMessage = nil
        loading = true
        restoredResumeTime = 0   // a newly chosen item starts fresh
        onLoading?(playlist[index].name)
        source.load(url: playlist[index].url, autoplay: false)   // applyPlayback decides
        wantsPlay = true
        applyPlayback()
        UserDefaults.standard.set(0.0, forKey: Key.time)   // a newly chosen item starts at the beginning
        persist()
        onChange?()
    }

    /// Start/stop the actual decode based on AR being active, user intent, and a visible position.
    /// `playing` reflects the INTENT we just applied, not `source.isPlaying` — libvlc changes state
    /// asynchronously, so querying immediately returns the OLD state and the UI showed play/pause
    /// inverted (pause icon while playing, play icon while paused) until the next transport action.
    private func applyPlayback() {
        let shouldPlay = arActive && wantsPlay && position != .off && source.hasMedia
        if shouldPlay { source.play() } else { source.pause() }
        playing = shouldPlay
    }

    /// Called by the coordinator on AR start/stop — the video only plays while AR is running.
    func setAR(active: Bool) { arActive = active; applyPlayback() }

    func removeItem(_ id: Item.ID) {
        guard let idx = playlist.firstIndex(where: { $0.id == id }) else { return }
        let wasCurrent = idx == currentIndex
        playlist.remove(at: idx)
        if let c = currentIndex {
            if idx < c { currentIndex = c - 1 }
            else if wasCurrent {
                currentIndex = nil; source.stop(); playing = false
                clearLoading()   // removing the item that was still loading
            }
        }
        if shuffle { refillShuffleBag() }   // indices shifted — rebuild the pool
        persist()
        onChange?()
    }

    func move(from: IndexSet, to: Int) {
        let currentID = currentIndex.flatMap { playlist.indices.contains($0) ? playlist[$0].id : nil }
        playlist.move(fromOffsets: from, toOffset: to)
        currentIndex = currentID.flatMap { id in playlist.firstIndex { $0.id == id } }
        if shuffle { refillShuffleBag() }   // indices reordered — rebuild the pool
        persist()
        onChange?()
    }

    private func refillShuffleBag() {
        shuffleBag = Array(playlist.indices).filter { $0 != currentIndex }.shuffled()
    }

    /// The index to play next, honouring shuffle and loop. nil = nothing left (stop).
    private func nextIndex() -> Int? {
        guard !playlist.isEmpty else { return nil }
        if shuffle {
            // Drop indices invalidated by playlist edits.
            shuffleBag.removeAll { !playlist.indices.contains($0) }
            if shuffleBag.isEmpty {
                guard loopPlaylist else { return nil }
                refillShuffleBag()
                if shuffleBag.isEmpty { return currentIndex }   // single-item playlist: loop it
            }
            return shuffleBag.isEmpty ? nil : shuffleBag.removeFirst()
        }
        if let c = currentIndex, c + 1 < playlist.count { return c + 1 }
        return loopPlaylist ? 0 : nil
    }

    func next() {
        guard let i = nextIndex() else { return }
        play(at: i)
    }

    func previous() {
        guard let c = currentIndex, c - 1 >= 0 else { return }
        play(at: c - 1)
    }

    // MARK: Transport

    func togglePlay() { wantsPlay.toggle(); applyPlayback(); saveTime() }

    /// End-of-item: advance through the playlist; at the end, stop cleanly so the state (and the
    /// playlist icon) doesn't stay "playing" forever on a finished list.
    private func handleEnded() {
        if let i = nextIndex() {
            play(at: i)
        } else {
            wantsPlay = false
            playing = false
            onChange?()
        }
    }
    func skip(_ seconds: Double) { source.seek(by: seconds) }
    func seek(to seconds: Double) { restoredResumeTime = seconds; source.seek(to: seconds); saveTime() }
    func clearError() { errorMessage = nil }

    /// Stop playing and hide the media screen, but KEEP the playlist. The current video stays loaded
    /// at its position, so choosing a position again + Play resumes where you left off.
    func stop() {
        wantsPlay = false
        position = .off
        applyPlayback()   // pauses (position is .off)
        clearLoading()    // hide any in-flight loading indicator (screen is hidden anyway)
        saveTime()
        persist()
        onChange?()
    }

    /// Empty the playlist and unload everything (an explicit "clear", separate from Stop).
    func clearPlaylist() {
        source.stop()
        playlist = []
        currentIndex = nil
        wantsPlay = false
        playing = false
        clearLoading()    // a clear mid-load left the spinner running forever
        UserDefaults.standard.set(0.0, forKey: Key.time)
        persist()
        onChange?()
    }

    /// Reset the loading indicator (panel spinner + AR card).
    private func clearLoading() {
        loading = false
        onLoading?(nil)
    }

    func setPosition(_ p: Position) {
        position = p
        applyPlayback()   // .off pauses; a visible position resumes if the user wants it and AR is on
        persist()
        onChange?()
    }

    // MARK: Rendering

    /// Full-FOV stretches over the whole display via the renderer's fullscreen blit; returns that
    /// texture provider when Full view is active.
    func fullscreenProvider() -> (() -> MTLTexture?)? {
        guard position == .fullFOV, source.isReady else { return nil }   // isReady → no blank box
        return { [weak source] in source?.latestTexture }
    }

    /// The head-locked corner `SceneScreen` for positions 1–4, or nil (off / not-ready / full-FOV).
    func sceneScreen() -> SceneScreen? {
        guard position != .off, position != .fullFOV, source.isReady else { return nil }
        let slot = Self.slot(for: position)
        let aspect = max(0.1, source.aspect)
        let width = (aspect >= slot.maxW / slot.maxH) ? slot.maxW : slot.maxH * aspect
        return SceneScreen(
            id: sceneID,
            yaw: slot.yaw, pitch: slot.pitch, distance: slot.distance,
            widthMeters: width, aspect: aspect,
            curveH: 0, autoCurveH: false,
            headLocked: true,
            textureProvider: { [weak source] in source?.latestTexture })
    }

    private static func slot(for p: Position) -> Slot {
        switch p {
        case .topLeft:     return Slot(yaw:  0.2496, pitch:  0.1292, distance: 1.4, maxW: 0.26, maxH: 0.17)
        case .topRight:    return Slot(yaw: -0.2496, pitch:  0.1292, distance: 1.4, maxW: 0.26, maxH: 0.17)
        case .bottomLeft:  return Slot(yaw:  0.2496, pitch: -0.1292, distance: 1.4, maxW: 0.26, maxH: 0.17)
        case .bottomRight: return Slot(yaw: -0.2496, pitch: -0.1292, distance: 1.4, maxW: 0.26, maxH: 0.17)
        case .fullFOV, .off:
            return Slot(yaw: 0, pitch: 0, distance: 1.4, maxW: 1.40, maxH: 0.78)
        }
    }
}
