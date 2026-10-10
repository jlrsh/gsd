import Foundation

/// Pure checklist logic over a `StateDoc` plus the currently sourced items.
/// All mutation goes through here so every write is stamped consistently.
public struct Checklist: Sendable {
    public enum Placement: Sendable, Hashable { case main, completed }

    public static let completedCap = 500
    public static let markerDays = 400
    public static let tombstoneDays = 180

    public var doc: StateDoc
    /// Rows toggled since the last sweep stay where they were (UI-only).
    public var pinned: [String: Placement] = [:]

    public init(doc: StateDoc) { self.doc = doc }

    public var zone: TimeZone { doc.zone }

    // MARK: sourced items

    /// Everything currently sourced, first source wins, manual overrides.
    /// `feedItems` is ordered: calendar feeds, then Gradescope.
    public func live(_ feedItems: [[Item]]) -> [String: Item] {
        var live: [String: Item] = [:]
        for items in feedItems { for it in items where live[it.key] == nil { live[it.key] = it } }
        for (key, entry) in doc.manual where !entry.deleted {
            guard var it = entry.item?.item(zone: zone) else { continue }
            it.key = key
            it.manual = true
            live[key] = it
        }
        return live
    }

    public func manualItem(_ key: String) -> Item? {
        guard let e = doc.manual[key], !e.deleted, var it = e.item?.item(zone: zone) else { return nil }
        it.key = key
        it.manual = true
        return it
    }

    public var gradescopeRows: [Gradescope.Row] { doc.sources[StateDoc.gradescopeSource]?.rows ?? [] }

    /// Closed-and-submitted Gradescope keys, computed rather than written, so
    /// an explicit uncheck always wins.
    public var autoDone: Set<String> {
        doc.gradescopeEnabled ? Gradescope.autoCompleteKeys(gradescopeRows) : []
    }

    public func isDone(_ key: String, auto: Set<String>) -> Bool { doc.records[key]?.done ?? auto.contains(key) }

    // MARK: view

    public struct View: Sendable {
        public var main: [Item]
        public var completed: [Item]
        public var done: Set<String>
        public var mainSections: [ItemSection]
        public var completedSections: [ItemSection]
        public var openCount: Int
        public var overdueCount: Int
    }

    public func view(_ live: [String: Item], liveOrder: [String], now: Date) -> View {
        let auto = autoDone
        let zone = self.zone
        var done = Set<String>()
        var main: [Item] = []
        var completed: [(Item, Date)] = []
        let retention = doc.retentionDays
        let cutoff = now.addingTimeInterval(-Double(retention) * 86400)

        func completedStamp(_ key: String, _ item: Item) -> Date {
            if let s = doc.records[key]?.completedAt, let d = ISODate.parse(s)?.date(naiveZone: zone) { return d }
            return item.due ?? now  // auto-completed: the due moment is when it closed
        }
        func visible(_ stamp: Date) -> Bool { retention <= 0 || stamp >= cutoff }

        for key in liveOrder {
            guard let it = live[key] else { continue }
            let isDone = self.isDone(key, auto: auto)
            if isDone { done.insert(key) }
            switch pinned[key] ?? (isDone ? .completed : .main) {
            case .main: main.append(it)
            case .completed:
                let stamp = completedStamp(key, it)
                if pinned[key] != nil || visible(stamp) { completed.append((it, stamp)) }
            }
        }
        // Done items no source lists any more, shown from their snapshot.
        for (key, rec) in doc.records where live[key] == nil {
            guard let snap = rec.snap, var it = snap.item(zone: zone) else { continue }
            it.key = key
            if rec.done { done.insert(key) }
            guard (pinned[key] ?? (rec.done ? .completed : nil)) == .completed else { continue }
            let stamp = completedStamp(key, it)
            if pinned[key] != nil || visible(stamp) { completed.append((it, stamp)) }
        }
        if completed.count > Checklist.completedCap {
            completed = Array(completed.sorted { $0.1 > $1.1 }.prefix(Checklist.completedCap))
        }
        let completedItems = completed.map(\.0).stableSorted(by: Item.sortLess)
        let sortedMain = main.stableSorted(by: Item.sortLess)
        let open = sortedMain.filter { !done.contains($0.key) }
        return View(main: sortedMain, completed: completedItems, done: done,
                    mainSections: Rows.mainSections(sortedMain, now: now, zone: zone),
                    completedSections: Rows.completedSections(completedItems, now: now, zone: zone),
                    openCount: open.count,
                    overdueCount: open.filter { $0.isOverdue(now: now, zone: zone) }.count)
    }

    // MARK: mutation

    /// Check or uncheck; the row stays put until the next sweep.
    public mutating func toggle(_ item: Item, live: [String: Item], now: Date) {
        let auto = autoDone
        let wasDone = isDone(item.key, auto: auto)
        if pinned[item.key] == nil { pinned[item.key] = wasDone ? .completed : .main }
        let prior = doc.records[item.key]
        let source = live[item.key] ?? item
        var rec = Record(done: !wasDone, at: doc.stamp(after: prior?.at, now: now), by: doc.device.id,
                         completedAt: prior?.completedAt, src: prior?.src ?? sourceID(source),
                         due: source.due.map { Clock.iso($0, zone) }, snap: Snapshot(source, zone: zone))
        if rec.done { rec.completedAt = Clock.iso(now, zone) }
        doc.records[item.key] = rec
    }

    func sourceID(_ item: Item) -> String {
        if item.manual { return "manual" }
        if item.source == "Gradescope" { return StateDoc.gradescopeSource }
        if let feed = doc.feeds.first(where: { !$0.value.deleted && $0.value.name == item.source }) { return feed.key }
        return item.source
    }

    /// File checked rows under Completed and bring unchecked ones back; an
    /// unchecked Completed item no source lists becomes a manual item.
    public mutating func sweep(live: [String: Item], now: Date) {
        for (key, placement) in pinned where placement == .completed {
            guard let rec = doc.records[key], !rec.done, live[key] == nil, doc.manual[key]?.deleted != false,
                  var snap = rec.snap else { continue }
            snap.manual = true
            doc.manual[key] = ManualEntry(at: doc.stamp(after: doc.manual[key]?.at, now: now), by: doc.device.id,
                                          deleted: false, item: snap)
        }
        pinned.removeAll()
        // Imported "checked" keys have no snapshot until their item shows up.
        for (key, rec) in Array(doc.records) where rec.done && rec.snap == nil {
            guard let it = live[key] else { continue }
            var r = rec
            r.snap = Snapshot(it, zone: zone)
            r.due = it.due.map { Clock.iso($0, zone) }
            doc.records[key] = r
        }
        prune(live: live, now: now)
    }

    /// Retention: past `retentionDays` a completed item's snapshot is dropped
    /// but a marker stays, so an old item never resurfaces as overdue.
    public mutating func prune(live: [String: Item], now: Date) {
        let retention = doc.retentionDays
        let day = 86400.0
        for (key, rec) in Array(doc.records) {
            let stamp = rec.completedAt.flatMap { ISODate.parse($0)?.date(naiveZone: zone) } ?? Clock.date(ms: rec.at)
            let age = now.timeIntervalSince(stamp) / day
            if rec.done {
                if retention > 0, age > Double(retention), rec.snap != nil, pinned[key] == nil {
                    doc.records[key]?.snap = nil
                }
                if live[key] == nil, age > Double(Checklist.markerDays) { doc.records[key] = nil }
            } else if live[key] == nil, pinned[key] == nil,
                      now.timeIntervalSince(Clock.date(ms: rec.at)) / day > Double(Checklist.tombstoneDays) {
                doc.records[key] = nil
            }
        }
        let tombstoneCutoff = Clock.ms(now) - Int64(Checklist.tombstoneDays) * 86_400_000
        doc.manual = doc.manual.filter { !$0.value.deleted || $0.value.at > tombstoneCutoff }
        doc.feeds = doc.feeds.filter { !$0.value.deleted || $0.value.at > tombstoneCutoff }
    }

    // MARK: manual items

    @discardableResult
    public mutating func addManual(title: String, due: Date?, allDay: Bool, now: Date) -> String {
        let key = Keys.manual()
        let item = Item(key: key, title: GSDText.clean(title), due: due, allDay: allDay, source: "manual", manual: true)
        doc.manual[key] = ManualEntry(at: doc.stamp(after: nil, now: now), by: doc.device.id, deleted: false,
                                      item: Snapshot(item, zone: zone))
        return key
    }

    public mutating func editManual(_ key: String, title: String, due: Date?, allDay: Bool, now: Date) {
        guard var entry = doc.manual[key], !entry.deleted, var snap = entry.item else { return }
        snap.title = GSDText.clean(title)
        snap.due = due.map { Clock.iso($0, zone) }
        snap.allDay = allDay
        entry.item = snap
        entry.at = doc.stamp(after: entry.at, now: now)
        entry.by = doc.device.id
        doc.manual[key] = entry
        if var rec = doc.records[key], rec.snap != nil {
            rec.snap = snap
            doc.records[key] = rec
        }
    }

    public mutating func deleteManual(_ key: String, now: Date) {
        guard let entry = doc.manual[key] else { return }
        doc.manual[key] = ManualEntry(at: doc.stamp(after: entry.at, now: now), by: doc.device.id, deleted: true, item: nil)
        if let rec = doc.records[key] {
            doc.records[key] = Record(done: false, at: doc.stamp(after: rec.at, now: now), by: doc.device.id)
        }
        pinned[key] = nil
    }

    // MARK: feeds

    @discardableResult
    public mutating func addFeed(url: String, name: String?, now: Date) -> String {
        let u = Py.strip(url)
        let id = Keys.feed(url: u)
        let n = Py.strip(name ?? "")
        doc.feeds[id] = FeedEntry(at: doc.stamp(after: doc.feeds[id]?.at, now: now), by: doc.device.id, deleted: false,
                                  url: u, name: n.isEmpty ? FeedFetcher.defaultName(u) : n, enabled: true)
        return id
    }

    public mutating func updateFeed(_ id: String, now: Date, _ change: (inout FeedEntry) -> Void) {
        guard var f = doc.feeds[id] else { return }
        change(&f)
        f.at = doc.stamp(after: f.at, now: now)
        f.by = doc.device.id
        doc.feeds[id] = f
    }

    public mutating func deleteFeed(_ id: String, now: Date) {
        updateFeed(id, now: now) { $0.deleted = true }
        doc.sources[id] = nil
    }
}
