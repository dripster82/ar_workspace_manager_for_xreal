import SwiftUI

/// Slack connection controls for the HUD Widgets card: OAuth credentials, connect/disconnect,
/// and status. Credentials are entered by the user (their own personal Slack app).
struct SlackSettingsView: View {
    @ObservedObject var slack: SlackService
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Create a personal Slack app, add the user scopes below, add the redirect URL, "
                     + "install it, then paste its Client ID & Secret here and Connect.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                labeledField("Client ID",
                             TextField("xxxxxxxx.xxxxxxxx",
                                       text: Binding(get: { slack.clientID }, set: { slack.clientID = $0 })))
                labeledField("Client Secret",
                             SecureField("•••••••••••••",
                                         text: Binding(get: { slack.clientSecret }, set: { slack.clientSecret = $0 })))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Redirect URL (add to your Slack app):").font(.caption2).foregroundStyle(.secondary)
                    Text(SlackService.redirectURI)
                        .font(.caption.monospaced()).textSelection(.enabled)
                    Text("User scopes: \(SlackService.scopes)").font(.caption2).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                HStack(spacing: 10) {
                    switch slack.state {
                    case .connecting:
                        ProgressView().controlSize(.small)
                        Text("Waiting for sign-in…").font(.caption)
                    case .connected:
                        Button("Disconnect") { slack.disconnect() }.controlSize(.small)
                    default:
                        Button("Connect") { slack.connect() }.controlSize(.small)
                    }
                    Spacer()
                }
            }
            .padding(.leading, 8)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "message.badge").foregroundStyle(.secondary)
                Text("Slack connection").font(.caption)
                Spacer()
                statusBadge
            }
        }
    }

    @ViewBuilder private var statusBadge: some View {
        switch slack.state {
        case .connected(let user):
            Label(user, systemImage: "checkmark.circle.fill")
                .font(.caption2).foregroundStyle(.green)
        case .connecting:
            Text("connecting…").font(.caption2).foregroundStyle(.secondary)
        case .error(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .font(.caption2).foregroundStyle(.orange).lineLimit(1)
        case .disconnected:
            Text("not connected").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func labeledField<F: View>(_ label: String, _ field: F) -> some View {
        HStack {
            Text(label).font(.caption).frame(width: 92, alignment: .leading)
            field.textFieldStyle(.roundedBorder).font(.caption)
        }
    }
}
