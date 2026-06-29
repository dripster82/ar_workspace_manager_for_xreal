import SwiftUI
import DisplayManager

/// Per-widget editor for a List widget, shown inside the widget's row: source toggle, title, and either
/// an in-app item editor or an Apple Reminders link + read-back checklist.
struct ListWidgetConfigView: View {
    @Binding var cfg: ListConfig
    var reminders: RemindersService?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Source").font(.caption).frame(width: 70, alignment: .leading)
                Picker("", selection: $cfg.source) {
                    ForEach(ListSource.allCases) { Text($0.displayName).tag($0) }
                }.labelsHidden().fixedSize()
                Spacer()
            }
            HStack {
                Text("Title").font(.caption).frame(width: 70, alignment: .leading)
                TextField("List", text: $cfg.title).textFieldStyle(.roundedBorder).font(.caption)
            }

            switch cfg.source {
            case .inApp:
                inAppEditor
            case .reminders:
                if let reminders {
                    RemindersListConfigView(cfg: $cfg, reminders: reminders)
                } else {
                    Text("Reminders unavailable.").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var inAppEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach($cfg.items) { $item in
                HStack(spacing: 6) {
                    Toggle("", isOn: $item.done).labelsHidden().controlSize(.small)
                    TextField("Item", text: $item.text).textFieldStyle(.roundedBorder).font(.caption)
                    Button { cfg.items.removeAll { $0.id == item.id } } label: {
                        Image(systemName: "trash")
                    }.buttonStyle(.borderless).controlSize(.small)
                }
            }
            Button("Add item") { cfg.items.append(ListItem(text: "")) }.controlSize(.small)
        }
    }
}

/// The Apple Reminders portion of the List widget editor: pick a list, show-completed toggle, and a
/// read-back checklist whose toggles write completion straight back to EventKit (the source of truth).
private struct RemindersListConfigView: View {
    @Binding var cfg: ListConfig
    @ObservedObject var reminders: RemindersService

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !reminders.isConnected {
                Button("Grant Reminders access") { reminders.requestAccess() }.controlSize(.small)
            } else {
                HStack {
                    Text("List").font(.caption).frame(width: 70, alignment: .leading)
                    Picker("", selection: Binding(get: { cfg.reminderListID ?? "" },
                                                  set: { cfg.reminderListID = $0.isEmpty ? nil : $0 })) {
                        Text("None").tag("")
                        ForEach(reminders.lists) { Text($0.title).tag($0.id) }
                    }.labelsHidden().fixedSize()
                    Spacer()
                }
                Toggle("Show completed", isOn: $cfg.showCompleted).font(.caption)

                let items = reminders.itemsByList[cfg.reminderListID ?? ""] ?? []
                ForEach(cfg.showCompleted ? items : items.filter { !$0.done }) { item in
                    HStack(spacing: 6) {
                        Button {
                            reminders.setCompleted(reminderID: item.id, done: !item.done)
                        } label: {
                            Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                        }.buttonStyle(.borderless).controlSize(.small)
                        Text(item.text).font(.caption).strikethrough(item.done)
                            .opacity(item.done ? 0.5 : 1)
                        Spacer()
                    }
                }
            }
        }
    }
}
