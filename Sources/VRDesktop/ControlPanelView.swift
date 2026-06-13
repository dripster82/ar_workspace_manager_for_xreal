import AppKit
import DisplayManager
import GlassesDriver
import SwiftUI

struct ControlPanelView: View {
    @ObservedObject var coordinator: AppCoordinator
    @State private var selectedScreenID: CGDirectDisplayID?
    @State private var moveX = ""
    @State private var moveY = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            statusSection
            Divider()
            outputSection
            Divider()
            workspaceSection
            Divider()
            testSection
            if !coordinator.statusMessage.isEmpty {
                Text(coordinator.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 600)
    }

    // MARK: Sections

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(glassesLabel, systemImage: glassesConnected ? "eyeglasses" : "eyeglasses.slash")
                .font(.headline)
            HStack(spacing: 16) {
                Text(String(format: "IMU %.0f Hz", coordinator.imuRate)).monospacedDigit()
                Text(String(format: "Render %.0f fps", coordinator.renderFPS)).monospacedDigit()
            }.font(.caption)
            Text(String(format: "yaw %+7.1f°  pitch %+6.1f°  roll %+6.1f°",
                        coordinator.euler.yaw, coordinator.euler.pitch, coordinator.euler.roll))
                .font(.system(.caption, design: .monospaced))
            HStack {
                Button("Recenter (⌃⌥Space)") { coordinator.recenter() }
                Toggle("Include roll", isOn: $coordinator.recenterRoll)
                    .help("Off: horizon stays gravity-level when recentering")
            }
            if coordinator.brightnessAvailable {
                HStack {
                    Image(systemName: "sun.min")
                    Slider(value: $coordinator.glassesBrightness, in: 0...7, step: 1) { editing in
                        if !editing { coordinator.applyBrightness() }
                    }
                    Image(systemName: "sun.max")
                    Text("\(Int(coordinator.glassesBrightness))").frame(width: 16).monospacedDigit()
                }.font(.caption)
            }
        }
    }

    private var glassesConnected: Bool {
        if case .connected = coordinator.glassesState { return true }
        return false
    }

    private var glassesLabel: String {
        switch coordinator.glassesState {
        case .disconnected: return "Glasses: not connected"
        case .connected(let p): return "Glasses: \(p)"
        case .error(let e): return "Glasses error: \(e)"
        }
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AR Output").font(.headline)
            if !coordinator.hasScreenRecordingPermission {
                HStack {
                    Label("Screen Recording permission needed to capture displays",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                    Button("Grant permission…") { coordinator.requestScreenRecordingPermission() }
                }
            }
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

            // Diagnostics: screen layout + live window placement & manual move.
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
        }
    }

    @State private var workspaceName = ""

    private var workspaceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Workspace").font(.headline)
                Spacer()
                Picker("", selection: Binding(
                    get: { coordinator.workspaceStore.activeWorkspaceID },
                    set: { coordinator.selectWorkspace($0) }
                )) {
                    ForEach(coordinator.workspaceStore.workspaces) { ws in
                        Text(ws.name).tag(UUID?.some(ws.id))
                    }
                }
                .frame(width: 160)
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

            ForEach(coordinator.editableScreens()) { screen in
                ScreenRow(initial: screen,
                          isPhysical: isPhysical(screen.id),
                          onChange: { coordinator.updateScreen($0) },
                          onRemove: { coordinator.removeScreen(id: screen.id) })
                    .id(screen.id)
            }

            HStack {
                Button("Add 16:9") {
                    let n = (coordinator.workspaceStore.activeWorkspace?.virtualScreens.count ?? 0) + 1
                    coordinator.addVirtualScreen(
                        VirtualScreenConfig(name: "Screen \(n)", width: 2560, height: 1440))
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

    private func syncWorkspaceName() {
        workspaceName = coordinator.workspaceStore.activeWorkspace?.name ?? ""
    }

    private func isPhysical(_ id: UUID) -> Bool {
        coordinator.workspaceStore.activeWorkspace?.physicalInAR.values.contains { $0.id == id } ?? false
    }


    private var testSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tracking feel").font(.headline)
            tuningSlider("Smoothing", $coordinator.orientationSmoothingMs, 0...80,
                         help: "higher = smoother, laggier")
            tuningSlider("Vel. smooth", $coordinator.velocitySmoothingMs, 0...200,
                         help: "smooths the prediction input")
            tuningSlider("Prediction", $coordinator.predictionLeadMs, 0...50,
                         help: "higher = compensates lag, may overshoot")
            Divider()
            Text("Testing").font(.headline)
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
                              _ range: ClosedRange<Double>, help: String) -> some View {
        HStack {
            Text(label).frame(width: 78, alignment: .leading).font(.caption)
            Slider(value: value, in: range)
            Text("\(Int(value.wrappedValue)) ms").frame(width: 48).font(.caption).monospacedDigit()
        }
        .help(help)
    }
}

struct ScreenRow: View {
    let initial: VirtualScreenConfig
    var isPhysical: Bool = false
    var onChange: (VirtualScreenConfig) -> Void = { _ in }
    var onRemove: () -> Void = {}

    // Local editing state so slider values update live during a drag (the live-update
    // path to the renderer doesn't re-publish, which otherwise froze the UI numbers).
    @State private var cfg: VirtualScreenConfig
    @State private var expanded = false

    init(initial: VirtualScreenConfig, isPhysical: Bool = false,
         onChange: @escaping (VirtualScreenConfig) -> Void = { _ in },
         onRemove: @escaping () -> Void = {}) {
        self.initial = initial
        self.isPhysical = isPhysical
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
                curveSlider("V. curve", $cfg.verticalCurve, auto: $cfg.autoCurveV)
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
