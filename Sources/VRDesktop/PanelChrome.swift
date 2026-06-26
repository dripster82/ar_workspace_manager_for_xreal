import SwiftUI

/// Design system for the redesigned control panel (dark + violet, sidebar app).
/// See Docs/Plan-ControlPanel-Redesign.md.
enum PanelTheme {
    static let accent = Color(red: 0.486, green: 0.361, blue: 0.988)   // ~#7C5CFC
    static let bg = Color(red: 0.055, green: 0.055, blue: 0.071)        // ~#0E0E12
    static let sidebar = Color(red: 0.071, green: 0.071, blue: 0.090)   // ~#12121A
    static let card = Color(red: 0.090, green: 0.090, blue: 0.114)      // ~#17171D
    static let border = Color.white.opacity(0.08)
    static let cardCorner: CGFloat = 14
}

/// Top-level destinations in the sidebar.
enum PanelRoute: String, CaseIterable, Identifiable {
    case dashboard, workspace, hudWidgets
    case windowRules, voiceCommands
    case settings, diagnostics
    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .workspace: return "Workspace"
        case .hudWidgets: return "HUD Widgets"
        case .windowRules: return "Window Rules"
        case .voiceCommands: return "Voice Commands"
        case .settings: return "Settings"
        case .diagnostics: return "Diagnostics"
        }
    }
    var subtitle: String {
        switch self {
        case .dashboard: return "Overview and quick actions"
        case .workspace: return "Arrange the displays in your workspace"
        case .hudWidgets: return "Customise your HUD (always in view)"
        case .windowRules: return "Automatically place apps on screens"
        case .voiceCommands: return "Hands-free control"
        case .settings: return "Preferences and advanced settings"
        case .diagnostics: return "Logs and display diagnostics"
        }
    }
    var icon: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .workspace: return "rectangle.3.group"
        case .hudWidgets: return "square.text.square"
        case .windowRules: return "wand.and.rays"
        case .voiceCommands: return "mic"
        case .settings: return "gearshape"
        case .diagnostics: return "stethoscope"
        }
    }
}

/// Settings sub-pages (per the UX review: Performance/Glasses/HUD/Shortcuts live here, not top-level).
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, glasses, hud, performance, permissions, shortcuts, about
    var id: String { rawValue }
    var label: String {
        switch self {
        case .general: return "General"
        case .glasses: return "Glasses"
        case .hud: return "HUD"
        case .performance: return "Performance"
        case .permissions: return "Permissions"
        case .shortcuts: return "Shortcuts"
        case .about: return "About"
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @ObservedObject var coordinator: AppCoordinator
    @Binding var route: PanelRoute

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Identity
            HStack(spacing: 10) {
                Image(systemName: "eyeglasses")
                    .font(.title3).foregroundStyle(PanelTheme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("AR Workspace Manager").font(.subheadline.weight(.semibold))
                    Text("v\(coordinator.appVersion)").font(.caption2).foregroundStyle(.secondary)
                    if let v = coordinator.updateAvailableVersion {
                        Button {
                            coordinator.pendingRoute = .settings
                            coordinator.pendingSettingsTab = .about
                        } label: {
                            Label("Update available: v\(v)", systemImage: "arrow.down.circle.fill")
                                .font(.caption2.weight(.medium)).foregroundStyle(.orange)
                        }
                        .buttonStyle(.plain).padding(.top, 2)
                    } else if coordinator.checkingForUpdate {
                        Text("Checking for updates…").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    group("MAIN", [.dashboard, .workspace, .hudWidgets])
                    group("AUTOMATION", [.windowRules, .voiceCommands])
                    group("SYSTEM", [.settings, .diagnostics])
                }
                .padding(.horizontal, 10)
            }
            Spacer(minLength: 8)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(PanelTheme.sidebar)
    }

    private func group(_ title: String, _ routes: [PanelRoute]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.bottom, 2)
            ForEach(routes) { r in NavRow(route: r, selected: route == r) { route = r } }
        }
    }

    /// Active workspace + Start/Stop AR — always visible (UX review item D).
    private var statusChip: some View {
        Button { coordinator.toggleAR() } label: {
            HStack(spacing: 9) {
                Circle().fill(coordinator.arActive ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(coordinator.activeWorkspaceName)
                        .font(.caption.weight(.medium)).lineLimit(1)
                    Text(coordinator.arActive ? "AR running — tap to stop" : "AR stopped — tap to start")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: coordinator.arActive ? "stop.fill" : "play.fill")
                    .font(.caption).foregroundStyle(coordinator.arActive ? .red : PanelTheme.accent)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PanelTheme.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(PanelTheme.border))
        }
        .buttonStyle(.plain)
    }
}

private struct NavRow: View {
    let route: PanelRoute
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: route.icon).frame(width: 18)
                Text(route.title).font(.callout)
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Color.white : Color.secondary)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowFill, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selected ? PanelTheme.accent.opacity(0.5) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var rowFill: Color {
        if selected { return PanelTheme.accent.opacity(0.28) }
        return hovering ? Color.white.opacity(0.08) : Color.white.opacity(0.04)
    }
}

// MARK: - Shared content chrome

/// Page title + subtitle header.
struct PageHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.title2.weight(.bold))
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Placeholder for not-yet-built pages (Window Rules engine, Voice Commands).
struct ComingSoon: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "hammer").font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }
}
