import Foundation
import XCTest
@testable import GSDCore

final class StateTests: XCTestCase {
    let zone = TimeZone(identifier: "America/Indiana/Indianapolis")!
    let t0 = ISODate.parse("2026-09-24T10:00:00-04:00")!.date(naiveZone: .utc)

    func freshDoc() -> StateDoc {
        var d = StateDoc(device: DeviceInfo(id: "DEV-A", name: "test", platform: "test", wrote: 0))
        d.settings[SettingKey.timezone] = Setting(v: .string(zone.identifier), at: 1, by: "t")
        return d
    }

    func item(_ key: String, _ title: String, dueIn hours: Double, source: String = "Canvas") -> Item {
        Item(key: key, title: title, due: t0.addingTimeInterval(hours * 3600), allDay: false, source: source)
    }

    func liveOf(_ items: [Item], _ c: Checklist) -> ([String: Item], [String]) {
        (c.live([items]), items.map(\.key))
    }

    func testCheckStaysInPlaceUntilSweep() {
        var c = Checklist(doc: freshDoc())
        let a = item("a", "Alpha", dueIn: 5), b = item("b", "Beta", dueIn: 30)
        let (live, order) = liveOf([a, b], c)
        c.toggle(a, live: live, now: t0)
        var v = c.view(live, liveOrder: order, now: t0)
        XCTAssertEqual(v.main.map(\.key), ["a", "b"], "checked row stays in main until sweep")
        XCTAssertTrue(v.done.contains("a"))
        XCTAssertEqual(v.openCount, 1)
        c.sweep(live: live, now: t0)
        v = c.view(live, liveOrder: order, now: t0)
        XCTAssertEqual(v.main.map(\.key), ["b"])
        XCTAssertEqual(v.completed.map(\.key), ["a"])
        // Uncheck from Completed: stays there until the next sweep.
        c.toggle(a, live: live, now: t0.addingTimeInterval(60))
        v = c.view(live, liveOrder: order, now: t0)
        XCTAssertEqual(v.completed.map(\.key), ["a"])
        XCTAssertFalse(v.done.contains("a"))
        c.sweep(live: live, now: t0)
        v = c.view(live, liveOrder: order, now: t0)
        XCTAssertEqual(v.main.map(\.key), ["a", "b"])
        XCTAssertTrue(v.completed.isEmpty)
    }

    func testStampsAreMonotonic() {
        var c = Checklist(doc: freshDoc())
        let a = item("a", "Alpha", dueIn: 5)
        let (live, _) = liveOf([a], c)
        c.toggle(a, live: live, now: t0)
        let first = c.doc.records["a"]!.at
        c.toggle(a, live: live, now: t0.addingTimeInterval(-100))  // clock went backwards
        XCTAssertEqual(c.doc.records["a"]!.at, first + 1)
    }

    func gradescopeDoc(_ status: String) -> StateDoc {
        var d = freshDoc()
        d.settings[SettingKey.gradescopeEnabled] = Setting(v: .bool(true), at: 1, by: "t")
        d.sources[StateDoc.gradescopeSource] = SourceSnapshot(fetchedAt: 1, error: nil, rows: [
            Gradescope.Row(key: "a1", title: "HW1", dueISO: "2026-09-22T23:59:00-04:00", status: status,
                           course: "CS 101", courseID: "1", url: "https://www.gradescope.com/x"),
        ])
        return d
    }

    func testGradescopeAutoCompleteIsComputedAndUncheckWins() {
        var c = Checklist(doc: gradescopeDoc("Submissions Closed — 90 / 100"))
        let items = Gradescope.items(c.gradescopeRows, zone: zone)
        let live = c.live([items]), order = items.map(\.key)
        var v = c.view(live, liveOrder: order, now: t0)
        XCTAssertEqual(v.completed.map(\.key), order, "closed + submitted is auto-completed")
        XCTAssertTrue(c.doc.records.isEmpty, "auto-complete writes nothing")
        c.toggle(items[0], live: live, now: t0)
        c.sweep(live: live, now: t0)
        v = c.view(live, liveOrder: order, now: t0)
        XCTAssertEqual(v.main.map(\.key), order, "an uncheck is never fought")
        XCTAssertEqual(c.doc.records[order[0]]?.done, false)

        let missed = Checklist(doc: gradescopeDoc("Submissions Closed — No Submission"))
        XCTAssertTrue(missed.autoDone.isEmpty, "a missed assignment stays visible")
    }

    func testOrphanUncheckedFromCompletedBecomesManual() {
        var c = Checklist(doc: freshDoc())
        let a = item("a", "Gone soon", dueIn: -2)
        var (live, order) = liveOf([a], c)
        c.toggle(a, live: live, now: t0)
        c.sweep(live: live, now: t0)
        // The feed drops the item; it's still shown under Completed from its snapshot.
        (live, order) = liveOf([], c)
        var v = c.view(live, liveOrder: order, now: t0)
        XCTAssertEqual(v.completed.map(\.key), ["a"])
        c.toggle(v.completed[0], live: live, now: t0)
        c.sweep(live: c.live([]), now: t0)
        XCTAssertNotNil(c.doc.manual["a"])
        live = c.live([])
        v = c.view(live, liveOrder: ["a"], now: t0)
        XCTAssertEqual(v.main.map(\.key), ["a"])
        XCTAssertEqual(v.main.first?.title, "Gone soon")
        XCTAssertEqual(v.main.first?.source, "Canvas")
    }

    func testRetentionHidesButNeverResurfacesAsOverdue() {
        var c = Checklist(doc: freshDoc())
        let old = item("old", "Old thing", dueIn: -24 * 60)
        let (live, order) = liveOf([old], c)
        c.toggle(old, live: live, now: t0.addingTimeInterval(-40 * 86400))
        c.sweep(live: live, now: t0.addingTimeInterval(-40 * 86400))
        var v = c.view(live, liveOrder: order, now: t0)
        XCTAssertTrue(v.completed.isEmpty, "past retention: hidden from Completed")
        XCTAssertTrue(v.main.isEmpty, "…and not back under Overdue (the Python bug)")
        c.prune(live: live, now: t0)
        XCTAssertNil(c.doc.records["old"]?.snap)
        XCTAssertEqual(c.doc.records["old"]?.done, true, "marker kept")
        v = c.view(live, liveOrder: order, now: t0)
        XCTAssertTrue(v.main.isEmpty)
        c.prune(live: [:], now: t0.addingTimeInterval(401 * 86400))
        XCTAssertNil(c.doc.records["old"], "marker GC once unlisted and >400 days")
    }

    func testManualLifecycle() {
        var c = Checklist(doc: freshDoc())
        let (due, allDay) = ParseWhen.parse("fri 5pm", now: t0, zone: zone)!
        let key = c.addManual(title: "Write\treport", due: due, allDay: allDay, now: t0)
        var v = c.view(c.live([]), liveOrder: [key], now: t0)
        XCTAssertEqual(v.main.first?.title, "Write report")
        XCTAssertEqual(v.main.first?.timeLabel(zone), "17:00")
        XCTAssertEqual(v.mainSections.first?.title, "Tomorrow · Fri Sep 25")
        c.editManual(key, title: "Write the report", due: nil, allDay: true, now: t0)
        v = c.view(c.live([]), liveOrder: [key], now: t0)
        XCTAssertEqual(v.mainSections.first?.title, "No date")
        c.toggle(v.main[0], live: c.live([]), now: t0)
        c.deleteManual(key, now: t0)
        v = c.view(c.live([]), liveOrder: [key], now: t0)
        XCTAssertTrue(v.main.isEmpty && v.completed.isEmpty)
        XCTAssertEqual(c.doc.manual[key]?.deleted, true)
    }

    func testStateRoundTrip() throws {
        var c = Checklist(doc: freshDoc())
        c.addFeed(url: "webcal://x.test/a.ics", name: nil, now: t0)
        c.doc.set(SettingKey.horizonDays, .int(42), now: t0)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LocalStore(directory: dir)
        try store.save(c.doc)
        let back = store.load(deviceName: "x", platform: "y")
        var expected = c.doc
        expected.device.wrote = back.device.wrote
        XCTAssertEqual(back, expected)
        XCTAssertEqual(back.horizonDays, 42)
        XCTAssertEqual(back.activeFeeds.first?.feed.name, "x")
    }

    func testTOML() {
        let doc = TOML.parse("""
        # comment
        [settings]
        horizon_days   = 120   # trailing
        timezone = "America/New_York" # c
        [[feed]]
        url  = "https://a.test/x.ics?a=1#frag"
        name = 'Lit "quoted"'
        [[feed]]
        url = "https://b.test/y.ics"
        enabled = false
        [plugins.gradescope]
        enabled = true
        email = "me@x.edu"
        """)
        XCTAssertEqual(doc.tables["settings"]?["horizon_days"], .int(120))
        XCTAssertEqual(doc.tables["settings"]?["timezone"], .string("America/New_York"))
        XCTAssertEqual(doc.arrays["feed"]?.count, 2)
        XCTAssertEqual(doc.arrays["feed"]?[0]["url"], .string("https://a.test/x.ics?a=1#frag"))
        XCTAssertEqual(doc.arrays["feed"]?[0]["name"], .string("Lit \"quoted\""))
        XCTAssertEqual(doc.arrays["feed"]?[1]["enabled"], .bool(false))
        XCTAssertEqual(doc.tables["plugins.gradescope"]?["email"], .string("me@x.edu"))
    }

    func testImportRealTerminalState() throws {
        let dir = GoldenTests.fixtures.appendingPathComponent("private")
        guard let config = try? String(contentsOf: dir.appendingPathComponent("config.toml"), encoding: .utf8),
              let state = try? Data(contentsOf: dir.appendingPathComponent("state.json")) else {
            throw XCTSkip("no private state fixtures")
        }
        var doc = freshDoc()
        doc.settings = [:]
        var s = PythonImport.Summary()
        PythonImport.importConfig(config, into: &doc, summary: &s)
        try PythonImport.importState(state, into: &doc, summary: &s)
        let root = try JSONSerialization.jsonObject(with: state) as! [String: Any]
        XCTAssertEqual(s.completed, (root["completed"] as! [String: Any]).count)
        XCTAssertEqual(doc.records.values.filter(\.done).count,
                       Set((root["checked"] as! [String]) + (root["completed"] as! [String: Any]).keys).count)
        XCTAssertTrue(doc.gradescopeEnabled)
        XCTAssertFalse(doc.feeds.isEmpty)
        // Feed ids line up with the Python cache file names.
        for (id, _) in doc.feeds where doc.feeds[id]!.enabled {
            let name = id.replacingOccurrences(of: "ics:", with: "") + ".ics"
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path), name)
        }
        // Idempotent.
        let once = doc
        var s2 = PythonImport.Summary()
        PythonImport.importConfig(config, into: &doc, summary: &s2)
        try PythonImport.importState(state, into: &doc, summary: &s2)
        XCTAssertEqual(doc, once)
        XCTAssertEqual(s2.description, "nothing new")
        print("import:", s.description)
    }
}
