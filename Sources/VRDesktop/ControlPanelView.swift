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

    private var workspaceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Workspace").font(.headline)
                Spacer()
                Picker("", selection: Binding(
                    get: { coordinator.workspaceStore.activeWorkspaceID },
                    set: { coordinator.workspaceStore.activeWorkspaceID = $0
                           coordinator.saveWorkspaces()
                           coordinator.objectWillChange.send() }
                )) {
                    ForEach(coordinator.workspaceStore.workspaces) { ws in
                        Text(ws.name).tag(UUID?.some(ws.id))
                    }
                }
                .frame(width: 180)
            }

            if var workspace = coordinator.workspaceStore.activeWorkspace {
                ForEach(workspace.virtualScreens) { screen in
                    ScreenRow(config: binding(for: screen.id))
                }
                HStack {
                    Button("Add 16:9 screen") {
                        workspace.virtualScreens.append(
                            VirtualScreenConfig(name: "Screen \(workspace.virtualScreens.count + 1)",
                                                width: 2560, height: 1440))
                        coordinator.workspaceStore.activeWorkspace = workspace
                        coordinator.saveWorkspaces()
                        coordinator.objectWillChange.send()
                    }
                    Button("Add ultrawide") {
                        workspace.virtualScreens.append(
                            VirtualScreenConfig(name: "Ultrawide \(workspace.virtualScreens.count + 1)",
                                                width: 5120, height: 1080,
                                                curvatureRadius: 2.0))
                        coordinator.workspaceStore.activeWorkspace = workspace
                        coordinator.saveWorkspaces()
                        coordinator.objectWillChange.send()
                    }
                }
            }
        }
    }

    private func binding(for id: UUID) -> Binding<VirtualScreenConfig> {
        Binding(
            get: {
                coordinator.workspaceStore.activeWorkspace?
                    .virtualScreens.first(where: { $0.id == id })
                ?? VirtualScreenConfig(name: "?", width: 1920, height: 1080)
            },
            set: { newValue in
                guard var ws = coordinator.workspaceStore.activeWorkspace,
                      let i = ws.virtualScreens.firstIndex(where: { $0.id == id }) else { return }
                ws.virtualScreens[i] = newValue
                coordinator.workspaceStore.activeWorkspace = ws
                coordinator.saveWorkspaces()
            }
        )
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
    @Binding var config: VirtualScreenConfig
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                slider("Yaw", $config.yawDegrees, -150...150, "°")
                slider("Pitch", $config.pitchDegrees, -60...60, "°")
                slider("Distance", $config.distanceMeters, 0.5...6, "m")
                slider("Scale", $config.scale, 0.3...3, "×")
                slider("Curve r", $config.curvatureRadius, 0...5, "m")
            }
            .padding(.leading, 8)
        } label: {
            HStack {
                Toggle("", isOn: $config.showInAR).labelsHidden()
                Text(config.name)
                Text("\(config.width)×\(config.height)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
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
}
