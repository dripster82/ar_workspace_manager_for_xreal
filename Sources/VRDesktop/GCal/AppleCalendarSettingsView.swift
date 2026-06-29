import SwiftUI

/// Apple Calendar connection controls for the HUD connections card: grant full access (TCC), status,
/// a route to System Settings when denied, and a multi-select of which calendars feed Calendar widgets
/// (a global selection, mirroring the global Google iCal feed). Per-widget source (Google/Apple/Both)
/// is chosen on each Calendar widget's own row.
struct AppleCalendarSettingsView: View {
    @ObservedObject var appleCalendar: AppleCalendarService
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Show your Apple Calendar events on a Calendar HUD widget. Choose Apple (or Both) "
                     + "as the source on the widget itself.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if appleCalendar.auth == .authorized {
                    if appleCalendar.calendars.isEmpty {
                        Text("No calendars found.").font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text("Calendars (none selected = all):").font(.caption2).foregroundStyle(.secondary)
                        ForEach(appleCalendar.calendars) { cal in
                            Toggle(cal.title, isOn: binding(for: cal.id)).font(.caption)
                        }
                    }
                }

                HStack(spacing: 10) {
                    switch appleCalendar.auth {
                    case .authorized:
                        Button("Refresh now") { appleCalendar.refresh() }.controlSize(.small)
                    case .denied, .restricted:
                        Button("Open System Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                                NSWorkspace.shared.open(url)
                            }
                        }.controlSize(.small)
                    case .notDetermined:
                        Button("Grant Calendar Access") { appleCalendar.requestAccess() }.controlSize(.small)
                    }
                    Spacer()
                }
            }
            .padding(.leading, 8)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "calendar").foregroundStyle(.secondary)
                Text("Apple Calendar connection").font(.caption)
                Spacer()
                statusBadge
            }
        }
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { appleCalendar.selectedCalendarIDs.contains(id) },
            set: { on in
                var ids = appleCalendar.selectedCalendarIDs
                if on { if !ids.contains(id) { ids.append(id) } }
                else { ids.removeAll { $0 == id } }
                appleCalendar.selectedCalendarIDs = ids
            })
    }

    @ViewBuilder private var statusBadge: some View {
        switch appleCalendar.auth {
        case .authorized:
            Label("connected", systemImage: "checkmark.circle.fill")
                .font(.caption2).foregroundStyle(.green).lineLimit(1)
        case .denied:
            Label("access denied", systemImage: "exclamationmark.triangle.fill")
                .font(.caption2).foregroundStyle(.orange).lineLimit(1)
        case .restricted:
            Text("restricted").font(.caption2).foregroundStyle(.secondary)
        case .notDetermined:
            Text("not connected").font(.caption2).foregroundStyle(.secondary)
        }
    }
}
