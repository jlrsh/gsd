import GSDCore
import SwiftUI

/// Three pages side by side: swipe right from the list to add an item, left
/// for Completed.
struct ChecklistView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var page = Page.main
    @State private var editing: EditTarget?
    @State private var confirmDelete: Item?
    @State private var showSettings = false

    enum Page: Hashable { case add, main, completed }

    var body: some View {
        TabView(selection: $page) {
            AddPage().tag(Page.add)
            mainList.tag(Page.main)
            completedList.tag(Page.completed)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .onChange(of: page) { old, new in
            if new == .add {
                // The add page only peeks in; landing on it opens the editor.
                editing = .new
                withAnimation { page = .main }
            } else if old == .completed || new == .completed {
                // Checked rows file under Completed as you go to look at them.
                model.sweep()
            }
        }
        .sheet(item: $editing) { EditSheet(target: $0) }
        .sheet(isPresented: $showSettings) { SettingsSheet() }
        .confirmationDialog("Delete “\(confirmDelete?.title ?? "")”?", isPresented: deleteBinding, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let key = confirmDelete?.key { model.deleteManual(key) }
            }
        }
    }

    private var mainList: some View {
        List {
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
    }

    private var completedList: some View {
        List {
            Section {
                if model.view.completed.isEmpty {
                    ContentUnavailableView("Nothing completed", systemImage: "checkmark.circle",
                                           description: Text("Checked items land here."))
                        .listRowSeparator(.hidden)
                }
            } header: {
                HStack {
                    Label("Completed (\(model.view.completed.count))", systemImage: "checkmark.circle")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.green)
                    Spacer()
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape").font(.title3)
                    }
                    .accessibilityLabel("Settings")
                }
                .textCase(nil)
            }
            ForEach(model.view.completedSections) { section in
                Section {
                    ForEach(section.items) { row($0) }
                } header: {
                    SectionHeader(section: section)
                }
            }
        }
        .listStyle(.plain)
        .refreshable { await model.refreshAndWait() }
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

/// What peeks in while swiping right from the list.
struct AddPage: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "plus.circle.fill").font(.system(size: 44))
            Text("New assignment").font(.headline)
        }
        .foregroundStyle(Color.accentColor)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
