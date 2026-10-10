import GSDCore
import SwiftUI

enum EditTarget: Identifiable {
    case new
    case edit(Item)

    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let item): return item.key
        }
    }
}

struct EditSheet: View {
    let target: EditTarget
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var date = Date()
    @State private var allDay = true
    @State private var noDate = false
    @FocusState private var titleFocused: Bool

    /// (due, allDay) the sheet would save.
    private var resolved: (Date?, Bool) {
        if noDate { return (nil, true) }
        guard allDay else { return (date, false) }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = model.zone
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return (Clock.midnight(Day(c.year!, c.month!, c.day!), model.zone), true)
    }

    private var isNew: Bool { if case .new = target { return true }; return false }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                        .focused($titleFocused)
                        .submitLabel(.done)
                        .onSubmit { titleFocused = false }
                }
                Section {
                    Toggle("No date", isOn: $noDate.animation())
                    if !noDate {
                        Toggle("All day", isOn: $allDay.animation())
                        DatePicker("Due", selection: $date,
                                   displayedComponents: allDay ? [.date] : [.date, .hourAndMinute])
                            .environment(\.timeZone, model.zone)
                    }
                } header: {
                    Text("Due")
                }
            }
            .navigationTitle(isNew ? "Add" : "Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Add" : "Save", action: save)
                        .disabled(title.trimmed.isEmpty)
                }
            }
            .onAppear(perform: load)
        }
        // Half height only: the keyboard would otherwise drag it to full screen.
        .presentationDetents([.medium])
    }

    private func load() {
        switch target {
        case .new:
            titleFocused = true
        case .edit(let item):
            title = item.title
            if let due = item.due {
                date = due
                allDay = item.allDay
            } else {
                noDate = true
            }
        }
    }

    private func save() {
        guard !title.trimmed.isEmpty else { return }
        let (due, allDay) = resolved
        switch target {
        case .new: model.addManual(title: title, due: due, allDay: allDay)
        case .edit(let item): model.editManual(item.key, title: title, due: due, allDay: allDay)
        }
        dismiss()
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
