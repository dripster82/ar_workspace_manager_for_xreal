import SwiftUI

/// Apple Reminders connection controls for the HUD connections card: grant full access (TCC), status,
/// and a route to System Settings when access was denied. Lists are picked per-widget on the List
/// widget's own row.
struct RemindersSettingsView: View {
    @ObservedObject var reminders: RemindersService
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Link a List HUD widget to an Apple Reminders list. Items sync via iCloud, and "
                     + "ticking an item off in the panel writes back to Reminders.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    switch reminders.auth {
                    case .authorized:
                        Button("Refresh now") { reminders.refreshAll() }.controlSize(.small)
                    case .denied, .restricted:
                        Button("Open System Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
                                NSWorkspace.shared.open(url)
                            }
                        }.controlSize(.small)
                    case .notDetermined:
                        Button("Grant Reminders Access") { reminders.requestAccess() }.controlSize(.small)
                    }
                    Spacer()
                }
            }
            .padding(.leading, 8)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checklist").foregroundStyle(.secondary)
                Text("Apple Reminders connection").font(.caption)
                Spacer()
                statusBadge
            }
        }
    }

    @ViewBuilder private var statusBadge: some View {
        switch reminders.auth {
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
