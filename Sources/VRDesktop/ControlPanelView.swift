import AppKit
import DisplayManager
import GlassesDriver
import SwiftUI

struct ControlPanelView: View {
    @ObservedObject var coordinator: AppCoordinator
    @State private var selectedScreenID: CGDirectDisplayID?
    @State private var moveX = ""
    @State private var moveY = ""
    @State private var showDiagnostics = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                statusCard
                card("AR Output", "display") { outputSection }
                card("Layout", "square.on.square.dashed") { PlacementMapView(coordinator: coordinator) }
                card("Workspace", "square.grid.2x2") { workspaceSection }
                card("Tracking & Testing", "gauge.with.dots.needle.33percent") { testSection }
                card("Permissions", "lock.shield") { permissionsSection }
                card("General", "gearshape") { generalSection }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 460, idealWidth: 540, minHeight: 420, idealHeight: 720)
        .background(Color(nsColor: .windowBackgroundColor))
        .safeAreaInset(edge: .bottom) {
            if !coordinator.statusMessage.isEmpty {
                Text(coordinator.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(.thinMaterial)
            }
        }
    }

    /// A titled card container for a section.
    private func card<Content: View>(_ title: String, _ icon: String,
                                     @ViewBuilder _ content: () -> Content) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        } label: {
            Label(title, systemImage: icon).font(.headline)
        }
    }

    // MARK: Status (header card)

    private var statusCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle().fill(glassesConnected ? Color.green : Color.secondary)
                        .frame(width: 9, height: 9)
                    Text(glassesLabel).font(.headline)
                    Spacer()
                    if coordinator.arActive {
                        Text("AR ON").font(.caption.bold())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.2), in: Capsule())
                    }
                }
                HStack(spacing: 16) {
                    Label(String(format: "%.0f Hz", coordinator.imuRate), systemImage: "gyroscope")
                    Label(String(format: "%.0f fps", coordinator.renderFPS), systemImage: "speedometer")
                }
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Text(String(format: "yaw %+6.1f°   pitch %+6.1f°   roll %+6.1f°",
                            coordinator.euler.yaw, coordinator.euler.pitch, coordinator.euler.roll))
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                if let looking = coordinator.lookedAtScreenName {
                    Label("Looking at: \(looking)", systemImage: "eye")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Recenter") { coordinator.recenter() }
                    Text("⌃⌥Space").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Toggle("Include roll", isOn: $coordinator.recenterRoll)
                        .toggleStyle(.checkbox)
                        .help("Off: horizon stays gravity-level when recentering")
                }
                if coordinator.brightnessAvailable {
                    HStack(spacing: 8) {
                        Image(systemName: "sun.min").foregroundStyle(.secondary)
                        // Device is 0–7; show it as 1–8 to the user.
                        Slider(value: Binding(
                            get: { coordinator.glassesBrightness + 1 },
                            set: { coordinator.glassesBrightness = $0 - 1 }
                        ), in: 1...9, step: 1) { editing in
                            coordinator.editingBrightness = editing
                            if !editing { coordinator.applyBrightness() }
                        }
                        Image(systemName: "sun.max").foregroundStyle(.secondary)
                        Text("\(Int(coordinator.glassesBrightness) + 1)").frame(width: 14).monospacedDigit()
                    }.font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
        }
    }

    private var glassesConnected: Bool {
        if case .connected = coordinator.glassesState { return true }
        return false
    }

    private var glassesLabel: String {
        switch coordinator.glassesState {
        case .disconnected: return "Glasses: not connected"
        case .connected(let p): return p
        case .error(let e): return "Glasses error: \(e)"
        }
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            permissionRow(
                title: "Screen Recording",
                detail: "Capture your displays to show them in AR",
                granted: coordinator.hasScreenRecordingPermission,
                grant: { coordinator.requestScreenRecordingPermission() })
            Divider()
            permissionRow(
                title: "Accessibility",
                detail: "Use ⌃⌥+brightness keys to dim the glasses",
                granted: coordinator.hasAccessibilityPermission,
                grant: { coordinator.requestAccessibilityPermission() })
            Text("Grants take effect after relaunching.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func permissionRow(title: String, detail: String, granted: Bool,
                               grant: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout)
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Text("Granted").font(.caption).foregroundStyle(.green)
            } else {
                Button("Grant…", action: grant).controlSize(.small)
            }
        }
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if coordinator.mirroringActive {
                HStack {
                    Label("A display is mirroring — the glasses need to be extended",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                    Button("Stop mirroring") { coordinator.stopMirroring() }
                }
            }
            Picker("Output screen", selection: $selectedScreenID) {
                Text("None").tag(CGDirectDisplayID?.none)
                ForEach(NSScreen.screens, id: \.self) { screen in
                    Text(screen.localizedName)
                        .tag(CGDirectDisplayID?.some(AppCoordinator.screenDisplayID(screen)))
                }
            }
            .onAppear { validateOutputSelection() }
            .onChange(of: coordinator.screenList) { _ in validateOutputSelection() }
            HStack {
                Button(coordinator.arActive ? "Stop AR" : "Start AR") {
                    if coordinator.arActive {
                        coordinator.stopAR()
                    } else if let id = selectedScreenID,
                              let screen = NSScreen.screens.first(where: { AppCoordinator.screenDisplayID($0) == id }) {
                        coordinator.startAR(on: screen)
                    }
                }
                .disabled(!coordinator.arActive && selectedScreenID == nil)
                if let name = coordinator.outputScreenName {
                    Text("→ \(name)").font(.caption).foregroundStyle(.secondary)
                }
            }

            if coordinator.arActive {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Stereo (SBS) — experimental", isOn: Binding(
                        get: { coordinator.stereoEnabled },
                        set: { coordinator.setStereo($0) }
                    ))
                    .font(.caption)
                    if !coordinator.sbsModeAvailable {
                        Text("No 3840×1080 mode on this display — stereo will render but may look squished")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if coordinator.stereoEnabled {
                        HStack {
                            Text("IPD").frame(width: 30, alignment: .leading).font(.caption)
                            Slider(value: $coordinator.ipdMillimeters, in: 50...75)
                            Text("\(Int(coordinator.ipdMillimeters)) mm").frame(width: 52).font(.caption).monospacedDigit()
                        }
                    }
                }
            }

            DisclosureGroup(isExpanded: $showDiagnostics) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(coordinator.screenList, id: \.self) { line in
                        Text(line).font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    HStack(alignment: .firstTextBaseline) {
                        Text(coordinator.outputWindowInfo)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                        Button("Copy info") {
                            let all = (coordinator.screenList + [coordinator.outputWindowInfo])
                                .joined(separator: "\n")
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(all, forType: .string)
                        }
                        .controlSize(.small)
                    }
                    if coordinator.arActive {
                        HStack {
                            TextField("x", text: $moveX).frame(width: 64)
                            TextField("y", text: $moveY).frame(width: 64)
                            Button("Move window") {
                                if let x = Double(moveX), let y = Double(moveY) {
                                    coordinator.moveOutputWindow(x: x, y: y)
                                }
                            }
                        }.font(.caption)
                    }
                }
                .padding(.top, 4)
            } label: {
                Text("Diagnostics").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @State private var workspaceName = ""

    private var workspaceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("", selection: Binding(
                    get: { coordinator.workspaceStore.activeWorkspaceID },
                    set: { coordinator.selectWorkspace($0) }
                )) {
                    ForEach(coordinator.workspaceStore.workspaces) { ws in
                        Text(ws.name).tag(UUID?.some(ws.id))
                    }
                }
                .labelsHidden()
                Button { coordinator.addWorkspace(); syncWorkspaceName() } label: {
                    Image(systemName: "plus")
                }.help("New workspace")
                Button(role: .destructive) { coordinator.deleteActiveWorkspace(); syncWorkspaceName() } label: {
                    Image(systemName: "trash")
                }
                .help("Delete workspace")
                .disabled(coordinator.workspaceStore.workspaces.count <= 1)
            }

            // Rename the active workspace.
            TextField("Workspace name", text: $workspaceName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { coordinator.renameActiveWorkspace(workspaceName) }
                .onAppear { syncWorkspaceName() }
                .onChange(of: coordinator.workspaceStore.activeWorkspaceID) { _ in syncWorkspaceName() }

            Divider()

            ForEach(coordinator.editableScreens()) { screen in
                ScreenRow(initial: screen,
                          isPhysical: isPhysical(screen.id),
                          lookedAt: coordinator.lookedAtScreenID == screen.id,
                          onChange: { coordinator.updateScreen($0) },
                          onRemove: { coordinator.removeScreen(id: screen.id) })
                    .id(screen.id)
                if !isPhysical(screen.id) {
                    mirrorMenu(for: screen)
                }
            }

            HStack {
                Button("Add 16:9") {
                    let n = (coordinator.workspaceStore.activeWorkspace?.virtualScreens.count ?? 0) + 1
                    coordinator.addVirtualScreen(
                        VirtualScreenConfig(name: "Screen \(n)", width: 2560, height: 1440, hiDPI: true))
                }
                Button("Add ultrawide") {
                    let n = (coordinator.workspaceStore.activeWorkspace?.virtualScreens.count ?? 0) + 1
                    coordinator.addVirtualScreen(
                        VirtualScreenConfig(name: "Ultrawide \(n)", width: 5120, height: 1080,
                                            curvatureRadius: 1.5))
                }
                let physicals = coordinator.availablePhysicalDisplays()
                Menu("Add monitor") {
                    if physicals.isEmpty {
                        Text("No available monitors").disabled(true)
                    }
                    ForEach(physicals, id: \.uuid) { display in
                        Button(display.name) {
                            coordinator.addPhysicalScreen(uuidString: display.uuid, name: display.name)
                        }
                    }
                }
                .frame(width: 130)
            }
            Text("Monitors appear in AR while still showing on the physical screen.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// Drop a selection whose display has gone away, and auto-pick the glasses when present.
    private func validateOutputSelection() {
        let ids = NSScreen.screens.map { AppCoordinator.screenDisplayID($0) }
        if let sel = selectedScreenID, !ids.contains(sel) { selectedScreenID = nil }
        if selectedScreenID == nil { selectedScreenID = coordinator.glassesScreenID() }
    }

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Launch at login", isOn: $coordinator.launchAtLogin)
                .font(.caption)
            Toggle("Keep cursor off the AR screen", isOn: $coordinator.confineCursor)
                .font(.caption)
            Divider()
            Toggle("Write debug log", isOn: $coordinator.debugLogging)
                .font(.caption)
                .help(coordinator.debugLogURL.path)
            if coordinator.debugLogging {
                HStack {
                    Button("Reveal log") { coordinator.revealDebugLog() }
                    Button("Clear log") { coordinator.clearDebugLog() }
                }
                .controlSize(.small)
            }
        }
    }

    private func mirrorMenu(for screen: VirtualScreenConfig) -> some View {
        let targets = coordinator.mirrorTargets()
        let currentName = targets.first { $0.uuid == screen.mirrorToPhysical }?.name
        return HStack(spacing: 6) {
            Image(systemName: "rectangle.on.rectangle.angled").foregroundStyle(.secondary)
            Menu(currentName.map { "Mirroring to \($0)" } ?? "Mirror to monitor: off") {
                Button("Off") { coordinator.setMirrorTarget(screenID: screen.id, physicalUUID: nil) }
                ForEach(targets, id: \.uuid) { target in
                    Button(target.name) {
                        coordinator.setMirrorTarget(screenID: screen.id, physicalUUID: target.uuid)
                    }
                }
            }
            .frame(width: 220)
        }
        .font(.caption)
        .padding(.leading, 24)
    }

    private func syncWorkspaceName() {
        workspaceName = coordinator.workspaceStore.activeWorkspace?.name ?? ""
    }

    private func isPhysical(_ id: UUID) -> Bool {
        coordinator.workspaceStore.activeWorkspace?.physicalInAR.values.contains { $0.id == id } ?? false
    }


    private var testSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            tuningSlider("Calm", $coordinator.minCutoffHz, 0.2...5, unit: "Hz", decimals: 1,
                         help: "lower = calmer at rest (removes heartbeat jitter), but softer on slow moves")
            tuningSlider("Response", $coordinator.betaResponsiveness, 0...2, unit: "", decimals: 2,
                         help: "higher = snappier on fast head turns (less lag)")
            tuningSlider("Prediction", $coordinator.predictionLeadMs, 0...50, unit: "ms", decimals: 0,
                         help: "higher = compensates lag, may overshoot")
            Divider()
            HStack {
                Text("Anti-alias").frame(width: 78, alignment: .leading).font(.caption)
                Picker("", selection: $coordinator.antialiasLevel) {
                    ForEach(coordinator.supportedAALevels, id: \.self) { level in
                        Text(level == 1 ? "Off" : "\(level)×").tag(level)
                    }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            HStack {
                Text("Sharpen").frame(width: 78, alignment: .leading).font(.caption)
                Picker("", selection: $coordinator.sharpenLevel) {
                    Text("Off").tag(1)
                    Text("2×").tag(2)
                    Text("4×").tag(4)
                    Text("8×").tag(8)
                    Text("16×").tag(16)
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            .help("Anisotropic sharpening of captured content (e.g. small text in VS Code); higher = crisper, more GPU")
            HStack {
                Text("Supersample").frame(width: 78, alignment: .leading).font(.caption)
                Picker("", selection: $coordinator.renderScalePercent) {
                    Text("Off").tag(100)
                    Text("1.25×").tag(125)
                    Text("1.5×").tag(150)
                    Text("2×").tag(200)
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            .help("Renders the scene above display resolution then downscales — smooths edges AND keeps text crisp; 2× has real GPU cost")
            Divider()
            Toggle("Fake head pose (no glasses needed)", isOn: $coordinator.useFakePose)
            if coordinator.useFakePose {
                HStack {
                    Text("Yaw").frame(width: 40, alignment: .leading)
                    Slider(value: $coordinator.fakeYawDegrees, in: -120...120)
                    Text("\(Int(coordinator.fakeYawDegrees))°").frame(width: 44).monospacedDigit()
                }
                HStack {
                    Text("Pitch").frame(width: 40, alignment: .leading)
                    Slider(value: $coordinator.fakePitchDegrees, in: -60...60)
                    Text("\(Int(coordinator.fakePitchDegrees))°").frame(width: 44).monospacedDigit()
                }
            }
        }
    }

    private func tuningSlider(_ label: String, _ value: Binding<Double>,
                              _ range: ClosedRange<Double>, unit: String, decimals: Int,
                              help: String) -> some View {
        HStack {
            Text(label).frame(width: 78, alignment: .leading).font(.caption)
            Slider(value: value, in: range)
            Text(String(format: "%.\(decimals)f %@", value.wrappedValue, unit))
                .frame(width: 52).font(.caption).monospacedDigit()
        }
        .help(help)
    }
}

struct ScreenRow: View {
    let initial: VirtualScreenConfig
    var isPhysical: Bool = false
    var lookedAt: Bool = false
    var onChange: (VirtualScreenConfig) -> Void = { _ in }
    var onRemove: () -> Void = {}

    // Local editing state so slider values update live during a drag (the live-update
    // path to the renderer doesn't re-publish, which otherwise froze the UI numbers).
    @State private var cfg: VirtualScreenConfig
    @State private var expanded = false

    init(initial: VirtualScreenConfig, isPhysical: Bool = false, lookedAt: Bool = false,
         onChange: @escaping (VirtualScreenConfig) -> Void = { _ in },
         onRemove: @escaping () -> Void = {}) {
        self.initial = initial
        self.isPhysical = isPhysical
        self.lookedAt = lookedAt
        self.onChange = onChange
        self.onRemove = onRemove
        _cfg = State(initialValue: initial)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Placement", selection: $cfg.placement) {
                    Text("Anchored").tag(ScreenPlacement.anchored)
                    Text("Floating").tag(ScreenPlacement.floating)
                }
                .pickerStyle(.segmented)
                .help("Anchored: fixed in space. Floating: stays in view (yaw/pitch/distance are the offset).")
                slider("Yaw", $cfg.yawDegrees, -180...180, "°")
                slider("Pitch", $cfg.pitchDegrees, -90...90, "°")
                slider("Distance", $cfg.distanceMeters, 0.5...6, "m")
                slider("Scale", $cfg.scale, 0.3...3, "×")
                curveSlider("Curve", $cfg.curvatureRadius, auto: $cfg.autoCurveH)
                HStack {
                    Button("Reset placement") { cfg.resetPlacement() }
                    Button("Remove", role: .destructive) { onRemove() }
                }
                .controlSize(.small)
            }
            .padding(.leading, 8)
        } label: {
            HStack {
                Toggle("", isOn: $cfg.showInAR).labelsHidden()
                Image(systemName: isPhysical ? "display" : "rectangle.on.rectangle")
                    .foregroundStyle(.secondary)
                Text(cfg.name)
                if lookedAt {
                    Image(systemName: "eye.fill").foregroundStyle(.tint).font(.caption)
                }
                Text("\(cfg.width)×\(cfg.height)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: cfg) { newValue in onChange(newValue) }
        .onChange(of: initial) { newValue in if newValue != cfg { cfg = newValue } }
    }

    private func slider(_ label: String, _ value: Binding<Double>,
                        _ range: ClosedRange<Double>, _ unit: String) -> some View {
        HStack {
            Text(label).frame(width: 60, alignment: .leading).font(.caption)
            Slider(value: value, in: range)
            Text(String(format: "%.1f%@", value.wrappedValue, unit))
                .frame(width: 52).font(.caption).monospacedDigit()
        }
    }

    private func curveSlider(_ label: String, _ value: Binding<Double>,
                             auto: Binding<Bool>) -> some View {
        HStack {
            Text(label).frame(width: 60, alignment: .leading).font(.caption)
            Slider(value: value, in: 0...5).disabled(auto.wrappedValue)
            Toggle("auto", isOn: auto).toggleStyle(.checkbox).font(.caption).fixedSize()
            Text(auto.wrappedValue ? "auto" : String(format: "%.1f", value.wrappedValue))
                .frame(width: 34).font(.caption).monospacedDigit()
                .foregroundStyle(auto.wrappedValue ? .secondary : .primary)
        }
    }
}

/// Drag-to-place layout: two zones (anchored "around you" and floating "in view"); each
/// screen is a box you drag to set its yaw (horizontal) and pitch (vertical).
struct PlacementMapView: View {
    @ObservedObject var coordinator: AppCoordinator
    @State private var zoomAnchored = 1.0
    @State private var zoomFloating = 1.0

    // Base half-ranges (degrees). Anchored covers the full sphere; floating only the FOV + margin.
    private static let anchoredYaw = 180.0, anchoredPitch = 90.0
    private static let fovHDeg = 40.0, fovVDeg = 23.0
    private static let floatMargin = 50.0
    private static var floatYaw: Double { fovHDeg / 2 + floatMargin }
    private static var floatPitch: Double { fovVDeg / 2 + floatMargin }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            zone(title: "Around you (anchored)", placement: .anchored, accent: .blue,
                 baseYaw: Self.anchoredYaw, basePitch: Self.anchoredPitch,
                 aspect: 1.0, zoom: $zoomAnchored)               // square
            zone(title: "In view (floating)", placement: .floating, accent: .accentColor,
                 baseYaw: Self.floatYaw, basePitch: Self.floatPitch,
                 aspect: Self.floatYaw / Self.floatPitch, zoom: $zoomFloating) // FOV+margin ratio
            Text("Drag to position. Left↔right = yaw, up↔down = pitch. Use +/− to zoom.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func screens(_ placement: ScreenPlacement) -> [VirtualScreenConfig] {
        coordinator.editableScreens().filter { $0.showInAR && $0.placement == placement }
    }

    private func zone(title: String, placement: ScreenPlacement, accent: Color,
                      baseYaw: Double, basePitch: Double, aspect: Double,
                      zoom: Binding<Double>) -> some View {
        let spaceName = "zone-\(placement.rawValue)"
        let yawRange = baseYaw / zoom.wrappedValue
        let pitchRange = basePitch / zoom.wrappedValue
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { zoom.wrappedValue = max(1, zoom.wrappedValue / 1.25) } label: {
                    Image(systemName: "minus.magnifyingglass")
                }.disabled(zoom.wrappedValue <= 1.0001)
                Button { zoom.wrappedValue = min(6, zoom.wrappedValue * 1.25) } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
            }
            .buttonStyle(.borderless).controlSize(.small)
            GeometryReader { geo in
                // Equal pixels-per-degree on both axes (no squish); pitch maps about centre.
                let ppd = geo.size.width / CGFloat(2 * yawRange)
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.12))
                    Rectangle().fill(.white.opacity(0.08)).frame(width: 1)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    // Field-of-view outline (what the glasses can show at once), centred.
                    if placement == .floating {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(.green.opacity(0.6),
                                          style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                            .frame(width: CGFloat(Self.fovHDeg) * ppd, height: CGFloat(Self.fovVDeg) * ppd)
                            .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    }
                    ForEach(screens(placement)) { cfg in
                        ScreenBox(initial: cfg, area: geo.size, coordinateSpace: spaceName,
                                  accent: accent, pxPerDeg: ppd,
                                  yawRange: yawRange, pitchRange: pitchRange,
                                  lookedAt: coordinator.lookedAtScreenID == cfg.id,
                                  onChange: { coordinator.updateScreen($0) })
                    }
                }
                .coordinateSpace(name: spaceName)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .aspectRatio(aspect, contentMode: .fit)
            .frame(maxWidth: 360)
        }
    }
}

private struct ScreenBox: View {
    let initial: VirtualScreenConfig
    let area: CGSize
    let coordinateSpace: String
    let accent: Color
    let pxPerDeg: CGFloat
    let yawRange: Double
    let pitchRange: Double
    let lookedAt: Bool
    var onChange: (VirtualScreenConfig) -> Void

    @State private var cfg: VirtualScreenConfig

    init(initial: VirtualScreenConfig, area: CGSize, coordinateSpace: String, accent: Color,
         pxPerDeg: CGFloat, yawRange: Double, pitchRange: Double,
         lookedAt: Bool, onChange: @escaping (VirtualScreenConfig) -> Void) {
        self.initial = initial
        self.area = area
        self.coordinateSpace = coordinateSpace
        self.accent = accent
        self.pxPerDeg = pxPerDeg
        self.yawRange = yawRange
        self.pitchRange = pitchRange
        self.lookedAt = lookedAt
        self.onChange = onChange
        _cfg = State(initialValue: initial)
    }

    private func point() -> CGPoint {
        // Centre-based with equal scale on both axes; +yaw to the left (flip), +pitch up.
        CGPoint(x: area.width / 2 - CGFloat(cfg.yawDegrees) * pxPerDeg,
                y: area.height / 2 - CGFloat(cfg.pitchDegrees) * pxPerDeg)
    }

    private func apply(location: CGPoint) {
        let yaw = Double((area.width / 2 - location.x) / pxPerDeg)
        let pitch = Double((area.height / 2 - location.y) / pxPerDeg)
        cfg.yawDegrees = min(yawRange, max(-yawRange, yaw))
        cfg.pitchDegrees = min(pitchRange, max(-pitchRange, pitch))
        onChange(cfg)
    }

    // Apparent width in metres — must match AppCoordinator.sceneScreen.
    private static let metersPerScreen = 1.6

    var body: some View {
        // Size the box by the screen's real angular extent (degrees of FOV) so gaps/overlap
        // in the map match AR — which depends on distance, not just aspect.
        let widthMeters = Double(cfg.width) / 1920.0 * Self.metersPerScreen * cfg.scale
        let aspect = Double(cfg.width) / Double(max(1, cfg.height))
        let heightMeters = widthMeters / aspect
        let dist = max(0.1, cfg.distanceMeters)
        let angW = 2 * atan((widthMeters / 2) / dist) * 180 / .pi
        let angH = 2 * atan((heightMeters / 2) / dist) * 180 / .pi
        let w = max(14, CGFloat(angW) * pxPerDeg)
        let h = max(10, CGFloat(angH) * pxPerDeg)
        return RoundedRectangle(cornerRadius: 4)
            .fill(accent.opacity(0.45))
            .overlay(
                Text(cfg.name).font(.system(size: 9)).lineLimit(1)
                    .padding(.horizontal, 3).foregroundStyle(.white))
            .overlay(RoundedRectangle(cornerRadius: 4)
                .strokeBorder(lookedAt ? Color.yellow : .white.opacity(0.5), lineWidth: lookedAt ? 2 : 1))
            .frame(width: w, height: h)
            .position(point())
            .gesture(
                DragGesture(coordinateSpace: .named(coordinateSpace))
                    .onChanged { apply(location: $0.location) }
            )
            .onChange(of: initial) { newValue in if newValue != cfg { cfg = newValue } }
    }
}
