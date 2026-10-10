import Foundation

/// A display row, as `gsd.models.Row` / `gsd.events.build_rows`.
public struct Row: Hashable, Sendable {
    public enum Kind: String, Sendable { case item, header, blank, rule }
    public enum Style: String, Sendable { case none = "", section, day, overdue }
    public var kind: Kind
    public var text: String = ""
    public var item: Item?
    public var style: Style = .none
}

/// A titled group of items, the unit the native list renders.
public struct ItemSection: Hashable, Sendable, Identifiable {
    public var title: String
    public var style: Row.Style
    public var items: [Item]
    public var id: String { title }
}

public enum Rows {
    static let dayFormatter = formatter("EEE MMM d")
    static let dayYearFormatter = formatter("EEE MMM d, yyyy")

    static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .utc
        f.dateFormat = format
        return f
    }

    /// Format a calendar day (zone-free: rendered at UTC midnight).
    static func format(_ d: Day, _ f: DateFormatter) -> String {
        f.string(from: Date(timeIntervalSince1970: TimeInterval(d.ordinal * 86400)))
    }

    public static func dayLabel(_ d: Day, today: Day) -> String {
        let delta = d.ordinal - today.ordinal
        if delta == 0 { return "Today · " + format(d, dayFormatter) }
        if delta == 1 { return "Tomorrow · " + format(d, dayFormatter) }
        if d.year != today.year { return format(d, dayYearFormatter) }
        return format(d, dayFormatter)
    }

    /// "MM/dd" of the due day, shown in place of the time once overdue.
    public static func shortDate(_ date: Date, _ zone: TimeZone) -> String {
        let d = Clock.day(date, zone)
        return String(format: "%02d/%02d", d.month, d.day)
    }

    /// Group dated items by local day, each day sorted.
    static func groupByDay(_ items: [Item], _ zone: TimeZone) -> [(Day, [Item])] {
        var buckets: [Day: [Item]] = [:]
        var order: [Day] = []
        for it in items {
            guard let d = it.day(zone) else { continue }
            if buckets[d] == nil { order.append(d) }
            buckets[d, default: []].append(it)
        }
        return order.sorted().map { ($0, buckets[$0]!.stableSorted(by: Item.sortLess)) }
    }

    /// Main list sections: Overdue, one per upcoming day, No date.
    public static func mainSections(_ main: [Item], now: Date, zone: TimeZone) -> [ItemSection] {
        let today = Clock.day(now, zone)
        let overdue = main.filter { $0.due != nil && $0.isOverdue(now: now, zone: zone) }
        let upcoming = main.filter { $0.due != nil && !$0.isOverdue(now: now, zone: zone) }
        let undated = main.filter { $0.due == nil }
        var blocks: [ItemSection] = []
        if !overdue.isEmpty {
            blocks.append(ItemSection(title: "Overdue", style: .overdue, items: overdue.stableSorted(by: Item.sortLess)))
        }
        for (day, items) in groupByDay(upcoming, zone) {
            blocks.append(ItemSection(title: dayLabel(day, today: today), style: .day, items: items))
        }
        if !undated.isEmpty {
            blocks.append(ItemSection(title: "No date", style: .day,
                                      items: undated.stableSorted { Py.less(Py.lower($0.title), Py.lower($1.title)) }))
        }
        return blocks
    }

    /// Completed sections: one per due day, then No date.
    public static func completedSections(_ completed: [Item], now: Date, zone: TimeZone) -> [ItemSection] {
        let today = Clock.day(now, zone)
        var out = groupByDay(completed, zone).map {
            ItemSection(title: dayLabel($0.0, today: today), style: .day, items: $0.1)
        }
        let undated = completed.filter { $0.due == nil }
        if !undated.isEmpty { out.append(ItemSection(title: "No date", style: .day, items: undated)) }
        return out
    }

    /// `build_rows`: (rows, main_start).
    public static func build(completed: [Item], main: [Item], now: Date, zone: TimeZone) -> ([Row], Int) {
        var rows: [Row] = []
        if !completed.isEmpty {
            rows.append(Row(kind: .header, text: "Completed", style: .section))
            for s in completedSections(completed, now: now, zone: zone) {
                rows.append(Row(kind: .blank))
                rows.append(Row(kind: .header, text: s.title, style: .day))
                rows += s.items.map { Row(kind: .item, item: $0) }
            }
            rows += [Row(kind: .blank), Row(kind: .rule), Row(kind: .blank)]
        }
        let mainStart = rows.count
        let blocks = mainSections(main, now: now, zone: zone)
        for (i, b) in blocks.enumerated() {
            if i > 0 { rows.append(Row(kind: .blank)) }
            rows.append(Row(kind: .header, text: b.title, style: b.style))
            rows += b.items.map { Row(kind: .item, item: $0) }
        }
        if blocks.isEmpty { rows.append(Row(kind: .header, text: "Nothing due", style: .day)) }
        return (rows, mainStart)
    }

    /// `gsd --list` output for the main list.
    public static func plainDump(completed: [Item], main: [Item], now: Date, zone: TimeZone) -> String {
        let (rows, start) = build(completed: completed, main: main, now: now, zone: zone)
        var lines: [String] = []
        for row in rows[start...] {
            switch row.kind {
            case .blank: lines.append("")
            case .header: lines.append(row.text)
            case .rule: continue
            case .item:
                let clock = row.item!.timeLabel(zone)
                lines.append("[ ] " + String(repeating: " ", count: max(0, 5 - clock.count)) + clock + "  " + row.item!.title)
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
