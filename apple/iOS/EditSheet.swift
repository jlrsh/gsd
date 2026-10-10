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
    @State private var when = ""
    @State private var usePicker = false
    @State private var pickerDate = Date()
    @State private var pickerAllDay = false
    @State private var noDate = false
    @FocusState private var focus: Field?

    enum Field { case title, when }

    private var parsed: (Date, Bool)? { ParseWhen.parse(when, now: model.now, zone: model.zone) }

    /// (due, allDay) the sheet would save, or nil when unreadable.
    private var resolved: (Date?, Bool)? {
        if noDate { return (nil, true) }
        if usePicker {
            if pickerAllDay {
                var cal = Calendar(identifier: .gregorian)
                cal.timeZone = model.zone
                let c = cal.dateComponents([.year, .month, .day], from: pickerDate)
                return (Clock.midnight(Day(c.year!, c.month!, c.day!), model.zone), true)
            }
            return (pickerDate, false)
        }
        return parsed.map { ($0.0, $0.1) }
    }

    private var preview: String {
        guard let (due, allDay) = resolved else { return "can't read that date — try “fri 5pm” or 2026-09-12" }
        guard let due else { return "No date" }
        let label = Rows.dayLabel(Clock.day(due, model.zone), today: Clock.day(model.now, model.zone))
        return allDay ? label : "\(label) · \(Item(key: "", title: "", due: due, allDay: false).timeLabel(model.zone))"
    }

    private var isNew: Bool { if case .new = target { return true }; return false }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                        .focused($focus, equals: .title)
                        .submitLabel(.next)
                        .onSubmit { focus = .when }
                }
                Section {
                    Toggle("No date", isOn: $noDate.animation())
                    if !noDate {
                        Toggle("Pick from calendar", isOn: $usePicker.animation())
                        if usePicker {
                            Toggle("All day", isOn: $pickerAllDay)
                            DatePicker("Due", selection: $pickerDate,
                                       displayedComponents: pickerAllDay ? [.date] : [.date, .hourAndMinute])
                                .environment(\.timeZone, model.zone)
                        } else {
                            TextField("today, fri 5pm, +3, 9/12 23:59", text: $when)
                                .focused($focus, equals: .when)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .submitLabel(.done)
                                .onSubmit(save)
                        }
                    }
                } header: {
                    Text("Due")
                } footer: {
                    Text(preview)
                        .foregroundStyle(resolved == nil ? Color.red : Color.secondary)
                        .monospacedDigit()
                }
            }
            .navigationTitle(isNew ? "Add" : "Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Add" : "Save", action: save)
                        .disabled(title.trimmed.isEmpty || resolved == nil)
                }
            }
            .onAppear(perform: load)
        }
        .presentationDetents([.medium, .large])
    }

    private func load() {
        switch target {
        case .new:
            focus = .title
        case .edit(let item):
            title = item.title
            if let due = item.due {
                pickerDate = due
                pickerAllDay = item.allDay
                usePicker = true
            } else {
                noDate = true
            }
        }
    }

    private func save() {
        guard !title.trimmed.isEmpty, let (due, allDay) = resolved else { return }
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
