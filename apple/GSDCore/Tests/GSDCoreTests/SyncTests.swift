import Foundation
import XCTest
@testable import GSDCore

final class SyncTests: XCTestCase {
    let t0 = ISODate.parse("2026-10-09T12:00:00-04:00")!.date(naiveZone: .utc)

    func doc(_ id: String) -> StateDoc {
        var d = StateDoc(device: DeviceInfo(id: id, name: id, platform: "test", wrote: 0))
        d.settings[SettingKey.timezone] = Setting(v: .string("America/New_York"), at: 1, by: "t")
        return d
    }

    let A = "AAAAAAAA-0000-0000-0000-000000000000", B = "BBBBBBBB-0000-0000-0000-000000000000"

    func item(_ key: String) -> Item {
        Item(key: key, title: key.uppercased(), due: t0.addingTimeInterval(3600), allDay: false, source: "Canvas")
    }

    func published(_ d: StateDoc, at now: Date) -> StateDoc {
        var p = Sync.publishable(d) { _ in "BEGIN:VCALENDAR\nEND:VCALENDAR" }
        p.device.wrote = Clock.ms(now)
        return p
    }

    func testCheckOnOneDeviceShowsOnTheOther() {
        var a = Checklist(doc: doc(A)), b = Checklist(doc: doc(B))
        let live = a.live([[item("x")]])
        a.toggle(item("x"), live: live, now: t0)
        _ = Sync.merge(&b.doc, peers: [published(a.doc, at: t0)], now: t0)
        XCTAssertEqual(b.doc.records["x"]?.done, true)
        XCTAssertEqual(b.view(live, liveOrder: ["x"], now: t0).completed.map(\.key), ["x"])
    }

    func testLastWriterWinsAndTieBreaksByDevice() {
        var a = Checklist(doc: doc(A)), b = Checklist(doc: doc(B))
        let live = a.live([[item("x")]])
        a.toggle(item("x"), live: live, now: t0)                       // A checks
        b.toggle(item("x"), live: live, now: t0.addingTimeInterval(5)) // B checks too
        b.toggle(item("x"), live: live, now: t0.addingTimeInterval(9)) // …then unchecks, later
        var merged = a.doc
        _ = Sync.merge(&merged, peers: [published(b.doc, at: t0)], now: t0)
        XCTAssertEqual(merged.records["x"]?.done, false, "newest stamp wins")

        // Identical stamps: the higher device id wins on every device.
        var x = doc(A), y = doc(B)
        x.records["k"] = Record(done: true, at: 100, by: A)
        y.records["k"] = Record(done: false, at: 100, by: B)
        var x2 = x, y2 = y
        _ = Sync.merge(&x2, peers: [published(y, at: t0)], now: t0)
        _ = Sync.merge(&y2, peers: [published(x, at: t0)], now: t0)
        XCTAssertEqual(x2.records["k"], y2.records["k"])
        XCTAssertEqual(x2.records["k"]?.by, B)
    }

    func testSettingsFeedsManualMerge() {
        var a = Checklist(doc: doc(A)), b = Checklist(doc: doc(B))
        let feed = a.addFeed(url: "https://x.test/a.ics", name: "X", now: t0)
        a.doc.set(SettingKey.horizonDays, .int(60), now: t0)
        let key = a.addManual(title: "Hand", due: nil, allDay: true, now: t0)
        _ = Sync.merge(&b.doc, peers: [published(a.doc, at: t0)], now: t0)
        XCTAssertEqual(b.doc.feeds[feed]?.name, "X")
        XCTAssertEqual(b.doc.horizonDays, 60)
        XCTAssertNotNil(b.manualItem(key))
        // Delete on B propagates back to A as a tombstone.
        b.deleteManual(key, now: t0.addingTimeInterval(60))
        _ = Sync.merge(&a.doc, peers: [published(b.doc, at: t0)], now: t0)
        XCTAssertNil(a.manualItem(key))
    }

    func testSourcesNewestFetchWinsAndTextIsAdopted() {
        var a = doc(A), b = doc(B)
        var ca = Checklist(doc: a)
        let feed = ca.addFeed(url: "https://x.test/a.ics", name: "X", now: t0)
        a = ca.doc
        a.sources[feed] = SourceSnapshot(fetchedAt: 2000, error: nil, rows: nil, by: A)
        a.sources[StateDoc.gradescopeSource] = SourceSnapshot(fetchedAt: 3000, rows: [], by: A)
        b.sources[StateDoc.gradescopeSource] = SourceSnapshot(fetchedAt: 1000, rows: nil, by: B)
        let r = Sync.merge(&b, peers: [published(a, at: t0)], now: t0)
        XCTAssertEqual(b.sources[feed]?.fetchedAt, 2000)
        XCTAssertEqual(b.sources[feed]?.by, A)
        XCTAssertNotNil(r.adoptedTexts[feed])
        XCTAssertEqual(b.sources[StateDoc.gradescopeSource]?.fetchedAt, 3000)
        // B republishes only its own fetches, never A's.
        XCTAssertTrue(Sync.publishable(b) { _ in "x" }.sources.isEmpty)
    }

    func testSilentPeersAreIgnoredAndLongAbsenceDoesNotResurrect() {
        var a = doc(A)
        var old = doc(B)
        old.records["gone"] = Record(done: true, at: 5, by: B)
        var stale = published(old, at: t0)
        stale.device.wrote = Clock.ms(t0) - 91 * 86_400_000
        _ = Sync.merge(&a, peers: [stale], now: t0)
        XCTAssertNil(a.records["gone"], "a peer silent >90 days is ignored")

        // A comes back after 100 days; "gc" was seen at last sync but every
        // live peer has since collected it.
        a.records["gc"] = Record(done: true, at: Clock.ms(t0) - 150 * 86_400_000, by: A)
        a.records["mine-new"] = Record(done: true, at: Clock.ms(t0), by: A)
        let peer = published(doc(B), at: t0)
        _ = Sync.merge(&a, peers: [peer], now: t0, lastSync: t0.addingTimeInterval(-100 * 86400))
        XCTAssertNil(a.records["gc"])
        XCTAssertNotNil(a.records["mine-new"])
    }

    func testFolderRoundTripSkipsConflictCopiesAndUnchangedWrites() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fa = SyncFolder(root: dir), fb = SyncFolder(root: dir)
        var a = Checklist(doc: doc(A))
        a.toggle(item("x"), live: a.live([[item("x")]]), now: t0)
        XCTAssertTrue(try fa.write(Sync.publishable(a.doc) { _ in nil }, now: t0))
        XCTAssertFalse(try fa.write(Sync.publishable(a.doc) { _ in nil }, now: t0.addingTimeInterval(60)), "unchanged bytes are not rewritten")
        // An iCloud conflict copy and junk are ignored.
        try Data("{}".utf8).write(to: dir.appendingPathComponent("devices/\(A) 2.json"))
        try Data("junk".utf8).write(to: dir.appendingPathComponent("devices/notes.txt"))
        let peers = fb.readPeers(excluding: B)
        XCTAssertEqual(peers.map(\.device.id), [A])
        XCTAssertEqual(peers.first?.records["x"]?.done, true)
        XCTAssertTrue(fa.readPeers(excluding: A).isEmpty, "own file is never read back")
    }

    @MainActor
    func testTwoAppModelsConverge() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        func model(_ name: String) -> AppModel {
            let defaults = UserDefaults(suiteName: "gsd-test-\(name)-\(UUID().uuidString)")!
            let m = AppModel(store: LocalStore(directory: dir.appendingPathComponent(name)), deviceName: name,
                             platform: "test", defaults: defaults, clock: { Date() })
            m.useSyncFolder(dir.appendingPathComponent("shared"))
            return m
        }
        let a = model("A"), b = model("B")
        a.addManual(title: "From A", due: nil, allDay: true)
        a.flush()
        await a.syncAndWait()
        await b.syncAndWait()
        let key = try XCTUnwrap(b.view.main.first { $0.title == "From A" }?.key)
        b.toggle(b.view.main.first { $0.key == key }!)
        b.flush()
        await b.syncAndWait()
        await a.syncAndWait()
        XCTAssertTrue(a.view.done.contains(key))
        XCTAssertEqual(a.syncPeers.map(\.name), ["B"])
        XCTAssertEqual(b.syncPeers.map(\.name), ["A"])
    }
}
