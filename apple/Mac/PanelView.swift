import AppKit
import GSDCore
import SwiftUI

/// The TUI's colour pairs (`setup_colors`).
enum TUI {
    static let font = Font.system(size: Metrics.fontSize, design: .monospaced)
    static let header = Color.blue
    static let overdue = Color.red
    static let accent = Color.cyan
    static let done = Color.green.opacity(0.75)

    static func inverse(_ scheme: ColorScheme) -> Color { scheme == .dark ? .black : .white }
    static let selection = Color.primary.opacity(0.88)
}

struct PanelView: View {
    @Environment(PanelState.self) private var state
    /// Offscreen rendering: no text field, which ImageRenderer can't draw.
    var snapshot = false

    var body: some View {
        GeometryReader { geo in
            let rows = Metrics.bodyRows(height: geo.size.height)
            VStack(spacing: 0) {
                TitleBar()
                Group {
                    switch state.mode {
                    case .help: HelpScreen()
                    case .sources: SourcesScreen()
                    default: ListScreen(bodyRows: rows)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                StatusLine(snapshot: snapshot)
            }
            .onAppear { state.bodyRows = rows }
            .onChange(of: rows) { _, new in state.bodyRows = new }
        }
        .ignoresSafeArea()
        .font(TUI.font)
    }
}

struct TitleBar: View {
    @Environment(AppModel.self) private var model
    @Environment(PanelState.self) private var state

    var body: some View {
        HStack(spacing: 10) {
            Text("gsd").bold().foregroundStyle(TUI.header)
            Text(subtitle).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(state.mode == .list ? "? keys · esc hide" : "esc back").foregroundStyle(.tertiary)
        }
        .lineLimit(1)
        .padding(.horizontal, Metrics.hPad)
        .padding(.top, 4)
        .frame(height: Metrics.titleHeight)
    }

    private var subtitle: String {
        switch state.mode {
        case .help: return "keys"
        case .sources: return "sources"
        default:
            let today = Clock.day(model.now, model.zone)
            return Rows.dayLabel(today, today: today)
        }
    }
}

struct ListScreen: View {
    @Environment(PanelState.self) private var state
    let bodyRows: Int

    var body: some View {
        let l = state.layout
        let cursor = state.cursorIndex(l)
        let top = PanelState.viewport(rows: l.rows, mainStart: l.mainStart, cursor: cursor, scroll: state.scroll, body: bodyRows)
        let end = max(top, min(l.rows.count, top + bodyRows))
        VStack(alignment: .leading, spacing: 0) {
            ForEach(top..<end, id: \.self) { i in
                RowLine(row: l.rows[i], selected: i == cursor)
            }
        }
    }
}

struct RowLine: View {
    let row: Row
    let selected: Bool

    var body: some View {
        content
            .padding(.horizontal, Metrics.hPad)
            .frame(maxWidth: .infinity, minHeight: Metrics.rowHeight, maxHeight: Metrics.rowHeight, alignment: .leading)
            .background(selected ? TUI.selection : Color.clear)
    }

    @ViewBuilder private var content: some View {
        switch row.kind {
        case .blank:
            Color.clear
        case .rule:
            Rectangle().fill(Color.secondary.opacity(0.35)).frame(height: 1)
        case .header:
            if row.style == .section {
                HStack(spacing: 0) {
                    Text("── \(row.text) ")
                    Rectangle().frame(height: 1)
                }
                .foregroundStyle(TUI.done)
            } else {
                Text(row.text).bold().foregroundStyle(row.style == .overdue ? TUI.overdue : TUI.header)
            }
        case .item:
            if let item = row.item { ItemLine(item: item, selected: selected) }
        }
    }
}

/// `[ ] 09:30  Title  ↗ ……… Source`, as `item_line` draws it.
struct ItemLine: View {
    @Environment(AppModel.self) private var model
    @Environment(PanelState.self) private var state
    @Environment(\.colorScheme) private var scheme
    let item: Item
    let selected: Bool

    var body: some View {
        let done = model.view.done.contains(item.key)
        let overdue = !done && item.isOverdue(now: model.now, zone: model.zone)
        let clock = overdue ? item.due.map { Rows.shortDate($0, model.zone) } ?? "" : item.timeLabel(model.zone)
        let inverse = TUI.inverse(scheme)
        let base: Color = selected ? inverse : (done ? TUI.done : .primary)
        HStack(spacing: 0) {
            Text(done ? "[x]" : "[ ]")
                .foregroundStyle(base)
                .onTapGesture { state.toggle(item) }
            Text(" " + String(repeating: " ", count: max(0, 5 - clock.count)) + clock + "  ")
                .foregroundStyle(selected ? inverse : (overdue ? TUI.overdue : base))
            Text(item.title + (item.link == nil ? "" : "  ↗"))
                .foregroundStyle(base)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Spacer(minLength: 16)
            Text(item.source)
                .foregroundStyle(selected ? inverse.opacity(0.65) : Color.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .contentShape(Rectangle())
        .onTapGesture { state.select(item.key) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { state.open(item) })
    }
}

struct HelpScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(PanelState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(PanelState.help, id: \.keys) { line in
                HStack(spacing: 0) {
                    Text(line.keys.padding(toLength: 18, withPad: " ", startingAt: 0)).foregroundStyle(TUI.accent)
                    Text(line.what)
                }
                .frame(height: Metrics.rowHeight)
            }
            Color.clear.frame(height: Metrics.rowHeight)
            Group {
                info("summon", state.shortcut)
                info("state", state.statePath)
                info("sync", model.syncStatus)
                info("timezone", model.zone.identifier)
            }
            .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .padding(.horizontal, Metrics.hPad)
    }

    private func info(_ label: String, _ value: String) -> some View {
        Text(label.padding(toLength: 9, withPad: " ", startingAt: 0) + value)
            .truncationMode(.middle)
            .frame(height: Metrics.rowHeight)
    }
}

/// The TUI's `show_sources`: toggle feeds and Gradescope, set the timezone.
struct SourcesScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(PanelState.self) private var state
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                Text("space toggle · t timezone · ⌘, settings · esc done")
                Text("Timezone: \(model.zone.identifier)" + (model.doc.timezoneSetting.lowercased() == "auto" ? " (auto)" : ""))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, Metrics.hPad)
            .frame(height: Metrics.rowHeight)
            Color.clear.frame(height: Metrics.rowHeight)
            ForEach(Array(state.sources.enumerated()), id: \.element.id) { i, source in
                let selected = i == state.sourceCursor
                HStack(spacing: 0) {
                    Text("[\(source.enabled ? "x" : " ")] \(source.label)")
                    Spacer(minLength: 16)
                    Text(detail(source)).foregroundStyle(selected ? TUI.inverse(scheme).opacity(0.65) : .secondary)
                }
                .foregroundStyle(selected ? TUI.inverse(scheme) : .primary)
                .padding(.horizontal, Metrics.hPad)
                .frame(maxWidth: .infinity, minHeight: Metrics.rowHeight, maxHeight: Metrics.rowHeight, alignment: .leading)
                .background(selected ? TUI.selection : Color.clear)
                .contentShape(Rectangle())
                .onTapGesture { state.sourceCursor = i }
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    state.sourceCursor = i
                    state.toggleSource()
                })
            }
            if model.doc.activeFeeds.isEmpty {
                Text("No calendar feeds yet — add one in Settings (⌘,).")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Metrics.hPad)
                    .frame(height: Metrics.rowHeight)
            }
        }
        .lineLimit(1)
    }

    private func detail(_ source: PanelState.Source) -> String {
        guard source.enabled else { return "off" }
        guard let s = model.status[source.id] else { return "" }
        if s.pending { return "fetching…" }
        if let e = s.error { return e }
        return s.fetchedAt.map { "updated " + GSDText.relTime($0, now: model.now) } ?? ""
    }
}

/// Bottom line: the TUI's status (dim), or the active prompt.
struct StatusLine: View {
    @Environment(AppModel.self) private var model
    @Environment(PanelState.self) private var state
    let snapshot: Bool
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            if let prompt = state.prompt {
                Text(prompt.label).bold().foregroundStyle(.primary)
                field(prompt)
                if let preview = state.duePreview {
                    Text(preview.text).foregroundStyle(preview.ok ? Color.secondary : TUI.overdue)
                }
            } else if state.mode == .confirm, let item = state.confirmDelete {
                Text("Delete “\(item.title)”? [y/N]").bold().foregroundStyle(.primary).truncationMode(.middle)
                Spacer(minLength: 0)
            } else {
                Text(model.statusLeft).truncationMode(.middle)
                Spacer(minLength: 12)
                Text(model.statusRight).truncationMode(.middle)
            }
        }
        .lineLimit(1)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Metrics.hPad)
        .frame(height: Metrics.statusHeight)
        .background(Color.primary.opacity(0.06))
    }

    @ViewBuilder private func field(_ prompt: PanelState.Prompt) -> some View {
        if snapshot {
            Text(prompt.text + "▏").foregroundStyle(.primary).frame(maxWidth: .infinity, alignment: .leading)
        } else {
            TextField("", text: Binding(get: { state.prompt?.text ?? "" }, set: { state.prompt?.text = $0 }))
                .textFieldStyle(.plain)
                .foregroundStyle(.primary)
                .focused($focused)
                .onSubmit { state.submitPrompt() }
                .id(prompt.id)
                .onAppear { DispatchQueue.main.async { focused = true } }
        }
    }
}

/// Offscreen render of the panel, for checking layout without a screen.
enum Snapshot {
    @MainActor
    static func write(model: AppModel, state: PanelState, size: CGSize, dark: Bool, to path: String) -> Bool {
        let view = PanelView(snapshot: true)
            .environment(model)
            .environment(state)
            .frame(width: size.width, height: size.height)
            .background(dark ? Color(white: 0.12) : Color(white: 0.97))
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }
}
