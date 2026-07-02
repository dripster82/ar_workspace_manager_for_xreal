import AppKit
import DisplayManager
import GlassesDriver
import SwiftUI
import UniformTypeIdentifiers

struct ControlPanelView: View {
    @ObservedObject var coordinator: AppCoordinator
    @State private var selectedScreenID: CGDirectDisplayID?
    @State private var moveX = ""
    @State private var moveY = ""
    @State private var showDiagnostics = false
    @State private var route: PanelRoute = .dashboard
    @State private var settingsTab: SettingsTab = .general
    @State private var selectedHUDID: UUID?
    @State private var selectedDisplayID: UUID?

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(coordinator: coordinator, route: $route).frame(width: 212)
            Divider().overlay(PanelTheme.border)
            VStack(spacing: 0) {
                topBar
                Divider().overlay(PanelTheme.border)
                ScrollView {
                    detail.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                }
                bottomBar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PanelTheme.bg)
        }
        .frame(minWidth: 940, idealWidth: 1040, minHeight: 640, idealHeight: 720)
        .preferredColorScheme(.dark)
        .tint(PanelTheme.accent)
        // External navigation requests (e.g. the menu-bar "Update available" → Settings → About).
        .onChange(of: coordinator.pendingRoute) { r in
            if let r { route = r; coordinator.pendingRoute = nil }
        }
        .onChange(of: coordinator.pendingSettingsTab) { t in
            if let t { settingsTab = t; coordinator.pendingSettingsTab = nil }
        }
    }

    private var topBar: some View {
        HStack(alignment: .center, spacing: 16) {
            PageHeader(title: route.title, subtitle: route.subtitle)
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Button { coordinator.toggleAR() } label: {
                    Label(coordinator.arActive ? "Stop AR" : "Start AR",
                          systemImage: coordinator.arActive ? "stop.fill" : "play.fill")
                        .frame(minWidth: 96)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                // The workspace AR is displaying (its HUD profile follows automatically).
                HStack(spacing: 6) {
                    Image(systemName: "rectangle.3.group").font(.caption2).foregroundStyle(.secondary)
                    Picker("", selection: Binding(
                        get: { coordinator.displayedWorkspaceID },
                        set: { coordinator.setDisplayedWorkspace($0) }
                    )) {
                        ForEach(coordinator.workspaceStore.workspaces) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                    .labelsHidden().fixedSize()
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    @ViewBuilder private var detail: some View {
        switch route {
        case .dashboard: dashboardPage
        case .workspace: workspacePage
        case .hudWidgets: hudWidgetsPage
        case .media: mediaPage
        case .windowRules:
            ComingSoon(title: "Window Rules",
                       detail: "Automatically place apps on screens. The rule editor is coming; for "
                             + "now use ⌃⌥W to move a window to the screen you're looking at.")
        case .voiceCommands: voiceCommandsPage
        case .settings: settingsPage
        case .diagnostics: diagnosticsSection
        }
    }

    @ViewBuilder private var mediaPage: some View {
        if let media = coordinator.mediaPlayer {
            VStack(alignment: .leading, spacing: 14) {
                card("Player", "play.rectangle") { MediaPlayerControls(media: media, coordinator: coordinator) }
                card("Playlist", "list.bullet") { MediaPlaylist(media: media, coordinator: coordinator) }
            }
        } else {
            ComingSoon(title: "Media", detail: "The renderer isn't ready yet — try again in a moment.")
        }
    }

    private var dashboardPage: some View {
        VStack(spacing: 14) {
            card("Status", "gauge.with.dots.needle.33percent") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4),
                          spacing: 10) {
                    kpiTile("Glasses",
                            glassesConnected ? (coordinator.glassesModelName ?? "Connected") : "Not connected",
                            "eyeglasses", glassesConnected ? .green : .secondary)
                    DashboardLiveTiles(live: coordinator.live)
                    permissionTile("Screen Rec", granted: coordinator.hasScreenRecordingPermission,
                                   request: coordinator.requestScreenRecordingPermission)
                    permissionTile("Accessibility", granted: coordinator.hasAccessibilityPermission,
                                   request: coordinator.requestAccessibilityPermission)
                    permissionTile("Microphone", granted: coordinator.hasMicrophonePermission,
                                   request: coordinator.requestMicrophonePermission)
                    permissionTile("Voice", granted: coordinator.hasSpeechPermission,
                                   request: coordinator.requestSpeechPermission)
                }
            }
            card("Brightness", "sun.max") {
                if coordinator.brightnessAvailable {
                    brightnessControl
                } else {
                    Label("Brightness control needs the glasses' MCU channel (XREAL Air series). "
                          + "The One series doesn't expose it — use the brightness button on the glasses.",
                          systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            card("Quick actions", "bolt") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 10)],
                          alignment: .leading, spacing: 10) {
                    quickAction("Recenter", "scope", "⌃⌥Space", arOnly: true) { coordinator.recenter() }
                    quickAction("Recalibrate", "gyroscope", "⌃⌥B") { coordinator.requestCalibration() }
                    quickAction("Focus", "viewfinder", "⌃⌥F", arOnly: true) { coordinator.toggleFocus() }
                    quickAction("Passthrough", "eye", "⌃⌥V", arOnly: true) { coordinator.togglePassthrough() }
                    quickAction("HUD", "rectangle.on.rectangle", "⌃⌥I", arOnly: true) { coordinator.toggleHUD() }
                    quickAction("Labels", "tag", "⌃⌥L", arOnly: true) { coordinator.toggleLabels() }
                    quickAction("Stereo", "view.3d", "⌃⌥D", arOnly: true) { coordinator.setStereo(!coordinator.stereoEnabled) }
                    quickAction("Move Window", "macwindow.on.rectangle", "⌃⌥W", arOnly: true) { coordinator.onToggleWindowPicker?() }
                    quickAction("Find Cursor", "cursorarrow.rays", "⌃⌥C", arOnly: true) { coordinator.onToggleCursorInfo?() }
                    quickAction("Cursor→Gaze", "cursorarrow.motionlines", "⌃⌥X", arOnly: true) { coordinator.moveCursorToGaze() }
                    quickAction("Screenshot", "camera", "⌃⌥P", arOnly: true) { coordinator.takeGlassesScreenshot() }
                    quickAction("Record", "record.circle", "⌃⌥R", arOnly: true) { coordinator.toggleRecording() }
                    quickAction("Mute Mic", "mic.slash", "⌃⌥M", arOnly: true) { coordinator.toggleMicMute() }
                    quickAction("Help", "keyboard", "⌃⌥H") { coordinator.onToggleHelp?() }
                }
            }
        }
        .onAppear { coordinator.refreshPermissions() }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            coordinator.refreshPermissions()
        }
    }

    private var settingsPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("", selection: $settingsTab) {
                ForEach(SettingsTab.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            switch settingsTab {
            case .general: card("General", "gearshape") { generalSection }
            case .glasses:
                card("Glasses", "eyeglasses") {
                    VStack(alignment: .leading, spacing: 12) {
                        if coordinator.brightnessAvailable { brightnessControl }
                        outputSection
                    }
                }
            case .hud:
                card("HUD connections", "antenna.radiowaves.left.and.right") { hudConnectionsSection }
            case .performance: card("Performance", "gauge.with.dots.needle.33percent") { testSection }
            case .permissions: card("Permissions", "lock.shield") { permissionsSection }
            case .shortcuts: card("Shortcuts", "keyboard") { HelpView() }
            case .about:
                card("About", "info.circle") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("AR Workspace Manager for XREAL").font(.headline)
                        Text("Version \(coordinator.appVersion) · Build \(BuildInfo.commit) · \(BuildInfo.date)")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        HStack(spacing: 10) {
                            Button { coordinator.checkForUpdates() } label: {
                                if coordinator.checkingForUpdate {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text("Check for Updates")
                                }
                            }
                            .disabled(coordinator.checkingForUpdate || coordinator.updateInstalling)
                            if let v = coordinator.updateAvailableVersion {
                                if coordinator.updateDownloadAssetURL != nil {
                                    Button("Download & Install v\(v)") { coordinator.installUpdate() }
                                        .buttonStyle(.borderedProminent)
                                        .disabled(coordinator.updateInstalling)
                                }
                                if let url = coordinator.updateURL {
                                    Link("Release notes", destination: url)
                                }
                            } else if let msg = coordinator.updateCheckMessage {
                                Text(msg).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .controlSize(.small)
                        if let s = coordinator.updateInstallStatus {
                            HStack(spacing: 6) {
                                if coordinator.updateInstalling { ProgressView().controlSize(.small) }
                                Text(s).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Divider().padding(.vertical, 2)
                        HStack(spacing: 14) {
                            Link("GitHub repo", destination: URL(string: "https://github.com/dripster82/ar_workspace_manager_for_xreal")!)
                            Link("Releases", destination: URL(string: "https://github.com/dripster82/ar_workspace_manager_for_xreal/releases")!)
                        }
                        .font(.caption).controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: Workspace — layout-centric (selectors, layout map, selected display detail)

    private var workspacePage: some View {
        VStack(alignment: .leading, spacing: 14) {
            workspaceBar
            // Layout map (narrow) on the left, the selected display's detail to its right.
            HStack(alignment: .top, spacing: 14) {
                card("Layout", "square.on.square.dashed") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            addDisplayMenu
                            Spacer()
                        }
                        .controlSize(.small)
                        PlacementMapView(coordinator: coordinator, selection: $selectedDisplayID)
                    }
                }
                .frame(width: 400)
                selectedDisplayDetail
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    /// "Add Display" → pops a resolution picker; the first item is the main physical display's
    /// resolution (falling back to 1920×1080) as the default.
    private var addDisplayMenu: some View {
        Menu {
            let (dw, dh) = mainDisplayResolution()
            Button("Default — \(dw)×\(dh)") { addDisplay(width: dw, height: dh) }
            Divider()
            Section("16:9 / standard") {
                Button("1920×1080") { addDisplay(width: 1920, height: 1080) }
                Button("2560×1440") { addDisplay(width: 2560, height: 1440) }
                Button("3840×2160") { addDisplay(width: 3840, height: 2160) }
            }
            Section("Ultrawide") {
                Button("2560×1080") { addDisplay(width: 2560, height: 1080) }
                Button("3440×1440") { addDisplay(width: 3440, height: 1440) }
                Button("3840×1080") { addDisplay(width: 3840, height: 1080) }
                Button("5120×1080") { addDisplay(width: 5120, height: 1080) }
                Button("5120×1440") { addDisplay(width: 5120, height: 1440) }
            }
        } label: {
            Label("Add Display", systemImage: "plus.rectangle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// Main physical display's current resolution, or 1920×1080 if unavailable — the default for a
    /// newly added virtual display.
    private func mainDisplayResolution() -> (Int, Int) {
        let id = CGMainDisplayID()
        let w = Int(CGDisplayPixelsWide(id)), h = Int(CGDisplayPixelsHigh(id))
        return (w > 0 && h > 0) ? (w, h) : (1920, 1080)
    }

    private var workspaceBar: some View {
        card("Workspace", "rectangle.3.group") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Workspace").font(.caption).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                    Picker("", selection: Binding(
                        get: { coordinator.editingWorkspace?.id },
                        set: { coordinator.selectWorkspace($0); selectedDisplayID = nil; syncWorkspaceName() }
                    )) {
                        ForEach(coordinator.workspaceStore.workspaces) { ws in
                            Text(ws.name).tag(UUID?.some(ws.id))
                        }
                    }
                    .labelsHidden().frame(minWidth: 150)
                    TextField("Name", text: $workspaceName)
                        .textFieldStyle(.roundedBorder).frame(width: 150)
                        .onSubmit { coordinator.renameActiveWorkspace(workspaceName) }
                        .onAppear { syncWorkspaceName() }
                    Button { coordinator.addWorkspace(); syncWorkspaceName() } label: { Image(systemName: "plus") }
                        .help("New empty workspace")
                    Button { coordinator.duplicateActiveWorkspace(); syncWorkspaceName() } label: {
                        Image(systemName: "plus.square.on.square")
                    }
                    .help("Duplicate this workspace (same screens) — switch between them to test display reuse")
                    Menu {
                        Section("New from template (sized for readable text)") {
                            ForEach(WorkspaceTemplate.allCases) { t in
                                Button("\(t.title) — \(t.subtitle)") {
                                    coordinator.addWorkspaceFromTemplate(t); syncWorkspaceName()
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "square.grid.2x2")
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("New workspace from a template")
                    Button(role: .destructive) { coordinator.deleteActiveWorkspace(); syncWorkspaceName() } label: {
                        Image(systemName: "trash")
                    }
                    .help("Delete workspace").disabled(coordinator.workspaceStore.workspaces.count <= 1)
                    Spacer()
                }
                HStack(spacing: 8) {
                    Text("HUD Profile").font(.caption).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                    Picker("", selection: Binding(
                        get: { coordinator.activeHUDProfileID },
                        set: { coordinator.selectHUDProfile($0) }
                    )) {
                        ForEach(coordinator.hudProfiles) { p in Text(p.name).tag(Optional(p.id)) }
                    }
                    .labelsHidden().frame(minWidth: 150)
                    Text("Edit widgets on the HUD Widgets page.").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder private var selectedDisplayDetail: some View {
        if let id = selectedDisplayID, let screen = coordinator.editableScreens().first(where: { $0.id == id }) {
            card("Display · \(screen.name)", "display") {
                VStack(alignment: .leading, spacing: 8) {
                    ScreenRow(initial: screen, isPhysical: isPhysical(id),
                              wideCanvasMode: coordinator.wideCanvas,
                              lookedAt: coordinator.lookedAtScreenID == id, startExpanded: true,
                              onChange: { coordinator.updateScreen($0) },
                              onRemove: { coordinator.removeScreen(id: id); selectedDisplayID = nil })
                        .id(id)
                    if !isPhysical(id) {
                        virtualMirrorMenu(for: screen)
                        if screen.mirrorOfVirtual == nil { mirrorMenu(for: screen) }
                    }
                }
            }
        } else {
            card("Display", "display") {
                Text("Click a screen in the layout above to edit it, or add a display.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            }
        }
    }

    private func addDisplay(width: Int, height: Int) {
        let n = (coordinator.workspaceStore.activeWorkspace?.virtualScreens.count ?? 0) + 1
        let cfg = VirtualScreenConfig(name: "Screen \(n)", width: width, height: height,
                                      hiDPI: width <= 3840)
        coordinator.addVirtualScreen(cfg)
        selectedDisplayID = cfg.id
    }

    // MARK: HUD Widgets — three-column (Available / Active / Settings)

    private var hudWidgetsPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            hudProfileBar
            HStack(alignment: .top, spacing: 14) {
                card("Available", "plus.app") { availableWidgetsColumn }.frame(width: 220)
                card("Active", "square.stack.3d.up") { activeWidgetsColumn }.frame(width: 290)
                card("Settings", "slider.horizontal.3") { hudDetailColumn }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    /// HUD Profile selector + create/rename/delete, above the three columns (like the workspace bar).
    private var hudProfileBar: some View {
        card("HUD Profile", "rectangle.on.rectangle.angled") {
            HStack(spacing: 8) {
                Picker("", selection: Binding(
                    get: { coordinator.activeHUDProfileID },
                    set: { coordinator.selectHUDProfile($0); selectedHUDID = nil }
                )) {
                    ForEach(coordinator.hudProfiles) { p in Text(p.name).tag(Optional(p.id)) }
                }
                .labelsHidden().frame(minWidth: 200)

                TextField("Rename", text: Binding(
                    get: { coordinator.activeHUDProfileName },
                    set: { coordinator.renameHUDProfile($0) }
                ))
                .textFieldStyle(.roundedBorder).frame(width: 160)

                Button { coordinator.addHUDProfile() } label: { Label("New", systemImage: "plus") }
                Button(role: .destructive) {
                    if let id = coordinator.activeHUDProfileID { coordinator.deleteHUDProfile(id: id) }
                    selectedHUDID = nil
                } label: { Label("Delete", systemImage: "trash") }
                .disabled(coordinator.hudProfiles.count <= 1)
                Spacer()
            }
            .controlSize(.small)
        }
    }

    private var availableWidgetsColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(WidgetKind.allCases) { kind in
                Button { coordinator.addWidget(kind: kind) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: kind.symbol).frame(width: 18).foregroundStyle(.secondary)
                        Text(kind.displayName).font(.callout)
                        Spacer(minLength: 0)
                        Image(systemName: "plus").font(.caption).foregroundStyle(PanelTheme.accent)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Divider().padding(.vertical, 2)
            Button { coordinator.addStack() } label: {
                Label("Add stack", systemImage: "rectangle.stack").font(.callout)
            }
            .buttonStyle(.plain)
        }
    }

    private var activeWidgetsColumn: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Editing · \(coordinator.activeHUDProfileName)")
                .font(.caption2).foregroundStyle(.secondary)
            if coordinator.widgets.isEmpty && coordinator.stacks.isEmpty {
                Text("No widgets yet — add one from the left, then drag it into place in the "
                     + "Workspace layout's floating zone.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(coordinator.stacks) { stack in
                activeRow(id: stack.id, icon: "rectangle.stack", name: stack.name, draggable: false)
                    .onDrop(of: [.plainText], isTargeted: nil) { dropProviders($0, toStack: stack.id, before: nil) }
                ForEach(coordinator.widgets.filter { $0.stackID == stack.id }) { w in
                    activeRow(id: w.id, icon: w.kind.symbol, name: w.kind.displayName, draggable: true)
                        .padding(.leading, 16)
                }
            }
            let loose = coordinator.widgets.filter { $0.stackID == nil }
            if !coordinator.stacks.isEmpty && !loose.isEmpty {
                Text("Unstacked — drop here to remove from a stack")
                    .font(.caption2).foregroundStyle(.secondary).padding(.top, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onDrop(of: [.plainText], isTargeted: nil) { dropProviders($0, toStack: nil, before: nil) }
            }
            ForEach(loose) { w in
                activeRow(id: w.id, icon: w.kind.symbol, name: w.kind.displayName, draggable: true)
            }
        }
    }

    private func activeRow(id: UUID, icon: String, name: String, draggable: Bool) -> some View {
        let selected = selectedHUDID == id
        return HStack(spacing: 8) {
            if draggable {
                Image(systemName: "line.3.horizontal").foregroundStyle(.secondary).frame(width: 16)
                    .contentShape(Rectangle())
                    .onDrag { NSItemProvider(object: id.uuidString as NSString) }
            } else {
                Image(systemName: "rectangle.stack").foregroundStyle(.secondary).frame(width: 16)
            }
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(name).font(.callout)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? PanelTheme.accent.opacity(0.24) : Color.white.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { selectedHUDID = id }
    }

    @ViewBuilder private var hudDetailColumn: some View {
        if let id = selectedHUDID, let w = coordinator.widgets.first(where: { $0.id == id }) {
            WidgetRow(initial: w, stacks: coordinator.stacks,
                      calendar: w.kind == .calendar ? coordinator.calendar : nil,
                      reminders: w.kind == .list ? coordinator.reminders : nil,
                      startExpanded: true,
                      onChange: { coordinator.updateWidget($0) },
                      onRemove: { coordinator.removeWidget(id: w.id); selectedHUDID = nil })
                .id(w.id)
        } else if let id = selectedHUDID, let s = coordinator.stacks.first(where: { $0.id == id }) {
            StackRow(initial: s, startExpanded: true,
                     onChange: { coordinator.updateStack($0) },
                     onRemove: { coordinator.removeStack(id: s.id); selectedHUDID = nil })
                .id(s.id)
        } else {
            Text("Select a widget or stack to edit it.")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
        }
    }

    /// A dashboard quick-action tile mirroring a keyboard shortcut. `arOnly` disables it when AR isn't
    /// running (the action would be a no-op).
    /// A compact KPI tile: icon, a big value, and a label. Optional `action` makes it tappable.
    /// Uses a tap gesture (not a Button) so every tile is structurally identical and the same size.
    private func kpiTile(_ title: String, _ value: String, _ system: String, _ tint: Color,
                         action: (() -> Void)? = nil) -> some View {
        KPITile(title: title, value: value, system: system, tint: tint, action: action)
    }

    /// A permission KPI: shows "Granted" when allowed, otherwise a tappable Grant button that
    /// requests access in place.
    @ViewBuilder
    private func permissionTile(_ title: String, granted: Bool,
                                request: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Image(systemName: granted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.callout).foregroundStyle(granted ? .green : .orange)
            if granted {
                Text("Granted").font(.system(.title3, design: .rounded).weight(.semibold))
            } else {
                Button(action: request) {
                    Text("Grant")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .background(Color.orange, in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
            Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .padding(10)
        .background(PanelTheme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder((granted ? Color.green : .orange).opacity(0.35)))
    }

    /// Update status KPI — checking / update-ready (opens About) / up to date (re-checks on tap).
    private func quickAction(_ title: String, _ icon: String, _ key: String,
                             arOnly: Bool = false, _ action: @escaping () -> Void) -> some View {
        let enabled = !arOnly || coordinator.arActive
        return Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption2).lineLimit(1)
                Text(key).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
            }
            .frame(width: 88, height: 66)
            .background(PanelTheme.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(PanelTheme.border))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            if !coordinator.statusMessage.isEmpty {
                Text(coordinator.statusMessage)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            Label("v\(coordinator.appVersion) · \(BuildInfo.commit) · \(BuildInfo.date)", systemImage: "hammer")
                .font(.caption2).foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 20).padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(PanelTheme.sidebar)
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

    /// Glasses brightness slider — reused on the Dashboard and in Settings › Glasses.
    private var brightnessControl: some View {
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

    /// HUD account connections (moved out of the HUD Widgets page into Settings › HUD).
    private var hudConnectionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SlackSettingsView(slack: coordinator.slack, announce: $coordinator.slackAnnounce,
                              voiceID: $coordinator.announceVoiceID,
                              onTest: { coordinator.announcer.speak("Slack message from Jeff") },
                              onDownloadVoices: { coordinator.openSpokenContentSettings() })
            Divider()
            GitHubSettingsView(github: coordinator.github)
            Divider()
            CalendarSettingsView(calendar: coordinator.calendar)
            Divider()
            AppleCalendarSettingsView(appleCalendar: coordinator.appleCalendar)
            Divider()
            RemindersSettingsView(reminders: coordinator.reminders)
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
            Divider()
            permissionRow(
                title: "Microphone",
                detail: "Record your voice when capturing the glasses view (⌃⌥R)",
                granted: coordinator.hasMicrophonePermission,
                grant: { coordinator.requestMicrophonePermission() })
            Divider()
            permissionRow(
                title: "Speech Recognition",
                detail: "Run hands-free voice commands (⌃⌥A)",
                granted: coordinator.hasSpeechPermission,
                grant: { coordinator.requestSpeechPermission() })
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

    // MARK: Voice Commands page

    private func voiceTimingSlider(_ label: String, _ value: Binding<Double>,
                                   _ range: ClosedRange<Double>) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).frame(width: 92, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: "%.1fs", value.wrappedValue))
                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }

    private var voiceCommandsPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "flask").foregroundStyle(.orange)
                Text("Experimental — voice control is a work in progress; recognition and commands may be unreliable.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.orange.opacity(0.35)))

            card("Voice control", "mic") {
                Toggle("Enable voice control", isOn: $coordinator.voiceEnabled)
                Text("Voice control only works while AR is running.")
                    .font(.caption2).foregroundStyle(.secondary)
                Picker("", selection: $coordinator.voiceMode) {
                    ForEach(AppCoordinator.VoiceMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                if coordinator.voiceMode == .wakeWord {
                    HStack(spacing: 8) {
                        Text("Wake word").font(.caption)
                        TextField("wake word", text: $coordinator.wakeWord)
                            .textFieldStyle(.roundedBorder).frame(width: 160)
                    }
                }
                // Timing applies to both modes: push-to-talk waits after the hotkey; wake word waits
                // after the wake word is heard. "End pause" ends the command in either mode.
                voiceTimingSlider("Wait to start", $coordinator.voiceStartTimeout, 1...8)
                voiceTimingSlider("End pause", $coordinator.voiceSilenceTimeout, 0.5...4)
                Text(coordinator.voiceMode == .pushToTalk
                     ? "Press ⌃⌥A, say a command, and it runs after a short pause."
                     : "Always listening — say \u{201C}\(coordinator.wakeWord) <command>\u{201D}. After the wake "
                       + "word you have the \u{201C}wait to start\u{201D} time to speak, or it stops listening.")
                    .font(.caption2).foregroundStyle(.secondary)
                Toggle("Higher accuracy (uses Apple servers)", isOn: $coordinator.voiceAllowRemote)
                Text(coordinator.voiceAllowRemote
                     ? "Audio is sent to Apple for recognition — more accurate, less private."
                     : "Recognition runs on-device — audio stays on your Mac.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            card("Microphone", "mic.circle") {
                HStack {
                    Text("Listening mic").font(.caption)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { coordinator.voiceInputDeviceUID },
                        set: { coordinator.setVoiceInputDevice($0) }
                    )) {
                        ForEach(coordinator.availableMicrophones(), id: \.id) { Text($0.name).tag($0.id) }
                    }.labelsHidden().fixedSize()
                }
                Text("Sets your system input device — voice and the meter listen on this mic.")
                    .font(.caption2).foregroundStyle(.secondary)
                if VoiceController.inputDeviceIsBluetooth(uid: coordinator.voiceInputDeviceUID) {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("This is a Bluetooth headset. Opening its mic switches the whole headset "
                             + "into low-quality call mode, so music/video through it will sound bad "
                             + "while voice control listens. Pick the Mac's built-in microphone to keep "
                             + "full audio quality.")
                            .font(.caption2).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.15)))
                }
                HStack(spacing: 10) {
                    Button(coordinator.micTesting ? "Stop test" : "Test mic") { coordinator.toggleMicTest() }
                        .controlSize(.small)
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.25))
                        Capsule().fill(coordinator.micLevel > 0.85 ? Color.orange : .green)
                            .frame(width: max(2, 180 * min(1, CGFloat(coordinator.micLevel))))
                    }
                    .frame(width: 180, height: 8)
                    Spacer()
                }
                if coordinator.micTesting {
                    Text("Speak — the bar should move. If it stays flat, the mic isn't being heard.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            card("Permissions", "lock.shield") {
                permissionRow(title: "Speech Recognition",
                              detail: "Convert your speech to commands (on-device)",
                              granted: coordinator.hasSpeechPermission) { coordinator.requestSpeechPermission() }
                permissionRow(title: "Microphone", detail: "Listen to your voice",
                              granted: coordinator.hasMicrophonePermission) { coordinator.requestMicrophonePermission() }
            }
            card("Commands", "text.bubble") {
                Text("Edit the phrases that trigger each command (comma-separated). Tap the mic to say a "
                     + "command and add exactly what was heard — best way to tune it to your voice. You can "
                     + "also say \u{201C}switch to <workspace name>\u{201D}.")
                    .font(.caption2).foregroundStyle(.secondary)
                ForEach(coordinator.voiceBindings) { binding in
                    VoiceBindingRow(binding: binding,
                                    onChange: { coordinator.updateVoiceBinding($0) },
                                    onTest: { coordinator.startVoiceTest($0) })
                }
                Button("Reset to defaults") { coordinator.resetVoiceCommands() }
                    .controlSize(.small).padding(.top, 4)
            }
        }
        .onAppear { coordinator.refreshPermissions() }
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
            if !coordinator.hasScreenRecordingPermission {
                HStack {
                    Label("Screen Recording is off — required to show your screens in AR",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                    Button("Grant") { coordinator.requestScreenRecordingPermission() }
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

            // EXPERIMENT: render a single static image (no capture / virtual displays) to isolate
            // the frame-pacing jitter. Same display link + output window + head tracking as real AR.
            if !coordinator.arActive {
                Button("Static-image AR (debug)") {
                    if let id = selectedScreenID,
                       let screen = NSScreen.screens.first(where: { AppCoordinator.screenDisplayID($0) == id }) {
                        coordinator.startStaticImageAR(on: screen)
                    }
                }
                .controlSize(.small)
                .disabled(selectedScreenID == nil)
                .help("Renders ~/Desktop/VRDesktop-debug/stage2.jpg to the spatial scene with no "
                    + "screen capture or virtual displays. If this still jitters, the cause is the "
                    + "AR presentation path itself.")
            }

            // Output refresh rate: switches the actual macOS display mode for the glasses so the
            // panel genuinely runs at the chosen rate (a steady 90 can read smoother than a
            // jittery 120). Live-switchable while AR runs.
            let rates = coordinator.availableGlassesRefreshRates()
            if !rates.isEmpty {
                Picker("Refresh rate", selection: Binding(
                    get: { coordinator.glassesRefreshRate },
                    set: { coordinator.setGlassesRefreshRate($0) }
                )) {
                    Text("Auto (\(Int(rates.first ?? 0)) Hz)").tag(0.0)
                    ForEach(rates, id: \.self) { r in
                        Text("\(Int(r)) Hz").tag(r)
                    }
                }
                .pickerStyle(.segmented)
                .help("Sets the glasses' macOS display mode to this refresh rate and paces "
                    + "rendering to it. Lower, steady rates can feel smoother than a jittery 120.")
            }

            Label("If AR stutters, set the glasses to the **sRGB** colour profile in "
                + "System Settings → Displays → Colour Profile. The factory “Air 2” profile makes "
                + "macOS colour-convert every frame, which causes the jumping.",
                  systemImage: "lightbulb")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Dedicated render thread (high priority)", isOn: $coordinator.useDedicatedRenderThread)
                .help("Runs the display link on a dedicated .userInteractive thread instead of the main "
                    + "run loop, so rendering keeps scheduler priority over background apps "
                    + "(VS Code/Docker/etc.) on a busy machine.")

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
                    if !coordinator.stereoEnabled {
                        Toggle("Wide curved canvas", isOn: $coordinator.wideCanvas)
                            .font(.caption)
                            .help("Wrap all anchored screens onto one continuous auto-curved surface with shared distance and canvas scale")
                        if coordinator.wideCanvas {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Canvas distance").frame(width: 110, alignment: .leading).font(.caption)
                                    Slider(value: $coordinator.wideCanvasDistanceMeters, in: 0.5...6)
                                    Text(String(format: "%.1fm", coordinator.wideCanvasDistanceMeters))
                                        .frame(width: 44).font(.caption).monospacedDigit()
                                }
                                HStack {
                                    Text("Canvas scale").frame(width: 110, alignment: .leading).font(.caption)
                                    Slider(value: $coordinator.wideCanvasScale, in: 0.3...3)
                                    Text(String(format: "%.2fx", coordinator.wideCanvasScale))
                                        .frame(width: 44).font(.caption).monospacedDigit()
                                }
                                Text("Screen scale still sets each screen's size before stitching. Canvas scale then resizes the merged wide canvas.")
                                    .font(.caption2).foregroundStyle(.secondary)
                                Button("Capture debug stages") {
                                    coordinator.captureDebugStages()
                                }
                                .font(.caption)
                                .disabled(!coordinator.arActive)
                                .help("Write stage1_*.jpg (raw screens), stage2.jpg (merged flat canvas), stage3.jpg (final curved frame) to ~/Desktop/VRDesktop-debug")
                            }
                            .padding(.top, 2)
                        }
                    }
                }
            }

            Text("Display diagnostics are on the Diagnostics page.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// Live display info + window move (shown on the Diagnostics page).
    private var diagnosticsInfo: some View {
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
                          wideCanvasMode: coordinator.wideCanvas,
                          lookedAt: coordinator.lookedAtScreenID == screen.id,
                          onChange: { coordinator.updateScreen($0) },
                          onRemove: { coordinator.removeScreen(id: screen.id) })
                    .id(screen.id)
                if !isPhysical(screen.id) {
                    virtualMirrorMenu(for: screen)
                    if screen.mirrorOfVirtual == nil {
                        mirrorMenu(for: screen)
                    }
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
            }
            Text("Your real monitors appear automatically (green) for positioning. "
                 + "Toggle one on to mirror it into the glasses (orange).")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// Drop a selection whose display has gone away, and auto-pick the glasses when present.
    private func validateOutputSelection() {
        let ids = NSScreen.screens.map { AppCoordinator.screenDisplayID($0) }
        if let sel = selectedScreenID, !ids.contains(sel) { selectedScreenID = nil }
        if selectedScreenID == nil { selectedScreenID = coordinator.glassesScreenID() }
    }

    private var widgetsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Floating info cards in your view.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { coordinator.addStack() } label: { Label("Add stack", systemImage: "rectangle.stack") }
                    .buttonStyle(.borderless).controlSize(.small)
                Menu {
                    ForEach(WidgetKind.allCases) { kind in
                        Button {
                            coordinator.addWidget(kind: kind)
                        } label: { Label(kind.displayName, systemImage: kind.symbol) }
                    }
                } label: {
                    Label("Add widget", systemImage: "plus")
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
            if coordinator.widgets.isEmpty && coordinator.stacks.isEmpty {
                Text("No widgets yet. Add a Clock or Power widget, then drag it into place in the "
                     + "Layout map's “In view (floating)” area.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                if !coordinator.stacks.isEmpty {
                    Text("Drag a widget onto a stack to add it, or between widgets to reorder.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(coordinator.stacks) { stack in
                    // Stack header — dropping a widget here appends it to the stack.
                    StackRow(initial: stack,
                             onChange: { coordinator.updateStack($0) },
                             onRemove: { coordinator.removeStack(id: stack.id) })
                        .onDrop(of: [.plainText], isTargeted: nil) { dropProviders($0, toStack: stack.id, before: nil) }
                    ForEach(coordinator.widgets.filter { $0.stackID == stack.id }) { w in
                        widgetRow(w).padding(.leading, 16)
                    }
                }
                let loose = coordinator.widgets.filter { $0.stackID == nil }
                if !coordinator.stacks.isEmpty {
                    Text("Unstacked — drop here to remove from a stack")
                        .font(.caption2.bold()).foregroundStyle(.secondary).padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onDrop(of: [.plainText], isTargeted: nil) { dropProviders($0, toStack: nil, before: nil) }
                }
                ForEach(loose) { w in widgetRow(w) }
            }
            if !coordinator.arActive {
                Text("Widgets appear once AR is running.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text("Account connections (Slack / GitHub / Calendar) are in Settings › HUD.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// A widget row with a drag handle (the drag source — dragging the whole DisclosureGroup
    /// conflicts with its toggle). The row is a drop target: dropping another widget here inserts
    /// it before this one, reordering within a stack or moving it into this widget's group.
    private func widgetRow(_ w: HUDWidget) -> some View {
        HStack(alignment: .top, spacing: 6) {
            // Solid grip — onDrag only makes opaque content draggable, so it needs a filled area.
            Image(systemName: "line.3.horizontal")
                .font(.body).foregroundStyle(.secondary)
                .frame(width: 26).frame(maxHeight: .infinity)
                .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
                .onDrag { NSItemProvider(object: w.id.uuidString as NSString) }
                .help("Drag to reorder, or onto a stack to add it")
            WidgetRow(initial: w, stacks: coordinator.stacks,
                      calendar: w.kind == .calendar ? coordinator.calendar : nil,
                      reminders: w.kind == .list ? coordinator.reminders : nil,
                      onChange: { coordinator.updateWidget($0) },
                      onRemove: { coordinator.removeWidget(id: w.id) })
        }
        .onDrop(of: [.plainText], isTargeted: nil) { dropProviders($0, toStack: w.stackID, before: w.id) }
    }

    /// Load the dragged widget id from the providers and move it. Reliable cross-version macOS DnD.
    private func dropProviders(_ providers: [NSItemProvider], toStack stackID: UUID?, before beforeID: UUID?) -> Bool {
        guard let p = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        _ = p.loadObject(ofClass: NSString.self) { obj, _ in
            guard let s = obj as? String, let id = UUID(uuidString: s) else { return }
            DispatchQueue.main.async { coordinator.moveWidget(id, toStack: stackID, before: beforeID) }
        }
        return true
    }

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Launch at login", isOn: $coordinator.launchAtLogin)
                .font(.caption)
            Toggle("Keep cursor off the AR screen", isOn: $coordinator.confineCursor)
                .font(.caption)
            Toggle("Fill the screen when moving a window (⌃⌥W)", isOn: $coordinator.fillScreenOnMove)
                .font(.caption)
                .help("On: a window moved with ⌃⌥W resizes to fill the target screen. Off: it keeps "
                      + "its size and just moves there.")
            HStack {
                Text("Exit Focus with").font(.caption)
                Spacer()
                Picker("", selection: $coordinator.focusEscape) {
                    ForEach(AppCoordinator.FocusEscape.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            .help("⌃⌥F always toggles Focus. This sets whether Esc also exits: ‘Esc’ exits on one press "
                  + "but apps that use Esc won't receive it while focused; ‘Double-tap Esc’ leaves single "
                  + "Esc working in your apps and exits only on a quick double-press (needs Accessibility).")
            HStack {
                Text("Recording microphone").font(.caption)
                Spacer()
                Picker("", selection: $coordinator.selectedMicID) {
                    ForEach(coordinator.availableMicrophones(), id: \.id) { Text($0.name).tag($0.id) }
                }.labelsHidden().fixedSize()
            }
            .help("Which mic is used when recording the glasses view (⌃⌥R). Mute live with ⌃⌥M.")
            Toggle("Record system audio (app & meeting sound)", isOn: $coordinator.recordSystemAudio)
                .font(.caption)
                .help("Mix the Mac's output audio — meeting voices, music, app SFX — into recordings, "
                      + "alongside the mic. Mute the mic (⌃⌥M) to record system audio only. Uses the "
                      + "Screen Recording permission.")
            HStack {
                Text("Restore windows on start").font(.caption)
                Spacer()
                Picker("", selection: $coordinator.windowRestoreMode) {
                    ForEach(WindowRestoreMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden().fixedSize()
            }
            .help("When AR starts, put each app back on the screen/position it had when AR last stopped (needs Accessibility).")
            Text("Logging and display diagnostics moved to the Diagnostics page.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// Diagnostics page: debug logging + live display info.
    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            card("Logging", "doc.text") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Write debug log", isOn: $coordinator.debugLogging)
                        .font(.caption).help(coordinator.debugLogURL.path)
                    Toggle("Log raw IMU data (~60 Hz)", isOn: $coordinator.rawIMULogging)
                        .font(.caption)
                        .help("Logs raw vs filtered yaw/pitch/roll + angular speed for movement/calibration testing")
                    Toggle("Log system load (~3 s)", isOn: $coordinator.systemLoadLogging)
                        .font(.caption)
                        .help("Logs load average, thermal state, and top CPU processes (incl. Sophos / "
                            + "WindowServer / colorsync) every ~3s, so we can correlate render stalls with "
                            + "machine load. Sampled off the render thread.")
                    if coordinator.debugLogging || coordinator.rawIMULogging || coordinator.systemLoadLogging {
                        HStack {
                            Button("Reveal log") { coordinator.revealDebugLog() }
                            Button("Clear log") { coordinator.clearDebugLog() }
                        }
                        .controlSize(.small)
                    }
                }
            }
            card("IMU", "gyroscope") { IMUDiagnosticsRows(live: coordinator.live) }
            card("Input", "cursorarrow.rays") {
                HStack(spacing: 8) {
                    Circle().fill(coordinator.isDraggingWindow ? Color.green : .secondary)
                        .frame(width: 9, height: 9)
                    Text("Dragging a window: \(coordinator.isDraggingWindow ? "yes" : "no")")
                        .font(.system(.caption, design: .monospaced))
                }
            }
            card("System health", "waveform.path.ecg") { systemHealthSection }
            card("Displays", "rectangle.on.rectangle") { diagnosticsInfo }
            #if DEBUG
            card("Developer — version override", "hammer") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Force the version the app reports, to test updates. Blank = real (v\(coordinator.bundleVersion)).")
                        .font(.caption2).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        TextField("e.g. 0.2", text: $coordinator.forcedVersionOverride)
                            .textFieldStyle(.roundedBorder).frame(width: 90)
                            .onSubmit { coordinator.applyForcedVersion() }
                        Button("Apply") { coordinator.applyForcedVersion() }
                        Button("Clear") { coordinator.forcedVersionOverride = ""; coordinator.applyForcedVersion() }
                    }
                    .controlSize(.small)
                    Text("Reporting v\(coordinator.appVersion) · \(coordinator.updateCheckMessage ?? "not checked")")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            #endif
        }
        // Keep the display list current while viewing (incl. during AR), without the continuous
        // writes that cause judder — the publisher only lives while this page is on screen.
        .onAppear { coordinator.refreshHealthNow() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            coordinator.refreshDisplayDiagnostics()
        }
    }

    private var systemHealthSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Live runaway metric — always shown (the others are accumulation indicators).
            HStack {
                Text("ColorSync daemon CPU").font(.caption)
                Spacer()
                let cds = coordinator.colorSyncDaemonCPU
                Text(String(format: "%.0f%%", cds))
                    .font(.caption.monospacedDigit().bold())
                    .foregroundStyle(cds >= 65 ? .red : (cds > 25 ? .orange : .secondary))
                if cds >= 65 { Text("pinned").font(.caption2).foregroundStyle(.red) }
            }
            Text("colorsync.displayservices — pins ~75% after rapid display changes; self-clears in ~1 min.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Toggle("Monitor problem processes (colorsync, WindowServer, Sophos)",
                   isOn: $coordinator.processMonitorEnabled)
                .font(.caption)
            if coordinator.processMonitorEnabled {
                ForEach(coordinator.processSamples) { s in
                    HStack {
                        Text(s.name).font(.system(.caption, design: .monospaced))
                        Spacer()
                        Text(String(format: "%.0f%%", s.cpu))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(s.cpu > 60 ? .red : (s.cpu > 25 ? .orange : .secondary))
                    }
                }
                .padding(.leading, 8)
                Text("Updates every 3 s while enabled.").font(.caption2).foregroundStyle(.secondary)
            }
            Divider()
            Toggle("Alert when ColorSync gets stuck", isOn: $coordinator.colorSyncAlertEnabled)
                .font(.caption)
            Text("Watches colorsync.displayservices; if it pins the CPU (the Air 2 colour self-loop, "
                 + "which can eventually crash the display session) an alert tells you to replug the "
                 + "glasses — the only fix. The app can't clear it automatically.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if coordinator.colorSyncRunawayWarning {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.red)
                    Text("ColorSync is stuck — this is the Air 2 colour self-loop and can crash the "
                         + "display session if ignored. Unplug/replug the Air 2 or reboot to clear it.")
                        .font(.caption2).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            healthRow("ColorSync display profiles", coordinator.displayProfileCount, warn: 30,
                      hint: "Lots of stale per-display profiles bloat the ColorSync registry.")
            healthRow("Saved display configs", coordinator.displayConfigCount, warn: 50,
                      hint: "Excessive saved arrangements make ColorSync re-parse a huge plist.")
            HStack {
                Button("Refresh") { coordinator.refreshHealthNow() }.controlSize(.small)
                Button("Clean ColorSync now") { coordinator.cleanColorSyncNow() }.controlSize(.small)
                Button("Clear saved configs…") { showClearConfigsConfirm = true }.controlSize(.small)
            }
            .confirmationDialog("Clear saved display arrangements?",
                                isPresented: $showClearConfigsConfirm, titleVisibility: .visible) {
                Button("Clear & Restart Now…", role: .destructive) {
                    coordinator.clearSavedDisplayConfigs()
                    coordinator.restartNow()
                }
                Button("Clear, I'll Restart Later") {
                    coordinator.clearSavedDisplayConfigs()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes the bloated WindowServer arrangement plist (backed up as .bak). The change "
                     + "only takes effect after a RESTART — WindowServer survives a logout and rewrites "
                     + "the file, so logging out is not enough. “Restart Now” asks macOS to restart (it "
                     + "shows its own confirmation and closes your apps first).")
            }
        }
    }

    @State private var showClearConfigsConfirm = false

    private func healthRow(_ label: String, _ count: Int, warn: Int, hint: String) -> some View {
        let over = count >= warn
        return VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text("\(count)").font(.caption.monospacedDigit())
                    .foregroundStyle(over ? .orange : .secondary)
                if over { Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.orange) }
            }
            if over {
                Text(hint).font(.caption2).foregroundStyle(.orange.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func virtualMirrorMenu(for screen: VirtualScreenConfig) -> some View {
        let targets = coordinator.virtualMirrorTargets(for: screen.id)
        let currentName = targets.first { $0.id == screen.mirrorOfVirtual }?.name
        return HStack(spacing: 6) {
            Image(systemName: "rectangle.on.rectangle.angled.fill").foregroundStyle(.secondary)
            Menu(currentName.map { "Mirroring screen: \($0)" } ?? "Mirror another screen: off") {
                Button("Off") { coordinator.setVirtualMirror(screenID: screen.id, sourceID: nil) }
                if targets.isEmpty {
                    Text("No eligible screens").disabled(true)
                }
                ForEach(targets, id: \.id) { target in
                    Button(target.name) {
                        coordinator.setVirtualMirror(screenID: screen.id, sourceID: target.id)
                    }
                }
            }
            .frame(width: 220)
        }
        .font(.caption)
        .padding(.leading, 24)
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
        workspaceName = coordinator.editingWorkspace?.name ?? ""
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
            Toggle("Ignore small movements", isOn: $coordinator.driftCorrection)
                .font(.caption)
                .help("Holds your heading steady while your head is still, so tiny movements don't slowly shift the view sideways. Safe; doesn't affect real head turns.")
            Toggle("Anti Drift", isOn: $coordinator.biasDriftCorrection)
                .font(.caption)
                .help("Continuously subtracts the calibrated drift rate (works even while turning your head). "
                      + "Calibrate it with the button below first.")
            HStack(spacing: 8) {
                Button(coordinator.driftCalibrating
                       ? "Calibrating…"
                       : (IMUService.shared.usingNetworkIMU ? "Calibrate" : "Calibrate drift")) {
                    coordinator.requestCalibration()
                }
                .controlSize(.small)
                .disabled(coordinator.driftCalibrating || !glassesConnected)
                .help(IMUService.shared.usingNetworkIMU
                      ? "Wear the glasses, look straight ahead and keep level, then press. Measures this "
                        + "device's mount tilt (so head-turns don't tilt the view) and the yaw drift."
                      : "Rest the glasses flat and still, then press. Measures the residual yaw drift "
                        + "and subtracts it continuously — helps even during head turns.")
                if coordinator.driftCalibrating { ProgressView().controlSize(.small) }
            }
            if let status = coordinator.driftCalibrationStatus {
                Text(status).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
            HStack {
                Text("Capture fps").frame(width: 78, alignment: .leading).font(.caption)
                Picker("", selection: $coordinator.captureFPS) {
                    Text("30").tag(30)
                    Text("60").tag(60)
                    Text("120").tag(120)
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            .help("How often captured screen content refreshes — higher is smoother (scrolling/video/cursor) but costs more, especially with many screens. Reprojection runs at full display rate regardless.")
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

/// A row to edit one HUD widget: scale, style (tint + clock options), and remove. Position is set
/// by dragging the widget in the Layout map's floating zone.
struct WidgetRow: View {
    let initial: HUDWidget
    let stacks: [HUDStack]
    /// The calendar service, supplied only for the calendar widget so its alarm options show here.
    var calendar: GoogleCalendarService?
    /// The reminders service, supplied only for the list widget so its Reminders controls show here.
    var reminders: RemindersService?
    var onChange: (HUDWidget) -> Void
    var onRemove: () -> Void

    @State private var cfg: HUDWidget
    @State private var expanded = false

    init(initial: HUDWidget, stacks: [HUDStack], calendar: GoogleCalendarService? = nil,
         reminders: RemindersService? = nil, startExpanded: Bool = false,
         onChange: @escaping (HUDWidget) -> Void, onRemove: @escaping () -> Void) {
        self.initial = initial
        self.stacks = stacks
        self.calendar = calendar
        self.reminders = reminders
        self.onChange = onChange
        self.onRemove = onRemove
        _cfg = State(initialValue: initial)
        _expanded = State(initialValue: startExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Full-width clickable header (the DisclosureGroup only made the chevron/label clickable).
            HStack(spacing: 6) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption2).foregroundStyle(.secondary).frame(width: 10)
                Image(systemName: cfg.kind.symbol).foregroundStyle(.secondary)
                Text(cfg.kind.displayName)
                Spacer()
                Text(String(format: "yaw %.0f°  pitch %.0f°", cfg.yawDegrees, cfg.pitchDegrees))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .onTapGesture { expanded.toggle() }

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Stack").font(.caption).frame(width: 70, alignment: .leading)
                        Picker("", selection: Binding(get: { cfg.stackID }, set: { cfg.stackID = $0 })) {
                            Text("None").tag(UUID?.none)
                            ForEach(stacks) { Text($0.name).tag(UUID?.some($0.id)) }
                        }.labelsHidden().fixedSize()
                        Spacer()
                    }
                    HStack {
                        Text("Scale").font(.caption).frame(width: 70, alignment: .leading)
                        Slider(value: $cfg.scale, in: 0.1...3, step: 0.05)
                        Text(String(format: "%.0f%%", cfg.scale * 100)).font(.caption.monospacedDigit())
                            .frame(width: 44)
                    }
                    HStack {
                        Text("Colour").font(.caption).frame(width: 70, alignment: .leading)
                        Picker("", selection: $cfg.style.tint) {
                            ForEach(WidgetTint.allCases) { Text($0.displayName).tag($0) }
                        }.labelsHidden().fixedSize()
                        Spacer()
                    }
                    HStack {
                        Text("Background").font(.caption).frame(width: 70, alignment: .leading)
                        Picker("", selection: $cfg.style.background) {
                            ForEach(WidgetBackground.allCases) { Text($0.displayName).tag($0) }
                        }.labelsHidden().fixedSize()
                        Spacer()
                    }
                    if cfg.kind == .clock {
                        Toggle("24-hour", isOn: $cfg.style.clock24h).font(.caption)
                        Toggle("Show seconds", isOn: $cfg.style.showSeconds).font(.caption)
                    }
                    if cfg.kind == .slack {
                        Toggle("Show refresh countdown", isOn: $cfg.style.showRefreshCountdown).font(.caption)
                    }
                    if cfg.kind == .calendar {
                        HStack {
                            Text("Source").font(.caption).frame(width: 70, alignment: .leading)
                            Picker("", selection: Binding(get: { cfg.calendarSource ?? .google },
                                                          set: { cfg.calendarSource = $0 })) {
                                ForEach(CalendarSource.allCases) { Text($0.displayName).tag($0) }
                            }.labelsHidden().fixedSize()
                            Spacer()
                        }
                        HStack {
                            Text("Range").font(.caption).frame(width: 70, alignment: .leading)
                            Picker("", selection: Binding(get: { cfg.calendarRange ?? .all },
                                                          set: { cfg.calendarRange = $0 })) {
                                ForEach(CalendarRange.allCases) { Text($0.displayName).tag($0) }
                            }.labelsHidden().fixedSize()
                            Spacer()
                        }
                        Stepper(value: Binding(get: { cfg.calendarMaxEvents ?? 4 },
                                               set: { cfg.calendarMaxEvents = $0 }), in: 1...10) {
                            Text("Show \(cfg.calendarMaxEvents ?? 4) event\((cfg.calendarMaxEvents ?? 4) == 1 ? "" : "s")")
                                .font(.caption)
                        }
                        if let calendar {
                            Divider()
                            CalendarAlarmOptions(calendar: calendar)
                        }
                    }
                    if cfg.kind == .list {
                        Divider()
                        ListWidgetConfigView(
                            cfg: Binding(get: { cfg.list ?? ListConfig() }, set: { cfg.list = $0 }),
                            reminders: reminders)
                    }
                    HStack {
                        Button("Remove", role: .destructive, action: onRemove)
                        Spacer()
                    }
                    .controlSize(.small)
                }
                .padding(.leading, 8)
            }
        }
        .onChange(of: cfg) { newValue in onChange(newValue) }
        .onChange(of: initial) { newValue in if newValue != cfg { cfg = newValue } }
    }
}

/// A row to edit a stack container: axis, alignment, scale, remove. Position is set by dragging the
/// stack in the Layout map's floating zone; member widgets are assigned via each widget's row.
struct StackRow: View {
    let initial: HUDStack
    var onChange: (HUDStack) -> Void
    var onRemove: () -> Void

    @State private var cfg: HUDStack
    @State private var expanded = false

    init(initial: HUDStack, startExpanded: Bool = false,
         onChange: @escaping (HUDStack) -> Void, onRemove: @escaping () -> Void) {
        self.initial = initial; self.onChange = onChange; self.onRemove = onRemove
        _cfg = State(initialValue: initial)
        _expanded = State(initialValue: startExpanded)
    }

    // Anchor: which edge the stack is pinned to (so it grows away from it).
    private var alignLabels: [(StackAlign, String)] {
        cfg.axis == .vertical
            ? [(.start, "Top"), (.center, "Centre"), (.end, "Bottom")]
            : [(.start, "Left"), (.center, "Centre"), (.end, "Right")]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption2).foregroundStyle(.secondary).frame(width: 10)
                Image(systemName: "rectangle.stack").foregroundStyle(.tint)
                Text(cfg.name)
                Text(cfg.axis == .vertical ? "vertical" : "horizontal")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "yaw %.0f°  pitch %.0f°", cfg.yawDegrees, cfg.pitchDegrees))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .onTapGesture { expanded.toggle() }

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Direction", selection: $cfg.axis) {
                        Text("Vertical").tag(StackAxis.vertical)
                        Text("Horizontal").tag(StackAxis.horizontal)
                    }.pickerStyle(.segmented)
                    HStack {
                        Text("Anchor").font(.caption).frame(width: 70, alignment: .leading)
                        Picker("", selection: $cfg.align) {
                            ForEach(alignLabels, id: \.0) { Text($0.1).tag($0.0) }
                        }.pickerStyle(.segmented)
                    }
                    .help("Which edge the stack is pinned to, so it grows away from it when a widget changes size.")
                    HStack {
                        Text("Scale").font(.caption).frame(width: 70, alignment: .leading)
                        Slider(value: $cfg.scale, in: 0.1...3, step: 0.05)
                        Text(String(format: "%.0f%%", cfg.scale * 100)).font(.caption.monospacedDigit()).frame(width: 44)
                    }
                    HStack {
                        Button("Remove", role: .destructive, action: onRemove)
                        Spacer()
                    }.controlSize(.small)
                }
                .padding(.leading, 8)
            }
        }
        .onChange(of: cfg) { newValue in onChange(newValue) }
        .onChange(of: initial) { newValue in if newValue != cfg { cfg = newValue } }
    }
}

struct ScreenRow: View {
    let initial: VirtualScreenConfig
    var isPhysical: Bool = false
    var wideCanvasMode: Bool = false
    var lookedAt: Bool = false
    var onChange: (VirtualScreenConfig) -> Void = { _ in }
    var onRemove: () -> Void = {}

    // Local editing state so slider values update live during a drag (the live-update
    // path to the renderer doesn't re-publish, which otherwise froze the UI numbers).
    @State private var cfg: VirtualScreenConfig
    @State private var expanded = false
    // Name editing is buffered locally and committed on submit/blur, so we don't re-save the
    // whole config (and rebuild the scene) on every keystroke.
    @State private var nameField: String

    init(initial: VirtualScreenConfig, isPhysical: Bool = false, wideCanvasMode: Bool = false,
         lookedAt: Bool = false, startExpanded: Bool = false,
         onChange: @escaping (VirtualScreenConfig) -> Void = { _ in },
         onRemove: @escaping () -> Void = {}) {
        self.initial = initial
        self.isPhysical = isPhysical
        self.wideCanvasMode = wideCanvasMode
        self.lookedAt = lookedAt
        self.onChange = onChange
        self.onRemove = onRemove
        _cfg = State(initialValue: initial)
        _nameField = State(initialValue: initial.name)
        _expanded = State(initialValue: startExpanded)
    }

    private func commitName() {
        let trimmed = nameField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { nameField = cfg.name; return } // reject blank, restore
        if trimmed != cfg.name { cfg.name = trimmed }               // persists via onChange(of: cfg)
        else { nameField = cfg.name }
    }

    private func chooseBackgroundImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Use as Background"
        if panel.runModal() == .OK, let url = panel.url {
            // Copy into the app's support folder so the workspace is self-contained.
            cfg.background.imagePath = ScreenBackgroundApplier.importImage(from: url) // persists via onChange(of: cfg)
        }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("Name").font(.caption).foregroundStyle(.secondary)
                    TextField("Screen name", text: $nameField)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .onSubmit { commitName() }
                }
                .help(isPhysical
                      ? "Rename this monitor's in-app label (shown in the panel and the ⌃⌥C popup)."
                      : "Rename this screen. The new name shows in the panel and the ⌃⌥C popup; the "
                        + "macOS display name updates next time AR starts.")
                if isPhysical {
                    Toggle("Mirror into glasses", isOn: $cfg.showInAR)
                        .font(.caption)
                        .help("On: capture this monitor and show it in the glasses (orange). "
                              + "Off: keep it as a positioning reference only (green).")
                }
                Picker("Placement", selection: $cfg.placement) {
                    Text("Anchored").tag(ScreenPlacement.anchored)
                    Text("Floating").tag(ScreenPlacement.floating)
                }
                .pickerStyle(.segmented)
                .help("Anchored: fixed in space. Floating: stays in view (yaw/pitch/distance are the offset).")
                if !isPhysical {
                    HStack(spacing: 6) {
                        Picker("Background", selection: $cfg.background.kind) {
                            Text("Default").tag(ScreenBackgroundKind.default)
                            Text("Solid colour").tag(ScreenBackgroundKind.color)
                            Text("Image").tag(ScreenBackgroundKind.image)
                            Text("Transparent").tag(ScreenBackgroundKind.transparent)
                        }
                        .font(.caption)
                        if cfg.background.kind == .color {
                            ColorPicker("", selection: Binding(
                                get: { Color(nsColor: ScreenBackgroundApplier.nsColor(fromHex: cfg.background.hex) ?? .black) },
                                set: { cfg.background.hex = ScreenBackgroundApplier.hex(from: NSColor($0)) }
                            ))
                            .labelsHidden()
                        }
                    }
                    .help("Sets this screen's macOS desktop wallpaper. Transparent fills it black, "
                          + "which the glasses' optics render see-through — so only your windows show.")
                    if cfg.background.kind == .image {
                        HStack(spacing: 6) {
                            Button("Choose Image…") { chooseBackgroundImage() }
                            Text(cfg.background.imagePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "No image")
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        .controlSize(.small)
                    }
                }
                if isPhysical {
                    Text("Resolution: \(cfg.width)×\(cfg.height)")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Menu("Resolution: \(cfg.width)×\(cfg.height)") {
                        Section("1080p (native)") {
                            Button("1440×1080 (4:3)") { setResolution(width: 1440, height: 1080) }
                            Button("1600×1080 (3:2)") { setResolution(width: 1600, height: 1080) }
                            Button("1920×1080 (16:9)") { setResolution(width: 1920, height: 1080) }
                            Button("2560×1080 (21:9)") { setResolution(width: 2560, height: 1080) }
                            Button("3840×1080 (32:9)") { setResolution(width: 3840, height: 1080) }
                            Button("5120×1080 (43:9)") { setResolution(width: 5120, height: 1080) }
                        }
                        Section("1440p") {
                            Button("2560×1440") { setResolution(width: 2560, height: 1440) }
                            Button("3440×1440") { setResolution(width: 3440, height: 1440) }
                            Button("5120×1440") { setResolution(width: 5120, height: 1440) }
                        }
                        Section("2160p") {
                            Button("3840×2160") { setResolution(width: 3840, height: 2160) }
                        }
                    }
                    .font(.caption)
                }
                slider("Yaw", $cfg.yawDegrees, -180...180, "°")
                slider("Pitch", $cfg.pitchDegrees, -90...90, "°")
                if wideCanvasMode && cfg.placement != .floating {
                    Text("Wide canvas controls shared distance and canvas scale. Screen scale still controls the image size.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                slider("Distance", $cfg.distanceMeters, 0.5...6, "m")
                    .disabled(wideCanvasMode && cfg.placement != .floating)
                slider("Scale", $cfg.scale, 0.3...3, "×")
                curveSlider("Curve", $cfg.curvatureRadius, auto: $cfg.autoCurveH)
                    .disabled(wideCanvasMode && cfg.placement != .floating)
                HStack {
                    Button("Reset placement") { cfg.resetPlacement() }
                    // Physical monitors are discovered automatically, so removing one is
                    // meaningless (it'd reappear) — only virtual screens can be removed.
                    if !isPhysical {
                        Button("Remove", role: .destructive) { onRemove() }
                    }
                }
                .controlSize(.small)
            }
            .padding(.leading, 8)
        } label: {
            HStack {
                Toggle("", isOn: $cfg.showInAR).labelsHidden()
                    .help(isPhysical
                          ? "On: mirror this monitor into the glasses (orange). Off: positioning reference only (green)."
                          : "Show this virtual screen in the glasses.")
                Image(systemName: isPhysical ? "display" : "rectangle.on.rectangle")
                    .foregroundStyle(cfg.showInAR && isPhysical ? .orange
                                     : isPhysical ? .green : .secondary)
                Text(cfg.name)
                if lookedAt {
                    Image(systemName: "eye.fill").foregroundStyle(.tint).font(.caption)
                }
                Text("\(cfg.width)×\(cfg.height)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: cfg) { newValue in onChange(newValue) }
        .onChange(of: initial) { newValue in
            if newValue != cfg { cfg = newValue }
            if newValue.name != nameField { nameField = newValue.name }
        }
    }

    private func slider(_ label: String, _ value: Binding<Double>,
                        _ range: ClosedRange<Double>, _ unit: String) -> some View {
        HStack {
            Text(label).frame(width: 60, alignment: .leading).font(.caption)
            Slider(value: value, in: range)
            // Editable value: type an exact number (clamped to range), or drag the slider.
            TextField("", value: Binding(
                get: { value.wrappedValue },
                set: { value.wrappedValue = min(range.upperBound, max(range.lowerBound, $0)) }
            ), format: .number.precision(.fractionLength(0...1)))
                .textFieldStyle(.roundedBorder).frame(width: 52)
                .font(.caption).monospacedDigit().multilineTextAlignment(.trailing)
            Text(unit).font(.caption2).foregroundStyle(.secondary).frame(width: 12, alignment: .leading)
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

    private func setResolution(width: Int, height: Int) {
        guard !isPhysical else { return }
        cfg.width = width
        cfg.height = height
    }
}

/// Drag-to-place layout: two zones (anchored "around you" and floating "in view"); each
/// screen is a box you drag to set its yaw (horizontal) and pitch (vertical).
struct PlacementMapView: View {
    @ObservedObject var coordinator: AppCoordinator
    /// Optional click-to-select of a screen (used by the Workspace editor).
    var selection: Binding<UUID?>? = nil
    @State private var zoomAnchored = 1.0
    @State private var zoomFloating = 1.0

    // Base half-ranges (degrees). Anchored covers the full sphere; floating only the FOV + margin.
    private static let anchoredYaw = 180.0, anchoredPitch = 90.0
    private static let fovHDeg = 40.0, fovVDeg = 23.0
    private static let floatMargin = 50.0
    private static var floatYaw: Double { fovHDeg / 2 + floatMargin }
    private static var floatPitch: Double { fovVDeg / 2 + floatMargin }

    private static let viewportHeight: CGFloat = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            zone(title: "Around you (anchored)", placement: .anchored, accent: .blue,
                 baseYaw: Self.anchoredYaw, basePitch: Self.anchoredPitch, zoom: $zoomAnchored)
            zone(title: "In view (floating)", placement: .floating, accent: .accentColor,
                 baseYaw: Self.floatYaw, basePitch: Self.floatPitch, zoom: $zoomFloating)
            Text("Drag a screen to position it. Two-finger scroll to pan, +/− to zoom. "
                 + "Green = real monitor (positioning only), orange = real monitor shown in the glasses.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func screens(_ placement: ScreenPlacement) -> [VirtualScreenConfig] {
        // Physical monitors always appear (as positioning references) even when not shown in the
        // glasses; virtual screens appear only when shown in AR.
        coordinator.editableScreens().filter {
            $0.placement == placement && ($0.showInAR || coordinator.isPhysicalScreen($0.id))
        }
    }

    private func zone(title: String, placement: ScreenPlacement, accent: Color,
                      baseYaw: Double, basePitch: Double, zoom: Binding<Double>) -> some View {
        let spaceName = "zone-\(placement.rawValue)"
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
                // Equal pixels-per-degree both axes (no squish). At zoom 1 the full yaw range
                // fits the width; content scrolls (two-finger) for the rest / when zoomed.
                let ppd = geo.size.width * CGFloat(zoom.wrappedValue) / CGFloat(2 * baseYaw)
                let contentW = CGFloat(2 * baseYaw) * ppd
                let contentH = CGFloat(2 * basePitch) * ppd
                // NSScrollView-backed so scrolling doesn't chain to the outer panel at limits.
                NonChainingScrollView(
                    contentSize: CGSize(width: contentW, height: contentH),
                    onMagnify: { delta in
                        zoom.wrappedValue = min(6, max(1, zoom.wrappedValue * (1 + Double(delta))))
                    }
                ) {
                    ZStack(alignment: .topLeading) {
                        Rectangle().fill(Color.gray.opacity(0.12))
                        Rectangle().strokeBorder(.white.opacity(0.35), lineWidth: 1.5) // limit boundary
                        Rectangle().fill(.white.opacity(0.08)).frame(width: 1)
                            .position(x: contentW / 2, y: contentH / 2)
                        Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                            .position(x: contentW / 2, y: contentH / 2)
                        // FOV outline (where the glasses' view sits when centred) — shown in
                        // both zones to help size and position screens against the visible area.
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(.green.opacity(0.6),
                                          style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                            .frame(width: CGFloat(Self.fovHDeg) * ppd, height: CGFloat(Self.fovVDeg) * ppd)
                            .position(x: contentW / 2, y: contentH / 2)
                        ForEach(screens(placement)) { cfg in
                            // Colour code: orange = real monitor mirrored into the glasses,
                            // green = real monitor shown for positioning only, accent = virtual.
                            let boxAccent: Color = coordinator.isPhysicalScreen(cfg.id)
                                ? (cfg.showInAR ? .orange : .green) : accent
                            ScreenBox(initial: cfg, area: CGSize(width: contentW, height: contentH),
                                      coordinateSpace: spaceName, accent: boxAccent, pxPerDeg: ppd,
                                      yawRange: baseYaw, pitchRange: basePitch,
                                      lookedAt: coordinator.lookedAtScreenID == cfg.id,
                                      selected: selection?.wrappedValue == cfg.id,
                                      onSelect: { selection?.wrappedValue = cfg.id },
                                      onChange: { coordinator.updateScreen($0) },
                                      onDelete: coordinator.isPhysicalScreen(cfg.id) ? nil : {
                                          if selection?.wrappedValue == cfg.id { selection?.wrappedValue = nil }
                                          coordinator.removeScreen(id: cfg.id)
                                      })
                        }
                        // Head-locked HUD widgets/stacks live in the field of view → floating only.
                        if placement == .floating {
                            ForEach(coordinator.widgets.filter { $0.stackID == nil }) { widget in
                                WidgetBox(initial: widget,
                                          area: CGSize(width: contentW, height: contentH),
                                          coordinateSpace: spaceName, pxPerDeg: ppd,
                                          yawRange: baseYaw, pitchRange: basePitch,
                                          onChange: { coordinator.updateWidget($0) })
                            }
                            ForEach(coordinator.stacks) { stack in
                                StackBox(initial: stack,
                                         area: CGSize(width: contentW, height: contentH),
                                         coordinateSpace: spaceName, pxPerDeg: ppd,
                                         yawRange: baseYaw, pitchRange: basePitch,
                                         onChange: { coordinator.updateStack($0) })
                            }
                        }
                    }
                    .frame(width: contentW, height: contentH)
                    .coordinateSpace(name: spaceName)
                }
            }
            .frame(height: Self.viewportHeight)
            .clipShape(RoundedRectangle(cornerRadius: 8))
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
    var selected: Bool = false
    var onSelect: () -> Void = {}
    var onChange: (VirtualScreenConfig) -> Void
    /// Right-click delete; nil for physical monitors (which can't be removed).
    var onDelete: (() -> Void)? = nil

    @State private var cfg: VirtualScreenConfig

    init(initial: VirtualScreenConfig, area: CGSize, coordinateSpace: String, accent: Color,
         pxPerDeg: CGFloat, yawRange: Double, pitchRange: Double,
         lookedAt: Bool, selected: Bool = false, onSelect: @escaping () -> Void = {},
         onChange: @escaping (VirtualScreenConfig) -> Void, onDelete: (() -> Void)? = nil) {
        self.initial = initial
        self.area = area
        self.coordinateSpace = coordinateSpace
        self.accent = accent
        self.pxPerDeg = pxPerDeg
        self.yawRange = yawRange
        self.pitchRange = pitchRange
        self.lookedAt = lookedAt
        self.selected = selected
        self.onSelect = onSelect
        self.onChange = onChange
        self.onDelete = onDelete
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

    private var borderColor: Color {
        if selected { return PanelTheme.accent }
        return lookedAt ? .yellow : .white.opacity(0.5)
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
                .strokeBorder(borderColor, lineWidth: selected ? 2.5 : (lookedAt ? 2 : 1)))
            .frame(width: w, height: h)
            .position(point())
            .onTapGesture { onSelect() }
            .gesture(
                DragGesture(coordinateSpace: .named(coordinateSpace))
                    .onChanged { onSelect(); apply(location: $0.location) }
            )
            .contextMenu {
                if let onDelete {
                    Button("Delete Display", systemImage: "trash", role: .destructive) { onDelete() }
                }
            }
            .onChange(of: initial) { newValue in if newValue != cfg { cfg = newValue } }
    }
}

/// A draggable HUD-widget box in the floating zone of the layout map — drag to set its yaw/pitch.
private struct WidgetBox: View {
    let initial: HUDWidget
    let area: CGSize
    let coordinateSpace: String
    let pxPerDeg: CGFloat
    let yawRange: Double
    let pitchRange: Double
    var onChange: (HUDWidget) -> Void

    @State private var cfg: HUDWidget

    init(initial: HUDWidget, area: CGSize, coordinateSpace: String, pxPerDeg: CGFloat,
         yawRange: Double, pitchRange: Double, onChange: @escaping (HUDWidget) -> Void) {
        self.initial = initial
        self.area = area
        self.coordinateSpace = coordinateSpace
        self.pxPerDeg = pxPerDeg
        self.yawRange = yawRange
        self.pitchRange = pitchRange
        self.onChange = onChange
        _cfg = State(initialValue: initial)
    }

    // Must match WidgetManager.baseWidthMeters; aspect is approximate per kind for the map box.
    private static let baseWidthMeters = 0.225
    private var displayAspect: Double { cfg.kind == .clock ? 3.0 : 2.6 }

    private func point() -> CGPoint {
        CGPoint(x: area.width / 2 - CGFloat(cfg.yawDegrees) * pxPerDeg,
                y: area.height / 2 - CGFloat(cfg.pitchDegrees) * pxPerDeg)
    }

    private func apply(location: CGPoint) {
        cfg.yawDegrees = min(yawRange, max(-yawRange, Double((area.width / 2 - location.x) / pxPerDeg)))
        cfg.pitchDegrees = min(pitchRange, max(-pitchRange, Double((area.height / 2 - location.y) / pxPerDeg)))
        onChange(cfg)
    }

    var body: some View {
        let widthMeters = Self.baseWidthMeters * cfg.scale
        let heightMeters = widthMeters / displayAspect
        let dist = max(0.1, cfg.distanceMeters)
        let angW = 2 * atan((widthMeters / 2) / dist) * 180 / .pi
        let angH = 2 * atan((heightMeters / 2) / dist) * 180 / .pi
        let w = max(20, CGFloat(angW) * pxPerDeg)
        let h = max(12, CGFloat(angH) * pxPerDeg)
        return RoundedRectangle(cornerRadius: 5)
            .fill(Color.purple.opacity(0.5))
            .overlay(Image(systemName: cfg.kind.symbol).font(.system(size: 9)).foregroundStyle(.white))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.6), lineWidth: 1))
            .frame(width: w, height: h)
            .position(point())
            .gesture(
                DragGesture(coordinateSpace: .named(coordinateSpace))
                    .onChanged { apply(location: $0.location) }
            )
            .onChange(of: initial) { newValue in if newValue != cfg { cfg = newValue } }
    }
}

/// A draggable stack-container box in the floating zone — drag to set the stack's yaw/pitch.
private struct StackBox: View {
    let initial: HUDStack
    let area: CGSize
    let coordinateSpace: String
    let pxPerDeg: CGFloat
    let yawRange: Double
    let pitchRange: Double
    var onChange: (HUDStack) -> Void

    @State private var cfg: HUDStack

    init(initial: HUDStack, area: CGSize, coordinateSpace: String, pxPerDeg: CGFloat,
         yawRange: Double, pitchRange: Double, onChange: @escaping (HUDStack) -> Void) {
        self.initial = initial; self.area = area; self.coordinateSpace = coordinateSpace
        self.pxPerDeg = pxPerDeg; self.yawRange = yawRange; self.pitchRange = pitchRange
        self.onChange = onChange
        _cfg = State(initialValue: initial)
    }

    private func point() -> CGPoint {
        CGPoint(x: area.width / 2 - CGFloat(cfg.yawDegrees) * pxPerDeg,
                y: area.height / 2 - CGFloat(cfg.pitchDegrees) * pxPerDeg)
    }

    private func apply(location: CGPoint) {
        cfg.yawDegrees = min(yawRange, max(-yawRange, Double((area.width / 2 - location.x) / pxPerDeg)))
        cfg.pitchDegrees = min(pitchRange, max(-pitchRange, Double((area.height / 2 - location.y) / pxPerDeg)))
        onChange(cfg)
    }

    var body: some View {
        let w: CGFloat = cfg.axis == .vertical ? 26 : 40
        let h: CGFloat = cfg.axis == .vertical ? 40 : 26
        return RoundedRectangle(cornerRadius: 5)
            .fill(Color.teal.opacity(0.5))
            .overlay(Image(systemName: "rectangle.stack").font(.system(size: 10)).foregroundStyle(.white))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.7), lineWidth: 1))
            .frame(width: w * CGFloat(cfg.scale), height: h * CGFloat(cfg.scale))
            .position(point())
            .gesture(DragGesture(coordinateSpace: .named(coordinateSpace)).onChanged { apply(location: $0.location) })
            .onChange(of: initial) { newValue in if newValue != cfg { cfg = newValue } }
    }
}

/// An NSScrollView hosting SwiftUI content. Unlike a nested SwiftUI ScrollView, it consumes
/// scroll events and does not chain them to the outer panel when it can't scroll further.
struct NonChainingScrollView<Content: View>: NSViewRepresentable {
    let contentSize: CGSize
    var onMagnify: (CGFloat) -> Void
    let content: Content

    init(contentSize: CGSize, onMagnify: @escaping (CGFloat) -> Void,
         @ViewBuilder content: () -> Content) {
        self.contentSize = contentSize
        self.onMagnify = onMagnify
        self.content = content()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NoChainScrollView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.onMagnify = onMagnify
        let hosting = NSHostingView(rootView: content)
        hosting.frame = CGRect(origin: .zero, size: contentSize)
        scroll.documentView = hosting
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let hosting = scroll.documentView as? NSHostingView<Content> else { return }
        (scroll as? NoChainScrollView)?.onMagnify = onMagnify
        hosting.rootView = content
        hosting.frame = CGRect(origin: .zero, size: contentSize)
        let clip = scroll.contentView.bounds.size
        guard clip.width > 0 else { return }
        let coord = context.coordinator
        if !coord.centered {
            scroll.contentView.scroll(to: NSPoint(x: max(0, (contentSize.width - clip.width) / 2),
                                                  y: max(0, (contentSize.height - clip.height) / 2)))
            scroll.reflectScrolledClipView(scroll.contentView)
            coord.centered = true
        } else if let last = coord.lastContentSize, last != contentSize {
            // Zoom changed: keep the point under the viewport centre fixed (centre-anchored).
            let rx = contentSize.width / last.width, ry = contentSize.height / last.height
            var o = scroll.contentView.bounds.origin
            o.x = (o.x + clip.width / 2) * rx - clip.width / 2
            o.y = (o.y + clip.height / 2) * ry - clip.height / 2
            o.x = min(max(0, o.x), max(0, contentSize.width - clip.width))
            o.y = min(max(0, o.y), max(0, contentSize.height - clip.height))
            scroll.contentView.scroll(to: o)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        coord.lastContentSize = contentSize
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var centered = false; var lastContentSize: CGSize? }

    final class NoChainScrollView: NSScrollView {
        var onMagnify: ((CGFloat) -> Void)?

        // Scroll the content ourselves and consume the event — never call super, so the
        // scroll is not forwarded to the enclosing panel when we're at (or can't reach) a bound.
        override func scrollWheel(with event: NSEvent) {
            guard let doc = documentView else { return }
            let visible = contentView.bounds.size
            let maxX = max(0, doc.frame.width - visible.width)
            let maxY = max(0, doc.frame.height - visible.height)
            var o = contentView.bounds.origin
            o.x = min(maxX, max(0, o.x - event.scrollingDeltaX))
            o.y = min(maxY, max(0, o.y - event.scrollingDeltaY))
            contentView.scroll(to: o)
            reflectScrolledClipView(contentView)
        }

        // Trackpad pinch → zoom (handled by the SwiftUI binding via the closure).
        override func magnify(with event: NSEvent) { onMagnify?(event.magnification) }
    }
}

/// One editable voice-command row: an enable toggle, the action title, and a comma-separated phrases
/// field. Commits to the store on toggle change or when editing the field ends.
private struct VoiceBindingRow: View {
    let binding: VoiceBinding
    let onChange: (VoiceBinding) -> Void
    let onTest: (@escaping (String) -> Void) -> Void
    @State private var phrasesText: String
    @State private var enabled: Bool
    @State private var heardText = ""
    @State private var testing = false

    init(binding: VoiceBinding, onChange: @escaping (VoiceBinding) -> Void,
         onTest: @escaping (@escaping (String) -> Void) -> Void) {
        self.binding = binding
        self.onChange = onChange
        self.onTest = onTest
        _phrasesText = State(initialValue: binding.phrases.joined(separator: ", "))
        _enabled = State(initialValue: binding.enabled)
    }

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $enabled).labelsHidden().controlSize(.small)
                .onChange(of: enabled) { _ in commit() }
            VStack(alignment: .leading, spacing: 2) {
                Text(binding.intent.title).font(.caption).fontWeight(.medium)
                TextField("phrases, comma separated", text: $phrasesText)
                    .textFieldStyle(.roundedBorder).font(.system(.caption2, design: .monospaced))
                    .onSubmit { commit() }
                if !heardText.isEmpty {
                    HStack(spacing: 6) {
                        Text("Heard: \u{201C}\(heardText)\u{201D}")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        Button("Add phrase") { addHeard() }.controlSize(.mini)
                        Button("Dismiss") { heardText = "" }
                            .controlSize(.mini).buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
            Button {
                heardText = ""; testing = true
                onTest { text in testing = false; heardText = text }
            } label: {
                Image(systemName: testing ? "mic.fill" : "mic.circle")
                    .foregroundStyle(testing ? .red : .accentColor)
            }
            .buttonStyle(.plain).disabled(testing)
            .help("Say this command, then add what was heard as a trigger phrase (tunes it to your voice).")
        }
        .opacity(enabled ? 1 : 0.5)
    }

    /// Append the recognizer's transcript to this command's phrases (lowercased).
    private func addHeard() {
        let h = heardText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !h.isEmpty else { return }
        if !phrasesText.isEmpty { phrasesText += ", " }
        phrasesText += h
        heardText = ""
        commit()
    }

    private func commit() {
        var b = binding
        b.enabled = enabled
        b.phrases = phrasesText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        onChange(b)
    }
}

/// A compact KPI tile: icon, big value, label. Tappable when `action` is set. Standalone (not a
/// method on the panel) so the live-telemetry tiles — which observe the lightweight `LiveStats`
/// rather than the whole coordinator — can build identical tiles.
struct KPITile: View {
    let title: String
    let value: String
    let system: String
    let tint: Color
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Image(systemName: system).font(.callout).foregroundStyle(tint)
            Text(value).font(.system(.title3, design: .rounded).weight(.semibold))
                .lineLimit(1).minimumScaleFactor(0.55)
            Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 74, maxHeight: 74, alignment: .topLeading)
        .background(PanelTheme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.35)))
        .contentShape(Rectangle())
        .onTapGesture { action?() }
    }
}

/// The dashboard's live readout tiles (Render fps, IMU temp, head orientation). Observes `LiveStats`
/// directly, so it keeps updating during AR while re-rendering only these three cells — not the
/// whole control panel (which is what used to cause head-tracking judder, so they were frozen in AR).
/// Rendered as three grid cells via `Group`, so they flow into the parent `LazyVGrid`.
private struct DashboardLiveTiles: View {
    @ObservedObject var live: LiveStats

    var body: some View {
        Group {
            KPITile(title: "Render", value: String(format: "%.0f fps", live.renderFPS),
                    system: "speedometer", tint: .secondary)
            KPITile(title: "Temp",
                    value: live.imuTemperature > 0 ? String(format: "%.0f°C", live.imuTemperature) : "—",
                    system: "thermometer.medium",
                    tint: live.imuTemperature >= 45 ? .orange : .secondary)
            orientationTile
        }
    }

    /// Combined head-orientation tile: one row per axis — icon, signed value, axis label.
    private var orientationTile: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("arrow.left.arrow.right", live.euler.yaw, "Yaw")
            row("arrow.up.arrow.down", live.euler.pitch, "Pitch")
            row("rotate.3d", live.euler.roll, "Roll")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(PanelTheme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.35)))
    }

    private func row(_ system: String, _ value: Double, _ label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: system).font(.caption).foregroundStyle(.secondary).frame(width: 16)
            Text(String(format: "%+.1f°", value))
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}

/// Diagnostics → IMU live rows (temperature, linear accel, sample rate). Observes `LiveStats` so it
/// refreshes during AR too, without re-rendering the rest of the Diagnostics page.
private struct IMUDiagnosticsRows: View {
    @ObservedObject var live: LiveStats

    var body: some View {
        let a = live.linearAccel
        let mag = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
        VStack(alignment: .leading, spacing: 4) {
            Text(String(format: "Temperature   %.1f °C", live.imuTemperature))
                .font(.system(.caption, design: .monospaced))
            Text(String(format: "Linear accel (g)   x %+.2f   y %+.2f   z %+.2f   |a| %.2f",
                        a.x, a.y, a.z, mag))
                .font(.system(.caption, design: .monospaced))
            Text(String(format: "Sample rate   %.0f Hz", live.imuRate))
                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
        }
    }
}

/// Head-locked video player: transport controls + the 5 FOV positions. The playlist lives in
/// `MediaPlaylist`. Global shortcuts (AR active): ⌃⌥1–5 positions, ⌃⌥0 stop, ⌃⌥K play/pause,
/// ⌃⌥← / ⌃⌥→ rewind / skip 10s.
struct MediaPlayerControls: View {
    @ObservedObject var media: MediaPlayerManager
    let coordinator: AppCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = media.errorMessage {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).font(.caption).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button { media.clearError() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.15)))
            }
            Text(media.currentName ?? "Nothing playing")
                .font(.caption).foregroundStyle(media.hasMedia ? .primary : .secondary)
                .lineLimit(1).truncationMode(.middle)

            HStack(spacing: 6) {
                transport("backward.end.fill", "Previous (in playlist)") { coordinator.mediaPrevious() }
                transport("gobackward.10", "Rewind 10s · ⌃⌥←") { coordinator.mediaSkip(-10) }
                transport(media.playing ? "pause.fill" : "play.fill", "Play/Pause · ⌃⌥K") { coordinator.toggleMediaPlay() }
                transport("goforward.10", "Skip 10s · ⌃⌥→") { coordinator.mediaSkip(10) }
                transport("forward.end.fill", "Next (in playlist)") { coordinator.mediaNext() }
                transport("stop.fill", "Stop · ⌃⌥0") { coordinator.stopMedia() }
                Spacer()
            }
            .disabled(!media.hasMedia)

            HStack(spacing: 8) {
                Text("Position").font(.caption)
                Picker("", selection: Binding(get: { media.position },
                                              set: { coordinator.setMediaPosition($0) })) {
                    ForEach(MediaPlayerManager.Position.allCases) { Text($0.label).tag($0) }
                }.labelsHidden().fixedSize()
                Spacer()
                Text("⌃⌥1–5").font(.caption2).foregroundStyle(.secondary)
            }
            if !coordinator.arActive {
                Text("Start AR to see the video in the glasses.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func transport(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 22) }
            .buttonStyle(.bordered).controlSize(.small).help(help)
    }
}

/// The transient in-AR progress bar, rasterized to a texture and shown for ~2s on transport actions.
struct MediaProgressView: View {
    let current: Double
    let duration: Double
    let playing: Bool

    private func fmt(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let t = Int(s.rounded()); return String(format: "%d:%02d", t / 60, t % 60)
    }

    var body: some View {
        let frac = duration > 0 ? min(1, max(0, current / duration)) : 0
        let barW: CGFloat = 380
        return HStack(spacing: 14) {
            Image(systemName: playing ? "play.fill" : "pause.fill").font(.system(size: 15))
            Text(fmt(current)).font(.system(.subheadline, design: .rounded).monospacedDigit())
                .frame(width: 54, alignment: .trailing)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25)).frame(width: barW, height: 8)
                Capsule().fill(.white).frame(width: max(8, barW * frac), height: 8)
            }.frame(width: barW)
            Text(fmt(duration)).font(.system(.subheadline, design: .rounded).monospacedDigit())
                .frame(width: 54, alignment: .leading)
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
        .background(Color.black.opacity(0.55), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
        .foregroundStyle(.white)
    }
}

/// The video playlist: add files, click to play, reorder, remove. Plays through automatically.
struct MediaPlaylist: View {
    @ObservedObject var media: MediaPlayerManager
    let coordinator: AppCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Add videos…") { coordinator.openMediaFile() }.controlSize(.small)
                Spacer()
                if !media.playlist.isEmpty {
                    Text("\(media.playlist.count) item\(media.playlist.count == 1 ? "" : "s")")
                        .font(.caption2).foregroundStyle(.secondary)
                    Button("Clear") { coordinator.clearMediaPlaylist() }.controlSize(.small)
                }
            }
            if media.playlist.isEmpty {
                Text("Add local or network-drive videos. They play one after another. "
                     + "(Most formats, incl. MKV/AVI — played by VLC.)")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                List {
                    ForEach(Array(media.playlist.enumerated()), id: \.element.id) { idx, item in
                        HStack(spacing: 8) {
                            Image(systemName: rowIcon(idx))
                                .font(.caption2)
                                .foregroundStyle(idx == media.currentIndex ? Color.accentColor : .secondary)
                            Text(item.name).font(.caption).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            if let d = item.duration {
                                Text(Self.durationLabel(d))
                                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            Button { coordinator.mediaPlayer?.removeItem(item.id) } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }.buttonStyle(.plain)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { coordinator.mediaPlayer?.play(at: idx) }
                    }
                    .onMove { coordinator.mediaPlayer?.move(from: $0, to: $1) }
                }
                .listStyle(.plain).frame(height: min(260, CGFloat(media.playlist.count) * 30 + 12))
            }
        }
    }

    /// Current item's icon reflects the playback state: playing ▶ / paused ⏸ / stopped ⏹ (position
    /// Off with the item still current); other rows show a film glyph.
    private func rowIcon(_ idx: Int) -> String {
        guard idx == media.currentIndex else { return "film" }
        if media.position == .off { return "stop.fill" }
        return media.playing ? "play.fill" : "pause.fill"
    }

    /// "1:23:45" / "23:45" style duration.
    static func durationLabel(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "" }
        let t = Int(seconds.rounded())
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
