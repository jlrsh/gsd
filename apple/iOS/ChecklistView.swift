import GSDCore
import SwiftUI

struct ChecklistView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var showCompleted = false
    @State private var editing: EditTarget?
    @State private var showSettings = false
    @State private var confirmDelete: Item?

    var body: some View {
        NavigationStack {
            List {
                if !model.view.completed.isEmpty {
                    Section {
                        DisclosureGroup(isExpanded: $showCompleted) {
                            ForEach(model.view.completedSections) { section in
                                Text(section.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .listRowSeparator(.hidden)
                                    .padding(.top, 6)
                                ForEach(section.items) { row($0) }
                            }
                        } label: {
                            Label("Completed (\(model.view.completed.count))", systemImage: "checkmark.circle")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.green)
                        }
                    }
                }
                if model.view.mainSections.isEmpty {
                    Section {
                        ContentUnavailableView(emptyTitle, systemImage: "checkmark.seal", description: Text(emptyDetail))
                            .listRowSeparator(.hidden)
                    }
                }
                ForEach(model.view.mainSections) { section in
                    Section {
                        ForEach(section.items) { row($0) }
                    } header: {
                        SectionHeader(section: section)
                    }
                }
            }
            .listStyle(.plain)
            .refreshable { await model.refreshAndWait() }
            .navigationTitle("gsd")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { editing = .new } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add item")
                }
            }
            .safeAreaInset(edge: .bottom) { StatusBar() }
            .sheet(item: $editing) { EditSheet(target: $0) }
            .sheet(isPresented: $showSettings) { SettingsSheet() }
            .confirmationDialog("Delete “\(confirmDelete?.title ?? "")”?", isPresented: deleteBinding, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let key = confirmDelete?.key { model.deleteManual(key) }
                }
            }
        }
    }

    private var emptyTitle: String { model.doc.activeFeeds.isEmpty && !model.doc.gradescopeEnabled ? "No sources yet" : "Nothing due" }
    private var emptyDetail: String {
        model.doc.activeFeeds.isEmpty && !model.doc.gradescopeEnabled
            ? "Add a calendar feed or Gradescope in Settings, or import from terminal gsd."
            : "Pull down to refresh."
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })
    }

    @ViewBuilder
    private func row(_ item: Item) -> some View {
        RowView(item: item, done: model.isDone(item), now: model.now, zone: model.zone,
                toggle: { withAnimation(.snappy) { model.toggle(item) } },
                open: {
                    if let link = item.link, let url = URL(string: link) { openURL(url) } else { model.toggle(item) }
                })
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button { model.toggle(item) } label: {
                    Label(model.isDone(item) ? "Uncheck" : "Done", systemImage: model.isDone(item) ? "arrow.uturn.backward" : "checkmark")
                }
                .tint(model.isDone(item) ? .orange : .green)
            }
            .swipeActions(edge: .trailing) {
                if item.manual {
                    Button(role: .destructive) { confirmDelete = item } label: { Label("Delete", systemImage: "trash") }
                    Button { editing = .edit(item) } label: { Label("Edit", systemImage: "pencil") }.tint(.blue)
                }
            }
            .contextMenu {
                Button { model.toggle(item) } label: {
                    Label(model.isDone(item) ? "Uncheck" : "Check", systemImage: "checkmark.square")
                }
                if let link = item.link, let url = URL(string: link) {
                    Button { openURL(url) } label: { Label("Open Link", systemImage: "arrow.up.right.square") }
                    Button { UIPasteboard.general.string = link } label: { Label("Copy Link", systemImage: "doc.on.doc") }
                }
                if item.manual {
                    Button { editing = .edit(item) } label: { Label("Edit", systemImage: "pencil") }
                    Button(role: .destructive) { confirmDelete = item } label: { Label("Delete", systemImage: "trash") }
                }
            }
    }
}

struct SectionHeader: View {
    let section: ItemSection

    var body: some View {
        Text(section.title)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(section.style == .overdue ? Color.red : Color.accentColor)
            .textCase(nil)
    }
}

struct RowView: View {
    let item: Item
    let done: Bool
    let now: Date
    let zone: TimeZone
    let toggle: () -> Void
    let open: () -> Void

    private var overdue: Bool { !done && item.isOverdue(now: now, zone: zone) }

    /// Time of day, or the due date once overdue (as the TUI does).
    private var clock: String {
        if overdue, let due = item.due { return Rows.shortDate(due, zone) }
        return item.timeLabel(zone)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button(action: toggle) {
                Image(systemName: done ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(done ? Color.green : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(done ? "Uncheck" : "Check")

            Text(clock.isEmpty ? " " : clock)
                .font(.callout.monospacedDigit())
                .foregroundStyle(overdue ? Color.red : Color.secondary)
                .frame(width: 48, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                (Text(item.title) + Text(item.link == nil ? "" : "  ↗").foregroundStyle(.tertiary))
                    .strikethrough(done, color: .secondary)
                    .foregroundStyle(done ? Color.secondary : Color.primary)
                    .lineLimit(3)
                Text(item.source)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 2) {
            Text(model.statusLeft)
            if !model.statusRight.isEmpty { Text(model.statusRight) }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
