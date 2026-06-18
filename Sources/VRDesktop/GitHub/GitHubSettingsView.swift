import SwiftUI

/// GitHub connection controls for the HUD Widgets card: a personal access token, optional org
/// scope, poll interval, and status. Shown when a GitHub widget exists.
struct GitHubSettingsView: View {
    @ObservedObject var github: GitHubService
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Create a personal access token (classic) with repo scope, then paste it here. "
                     + "Leave Org blank to count across all repos the token can see.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                field("Token", SecureField("ghp_…",
                    text: Binding(get: { github.token }, set: { github.token = $0 })))
                field("Org (optional)", TextField("my-org",
                    text: Binding(get: { github.org }, set: { github.org = $0 })))

                HStack {
                    Text("Refresh every").font(.caption)
                    Picker("", selection: $github.pollSeconds) {
                        ForEach(GitHubService.pollOptions, id: \.seconds) { Text($0.label).tag($0.seconds) }
                    }.labelsHidden().fixedSize()
                    Spacer()
                }

                HStack(spacing: 10) {
                    switch github.state {
                    case .connecting:
                        ProgressView().controlSize(.small); Text("Checking…").font(.caption)
                    case .connected:
                        Button("Refresh now") { github.refreshNow() }.controlSize(.small)
                        Button("Disconnect") { github.disconnect() }.controlSize(.small)
                    default:
                        Button("Connect") { github.connect() }.controlSize(.small)
                    }
                    Spacer()
                }

                queryEditor
            }
            .padding(.leading, 8)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left.forwardslash.chevron.right").foregroundStyle(.secondary)
                Text("GitHub connection").font(.caption)
                Spacer()
                statusBadge
            }
        }
    }

    @State private var queriesOpen = false

    @ViewBuilder private var queryEditor: some View {
        DisclosureGroup("Edit search queries", isExpanded: $queriesOpen) {
            VStack(alignment: .leading, spacing: 6) {
                Text("One GitHub search per row. {fresh} expands to a recent-activity filter; the Org "
                     + "above is appended automatically.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(GitHubService.queryDefs, id: \.key) { def in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(def.label).font(.caption2).foregroundStyle(.secondary)
                        TextField(def.def, text: Binding(
                            get: { github.query(def.key) },
                            set: { github.setQuery(def.key, $0) }))
                            .textFieldStyle(.roundedBorder).font(.system(.caption, design: .monospaced))
                    }
                }
                HStack {
                    Button("Reset to defaults") { github.resetQueries() }.controlSize(.small)
                    Spacer()
                }
            }
            .padding(.leading, 8)
        }
        .font(.caption)
    }

    @ViewBuilder private var statusBadge: some View {
        switch github.state {
        case .connected(let login):
            Label("@\(login)", systemImage: "checkmark.circle.fill").font(.caption2).foregroundStyle(.green)
        case .connecting:
            Text("checking…").font(.caption2).foregroundStyle(.secondary)
        case .error(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .font(.caption2).foregroundStyle(.orange).lineLimit(1)
        case .disconnected:
            Text("not connected").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func field<F: View>(_ label: String, _ field: F) -> some View {
        HStack {
            Text(label).font(.caption).frame(width: 92, alignment: .leading)
            field.textFieldStyle(.roundedBorder).font(.caption)
        }
    }
}
