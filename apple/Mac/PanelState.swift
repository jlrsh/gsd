import AppKit
import Carbon.HIToolbox
import GSDCore
import Observation

/// Panel geometry.  Rows have a fixed height, so the viewport is the TUI's
/// row arithmetic rather than a scroll view.
enum Metrics {
    static let fontSize: CGFloat = 13
    static let rowHeight: CGFloat = 19
    static let titleHeight: CGFloat = 30
    static let statusHeight: CGFloat = 28
    static let hPad: CGFloat = 14

    static func bodyRows(height: CGFloat) -> Int {
        max(1, Int((height - titleHeight - statusHeight - 4) / rowHeight))
    }
}

/// What the panel shows and where the cursor is.  All key handling lives
/// here, ported from `gsd/ui.py` (`move`, `ensure_visible`, `clamp`, prompts).
@MainActor @Observable
final class PanelState {
    enum Mode: Equatable { case list, help, sources, prompt, confirm }

    struct Prompt: Equatable {
        enum Step: Equatable {
            case addTitle
            case addDue(title: String)
            case editTitle(key: String)
            case editDue(key: String, title: String)
            case timezone
        }
        var step: Step
        var label: String
        var text: String
        var id = UUID()
    }

    struct Layout {
        var rows: [Row]
        var mainStart: Int
    }

    struct Source: Identifiable {
        var id: String
        var label: String
        var enabled: Bool
    }

    let model: AppModel
    var mode: Mode = .list
    var prompt: Prompt?
    var confirmDelete: Item?
    /// The cursor follows an item, not a row number, across rebuilds.
    private(set) var cursorKey: String?
    private(set) var cursorHint = 0
    var scroll = 0
    var bodyRows = 20
    var sourceCursor = 0
    var shortcut = ""
    var statePath = ""
    @ObservationIgnored private var wheelAccum: CGFloat = 0

    @ObservationIgnored var hide: @MainActor () -> Void = {}
    @ObservationIgnored var openSettings: @MainActor () -> Void = {}
    @ObservationIgnored var quit: @MainActor () -> Void = {}

    init(model: AppModel) { self.model = model }

    var layout: Layout {
        let v = model.view
        let (rows, start) = Rows.build(completed: v.completed, main: v.main, now: model.now, zone: model.zone)
        return Layout(rows: rows, mainStart: start)
    }

    // MARK: cursor and viewport

    static func itemRows(_ rows: [Row]) -> [Int] { rows.indices.filter { rows[$0].kind == .item } }

    /// The nearest item row from `start` in `direction` (`snap_to_item`).
    static func snap(_ rows: [Row], from start: Int, _ direction: Int) -> Int? {
        var i = max(0, min(start, rows.count - 1))
        while rows.indices.contains(i) {
            if rows[i].kind == .item { return i }
            i += direction
        }
        return nil
    }

    /// `ensure_visible` then `clamp`: the first row to draw.  Completed stays
    /// above the fold: `max_scroll` never drops below `main_start`.
    static func viewport(rows: [Row], mainStart: Int, cursor: Int?, scroll: Int, body: Int) -> Int {
        var s = scroll
        if let c = cursor {
            if c < s {
                s = c
                // Pull the day header (and its blank line) along for context.
                var back = 0
                while back < 2, s > 0, rows[s - 1].kind == .header || rows[s - 1].kind == .blank {
                    s -= 1
                    back += 1
                }
                // Nothing selectable above: show the very top, banner included.
                if !rows[..<s].contains(where: { $0.kind == .item }) { s = 0 }
            } else if c >= s + body {
                s = c - body + 1
            }
        }
        let maxScroll = max(mainStart, rows.count - body)
        return max(0, min(s, maxScroll))
    }

    func cursorIndex(_ l: Layout) -> Int? {
        if let key = cursorKey, let i = l.rows.firstIndex(where: { $0.item?.key == key }) { return i }
        return Self.snap(l.rows, from: cursorHint, +1) ?? Self.snap(l.rows, from: cursorHint, -1)
    }

    var currentItem: Item? {
        let l = layout
        return cursorIndex(l).flatMap { l.rows[$0].item }
    }

    private func setCursor(_ i: Int, _ l: Layout) {
        cursorKey = l.rows[i].item?.key
        cursorHint = i
        scroll = Self.viewport(rows: l.rows, mainStart: l.mainStart, cursor: i, scroll: scroll, body: bodyRows)
    }

    func select(_ key: String) {
        let l = layout
        if let i = l.rows.firstIndex(where: { $0.item?.key == key }) { setCursor(i, l) }
    }

    /// Fresh summon: list mode, cursor on the first main-list item.
    func reset() {
        mode = .list
        prompt = nil
        confirmDelete = nil
        sourceCursor = 0
        wheelAccum = 0
        let l = layout
        scroll = l.mainStart
        if let i = Self.snap(l.rows, from: l.mainStart, +1) ?? Self.snap(l.rows, from: l.mainStart, -1) {
            setCursor(i, l)
        } else {
            cursorKey = nil
            cursorHint = l.mainStart
        }
    }

    func move(_ delta: Int) {
        let l = layout
        let c = cursorIndex(l) ?? l.mainStart
        let items = Self.itemRows(l.rows)
        if let t = delta > 0 ? items.first(where: { $0 > c }) : items.last(where: { $0 < c }) { setCursor(t, l) }
    }

    func jump(first: Bool) {
        let l = layout
        let items = Self.itemRows(l.rows)
        if let t = first ? items.first : items.last { setCursor(t, l) }
    }

    /// Half a screen of *items*; the viewport follows the cursor.
    func page(_ direction: Int) {
        let l = layout
        let items = Self.itemRows(l.rows)
        guard let c = cursorIndex(l), let pos = items.firstIndex(of: c) else { return }
        let target = max(0, min(items.count - 1, pos + direction * max(1, bodyRows / 2)))
        setCursor(items[target], l)
    }

    /// Mouse wheel: scroll by rows, dragging the cursor along when it leaves the view.
    func wheel(_ deltaY: CGFloat, precise: Bool) {
        guard mode == .list else { return }
        wheelAccum += precise ? deltaY / Metrics.rowHeight : deltaY
        let steps = Int(wheelAccum.rounded(.towardZero))  // positive: toward the top
        guard steps != 0 else { return }
        wheelAccum -= CGFloat(steps)
        let l = layout
        let cursor = cursorIndex(l)
        let current = Self.viewport(rows: l.rows, mainStart: l.mainStart, cursor: cursor, scroll: scroll, body: bodyRows)
        scroll = max(0, min(max(l.mainStart, l.rows.count - bodyRows), current - steps))
        if let c = cursor, c < scroll || c >= scroll + bodyRows {
            let visible = Self.itemRows(l.rows).filter { $0 >= scroll && $0 < scroll + bodyRows }
            if let t = c < scroll ? visible.first : visible.last {
                cursorKey = l.rows[t].item?.key
                cursorHint = t
            }
        }
    }

    // MARK: actions

    func toggleCurrent() {
        if let item = currentItem { model.toggle(item) }
    }

    func toggle(_ item: Item) {
        select(item.key)
        model.toggle(item)
    }

    func open(_ item: Item?) {
        guard let item else { return }
        guard let link = item.link, let url = URL(string: link) else {
            model.notify("no link on this event")
            return
        }
        NSWorkspace.shared.open(url)
        model.notify("opening link…", seconds: 1.5)
    }

    func copyLink() {
        guard let link = currentItem?.link else {
            model.notify("no link on this event")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
        model.notify("link copied", seconds: 1.5)
    }

    func refresh() {
        guard !model.doc.activeFeeds.isEmpty || model.doc.gradescopeEnabled else {
            model.notify("no sources configured — ⌘, for Settings")
            return
        }
        model.notify("refreshing…", seconds: 1.5)
        Task {
            await model.syncAndWait()
            model.refresh(force: true)
        }
    }

    // MARK: prompts

    func beginAdd() { startPrompt(.addTitle, "Title:", "") }

    func beginEdit() {
        guard let item = currentItem else { return }
        guard item.manual else { return model.notify("only manual items can be edited") }
        startPrompt(.editTitle(key: item.key), "Title:", item.title)
    }

    func beginDelete() {
        guard let item = currentItem else { return }
        guard item.manual else { return model.notify("only manual items can be deleted") }
        confirmDelete = item
        mode = .confirm
    }

    private func startPrompt(_ step: Prompt.Step, _ label: String, _ text: String) {
        prompt = Prompt(step: step, label: label, text: text)
        mode = .prompt
    }

    func cancelPrompt() {
        let back: Mode = prompt?.step == .timezone ? .sources : .list
        prompt = nil
        mode = back
    }

    func submitPrompt() {
        guard let p = prompt else { return }
        let text = p.text.trimmed
        switch p.step {
        case .addTitle:
            guard !text.isEmpty else { return cancelPrompt() }
            startPrompt(.addDue(title: text), "Due:", "")
        case .addDue(let title):
            guard let due = resolveDue(p.text) else { return model.notify("could not read that date — try 'fri' or 2026-09-12") }
            let key = model.addManual(title: title, due: due.0, allDay: due.1)
            prompt = nil
            mode = .list
            select(key)
        case .editTitle(let key):
            guard !text.isEmpty, let item = model.manualItem(key) else { return cancelPrompt() }
            startPrompt(.editDue(key: key, title: text), "Due:", dueText(item))
        case .editDue(let key, let title):
            guard let due = resolveDue(p.text) else { return model.notify("could not read that date — try 'fri' or 2026-09-12") }
            model.editManual(key, title: title, due: due.0, allDay: due.1)
            prompt = nil
            mode = .list
            select(key)
        case .timezone:
            if text.isEmpty || text.lowercased() == "auto" {
                model.set(SettingKey.timezone, .string("auto"))
            } else if ICS.ianaZone(text) != nil {
                model.set(SettingKey.timezone, .string(text))
            } else {
                return model.notify("unknown IANA timezone: \(text)", seconds: 5)
            }
            prompt = nil
            mode = .sources
        }
    }

    /// `parse_when`, plus "none" for an undated item.
    func resolveDue(_ text: String) -> (Date?, Bool)? {
        if ["none", "no date", "-", "never"].contains(text.trimmed.lowercased()) { return (nil, true) }
        return ParseWhen.parse(text, now: model.now, zone: model.zone).map { ($0.0, $0.1) }
    }

    /// What the due prompt would save, shown beside it as you type.
    var duePreview: (text: String, ok: Bool)? {
        guard let p = prompt else { return nil }
        switch p.step {
        case .addDue, .editDue: break
        default: return nil
        }
        guard let resolved = resolveDue(p.text) else { return ("can't read that — try fri 5pm, +3, 9/12, none", false) }
        guard let due = resolved.0 else { return ("no date", true) }
        let label = Rows.dayLabel(Clock.day(due, model.zone), today: Clock.day(model.now, model.zone))
        if resolved.1 { return (label, true) }
        return (label + " · " + Item(key: "", title: "", due: due, allDay: false).timeLabel(model.zone), true)
    }

    /// A due date as text `parse_when` reads back.
    func dueText(_ item: Item) -> String {
        guard let due = item.due else { return "none" }
        let w = WallTime(instant: due, zone: model.zone)
        return item.allDay ? w.day.iso : w.day.iso + String(format: " %02d:%02d", w.hour, w.minute)
    }

    // MARK: sources screen

    var sources: [Source] {
        [Source(id: StateDoc.gradescopeSource, label: "Gradescope", enabled: model.doc.gradescopeEnabled)]
            + model.doc.activeFeeds.map { Source(id: $0.id, label: "Calendar · \($0.feed.name)", enabled: $0.feed.enabled) }
    }

    func toggleSource() {
        let all = sources
        guard all.indices.contains(sourceCursor) else { return }
        let s = all[sourceCursor]
        if s.id == StateDoc.gradescopeSource {
            model.set(SettingKey.gradescopeEnabled, .bool(!s.enabled))
            if !s.enabled { model.refresh(only: [s.id]) }
        } else {
            model.setFeedEnabled(s.id, !s.enabled)
        }
    }

    // MARK: keys

    static let help: [(keys: String, what: String)] = [
        ("j / k, ↓ / ↑", "move between assignments"),
        ("g / G", "jump to first / last"),
        ("⌃d / ⌃u", "half a screen down / up"),
        ("space", "check or uncheck"),
        ("enter / o", "open the event's link"),
        ("y", "copy the event's link"),
        ("a", "add an assignment by hand"),
        ("e / d", "edit / delete a manual assignment"),
        ("r", "sync and refresh all sources"),
        ("c", "enable or disable sources"),
        ("?", "this help"),
        ("⌘,", "settings"),
        ("q / esc", "hide, filing checked items under Completed"),
        ("⌘Q", "quit gsd"),
    ]

    /// A key press.  Returns false to let the event through (menu shortcuts,
    /// typing into the prompt's text field).
    @discardableResult
    func key(_ chars: String, code: Int, flags: NSEvent.ModifierFlags) -> Bool {
        let flags = flags.intersection([.command, .control, .option, .shift])
        if flags.contains(.command) {
            switch chars.lowercased() {
            case "q": quit()
            case ",": openSettings()
            case "w": hide()
            case "r": if mode == .list { refresh() }
            default: return false
            }
            return true
        }
        let esc = code == kVK_Escape || chars == "\u{1b}"
        let enter = code == kVK_Return || code == kVK_ANSI_KeypadEnter || chars == "\r"
        switch mode {
        case .prompt:
            if esc { cancelPrompt(); return true }
            return false
        case .confirm:
            if chars.lowercased() == "y", let item = confirmDelete { model.deleteManual(item.key) }
            confirmDelete = nil
            mode = .list
            return true
        case .help:
            mode = .list
            return true
        case .sources:
            sourcesKey(chars, code: code, esc: esc, enter: enter)
            return true
        case .list:
            listKey(chars, code: code, control: flags.contains(.control), esc: esc, enter: enter)
            return true
        }
    }

    private func listKey(_ chars: String, code: Int, control: Bool, esc: Bool, enter: Bool) {
        if esc { return hide() }
        if control {
            switch chars {
            case "d": page(+1)
            case "u": page(-1)
            case "n": move(+1)
            case "p": move(-1)
            default: break
            }
            return
        }
        switch code {
        case kVK_DownArrow: return move(+1)
        case kVK_UpArrow: return move(-1)
        case kVK_Home: return jump(first: true)
        case kVK_End: return jump(first: false)
        case kVK_PageDown: return page(+1)
        case kVK_PageUp: return page(-1)
        default: break
        }
        if enter { return open(currentItem) }
        switch chars {
        case "j", "J": move(+1)
        case "k", "K": move(-1)
        case "g": jump(first: true)
        case "G": jump(first: false)
        case " ": toggleCurrent()
        case "o": open(currentItem)
        case "y": copyLink()
        case "a": beginAdd()
        case "e": beginEdit()
        case "d": beginDelete()
        case "r": refresh()
        case "c":
            sourceCursor = 0
            mode = .sources
        case "?": mode = .help
        case "q", "Q": hide()
        default: break
        }
    }

    private func sourcesKey(_ chars: String, code: Int, esc: Bool, enter: Bool) {
        let count = sources.count
        if esc || enter || chars == "q" || chars == "c" {
            mode = .list
        } else if code == kVK_DownArrow || chars == "j" {
            sourceCursor = min(count - 1, sourceCursor + 1)
        } else if code == kVK_UpArrow || chars == "k" {
            sourceCursor = max(0, sourceCursor - 1)
        } else if chars == " " {
            toggleSource()
        } else if chars == "t" {
            startPrompt(.timezone, "Timezone (IANA name or auto):", model.doc.timezoneSetting)
        }
    }

    /// Line editing for the prompt when its text field doesn't have focus
    /// (and for `--keys` replay).
    func typeIntoPrompt(_ chars: String, code: Int, flags: NSEvent.ModifierFlags) {
        let flags = flags.intersection([.command, .control, .option])
        if code == kVK_Escape || chars == "\u{1b}" { return cancelPrompt() }
        if code == kVK_Return || code == kVK_ANSI_KeypadEnter || chars == "\r" { return submitPrompt() }
        if code == kVK_Delete || chars == "\u{7f}" { prompt?.text = String((prompt?.text ?? "").dropLast()); return }
        if flags == .control, chars == "u" { prompt?.text = ""; return }
        if flags == .command, chars == "v", let s = NSPasteboard.general.string(forType: .string) {
            prompt?.text += s.replacingOccurrences(of: "\n", with: " ")
            return
        }
        let printable = chars.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 && !(0xF700...0xF8FF).contains($0.value) }
        if flags.subtracting(.option).isEmpty, !chars.isEmpty, printable { prompt?.text += chars }
    }

    /// Drive the panel from a key script: plain characters, or `<down>`, `<up>`,
    /// `<cr>`, `<esc>`, `<space>`.  For headless checks.
    func replay(_ script: String) {
        var i = script.startIndex
        while i < script.endIndex {
            var chars = String(script[i])
            var code = -1
            var next = script.index(after: i)
            if script[i] == "<", let close = script[i...].firstIndex(of: ">") {
                let name = script[script.index(after: i)..<close]
                next = script.index(after: close)
                switch name {
                case "down": (chars, code) = ("", kVK_DownArrow)
                case "up": (chars, code) = ("", kVK_UpArrow)
                case "cr": (chars, code) = ("\r", kVK_Return)
                case "esc": (chars, code) = ("\u{1b}", kVK_Escape)
                case "space": chars = " "
                default: break
                }
            }
            if mode == .prompt {
                typeIntoPrompt(chars, code: code, flags: [])
            } else {
                key(chars, code: code, flags: [])
            }
            i = next
        }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
