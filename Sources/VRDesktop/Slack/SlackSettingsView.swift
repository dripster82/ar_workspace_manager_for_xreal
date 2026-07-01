import SwiftUI

/// Slack connection controls for the HUD Widgets card: OAuth credentials, connect/disconnect,
/// and status. Credentials are entered by the user (their own personal Slack app).
struct SlackSettingsView: View {
    @ObservedObject var slack: SlackService
    /// Read new Slack messages aloud as they arrive (owned by the coordinator).
    @Binding var announce: Bool
    /// Selected text-to-speech voice identifier ("" = system default).
    @Binding var voiceID: String
    /// Speak a sample line now, to verify text-to-speech works independently of Slack detection.
    var onTest: () -> Void = {}
    /// Open System Settings ▸ Accessibility ▸ Spoken Content to download more voices.
    var onDownloadVoices: () -> Void = {}
    @State private var expanded = false
    @State private var voiceHelpExpanded = false
    private let voices = SpeechAnnouncer.englishVoices()

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

                HStack {
                    Toggle("Read new messages aloud", isOn: $announce)
                        .font(.caption)
                        .help("Speaks \u{201C}Slack message from <name>\u{201D} when a new unread message arrives "
                              + "(checked at the refresh interval above).")
                    Spacer()
                    Button("Test voice") { onTest() }.controlSize(.small)
                }
                if announce {
                    HStack(spacing: 8) {
                        Text("Voice").font(.caption)
                        Picker("", selection: $voiceID) {
                            Text("System default").tag("")
                            ForEach(voices) { Text($0.label).tag($0.id) }
                        }.labelsHidden().fixedSize()
                        Spacer()
                        Button("Download voices…") { onDownloadVoices() }.controlSize(.small)
                    }
                    DisclosureGroup(isExpanded: $voiceHelpExpanded) {
                        VStack(alignment: .leading, spacing: 3) {
                            voiceStep(1, "Click \u{201C}Download voices…\u{201D} above (opens System Settings ▸ "
                                       + "Accessibility ▸ Spoken Content).")
                            voiceStep(2, "Next to \u{201C}System voice\u{201D}, click the \u{24D8} (info) icon.")
                            voiceStep(3, "Find the voice you want (Enhanced/Premium sound the best) and click "
                                       + "the cloud download icon next to it to install.")
                            voiceStep(4, "Come back here — the new voices appear in the Voice list above.")
                        }
                        .padding(.top, 2)
                    } label: {
                        Text("How to add more voices").font(.caption)
                    }
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
                HStack {
                    Text("Checked every refresh, regardless of rotation. Starred channels are always "
                         + "included automatically.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Refresh list") { slack.loadPickerOptions(force: true) }
                        .controlSize(.small).disabled(slack.loadingPicker)
                }
                if slack.loadingPicker {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(slack.pickerOptions.isEmpty ? "Loading conversations…"
                             : "Refreshing… new people/channels may still be appearing")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
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

    private func voiceStep(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(n).").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            Text(text).font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
