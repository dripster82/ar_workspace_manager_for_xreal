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

                HStack {
                    Text("Refresh every").font(.caption)
                    Picker("", selection: $slack.pollSeconds) {
                        ForEach(SlackService.pollOptions, id: \.seconds) { Text($0.label).tag($0.seconds) }
                    }.labelsHidden().fixedSize()
                    Spacer()
                }

                priorityPicker

                HStack(spacing: 10) {
                    switch slack.state {
                    case .connecting:
                        ProgressView().controlSize(.small)
                        Text("Waiting for sign-in…").font(.caption)
                    case .connected:
                        Button("Refresh now") { slack.refreshNow() }.controlSize(.small)
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

    @State private var priorityOpen = false

    @ViewBuilder private var priorityPicker: some View {
        DisclosureGroup(isExpanded: $priorityOpen) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Checked every refresh, regardless of rotation. Starred channels are always "
                     + "included automatically.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if slack.loadingPicker && slack.pickerOptions.isEmpty {
                    HStack { ProgressView().controlSize(.small); Text("Loading…").font(.caption) }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach([SlackService.ConvoOption.Kind.dm, .groupDM, .channel], id: \.self) { kind in
                            let items = slack.pickerOptions.filter { $0.kind == kind }
                            if !items.isEmpty {
                                Text(kind.rawValue).font(.caption2.bold()).foregroundStyle(.secondary)
                                ForEach(items) { opt in
                                    Toggle(opt.label, isOn: Binding(
                                        get: { slack.priorityIDs.contains(opt.id) },
                                        set: { slack.setPriority(opt.id, on: $0) }))
                                        .font(.caption).toggleStyle(.checkbox)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
            .padding(.leading, 8)
        } label: {
            HStack {
                Text("Priority conversations").font(.caption)
                Spacer()
                Text("\(slack.priorityIDs.count) selected").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .onChange(of: priorityOpen) { open in if open { slack.loadPickerOptions() } }
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
