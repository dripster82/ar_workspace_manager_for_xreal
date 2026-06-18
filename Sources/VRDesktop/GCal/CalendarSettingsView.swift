import SwiftUI

/// Google Calendar connection controls for the HUD Widgets card: OAuth credentials (user's own
/// Google Cloud "Desktop app" client), connect/disconnect, status, and poll interval.
struct CalendarSettingsView: View {
    @ObservedObject var calendar: GoogleCalendarService
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text("In Google Calendar → Settings → your calendar → “Integrate calendar”, copy the "
                     + "“Secret address in iCal format” and paste it here. No Google project needed.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                field("iCal URL",
                      TextField("https://calendar.google.com/calendar/ical/…/basic.ics",
                                text: Binding(get: { calendar.icalURL }, set: { calendar.icalURL = $0 })))

                HStack {
                    Text("Refresh every").font(.caption)
                    Picker("", selection: $calendar.pollSeconds) {
                        ForEach(GoogleCalendarService.pollOptions, id: \.seconds) { Text($0.label).tag($0.seconds) }
                    }.labelsHidden().fixedSize()
                    Spacer()
                }

                HStack(spacing: 10) {
                    switch calendar.state {
                    case .connecting:
                        ProgressView().controlSize(.small); Text("Loading…").font(.caption)
                    case .connected:
                        Button("Disconnect") { calendar.disconnect() }.controlSize(.small)
                    default:
                        Button("Connect") { calendar.connect() }.controlSize(.small)
                    }
                    Spacer()
                }
            }
            .padding(.leading, 8)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "calendar").foregroundStyle(.secondary)
                Text("Google Calendar connection").font(.caption)
                Spacer()
                statusBadge
            }
        }
    }

    @ViewBuilder private var statusBadge: some View {
        switch calendar.state {
        case .connected(let account):
            Label(account, systemImage: "checkmark.circle.fill")
                .font(.caption2).foregroundStyle(.green).lineLimit(1)
        case .connecting:
            Text("connecting…").font(.caption2).foregroundStyle(.secondary)
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
