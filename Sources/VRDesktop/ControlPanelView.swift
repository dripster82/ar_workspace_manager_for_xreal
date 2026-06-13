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

    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, newValue in LaunchAtLogin.set(newValue) }
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
                slider("Yaw", $cfg.yawDegrees, -150...150, "°")
                slider("Pitch", $cfg.pitchDegrees, -60...60, "°")
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
