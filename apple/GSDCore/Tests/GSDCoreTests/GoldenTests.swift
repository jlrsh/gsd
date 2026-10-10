import Foundation
import XCTest
@testable import GSDCore

/// Parity against golden JSON emitted by `golden/generate.py` from the Python app.
final class GoldenTests: XCTestCase {
    static let fixtures = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")

    static func json(_ path: String) throws -> Any? {
        let url = fixtures.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    }

    static let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func date(_ s: Any?) -> Date? { (s as? String).flatMap { isoParser.date(from: $0) } }

    static func utc(_ d: Date?) -> String? {
        guard let d else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .utc
        return f.string(from: d)
    }

    func nn(_ s: String?) -> AnyHashable { s ?? "<nil>" }

    func itemDict(_ it: Item) -> [String: AnyHashable] {
        ["key": it.key, "title": it.title, "due": nn(GoldenTests.utc(it.due)),
         "allDay": it.allDay, "link": nn(it.link), "source": it.source]
    }

    func goldenItem(_ d: [String: Any]) -> [String: AnyHashable] {
        ["key": d["key"] as! String, "title": d["title"] as! String,
         "due": nn(d["due"] as? String), "allDay": d["allDay"] as! Bool,
         "link": nn(d["link"] as? String), "source": d["source"] as! String]
    }

    func rowList(_ rows: [Row]) -> [[AnyHashable]] {
        rows.map { [$0.kind.rawValue, $0.text, $0.style.rawValue, nn($0.item?.key)] }
    }

    func goldenRows(_ rows: Any?) -> [[AnyHashable]] {
        (rows as! [[Any]]).map { r in r.map { ($0 as? String).map { $0 as AnyHashable } ?? (($0 is NSNull) ? nn(nil) : ($0 as! AnyHashable)) } }
    }

    func runICS(_ path: String, dir: String) throws {
        guard let cases = try GoldenTests.json(path) as? [[String: Any]] else {
            throw XCTSkip("no golden at \(path)")
        }
        XCTAssertFalse(cases.isEmpty)
        var total = 0
        defer { print("ICS parity: \(cases.count) cases, \(total) items from \(path)") }
        for c in cases {
            let file = c["file"] as! String
            let zone = TimeZone(identifier: c["zone"] as! String)!
            let now = GoldenTests.date(c["now"])!
            let label = "\(file) @ \(c["now"]!) \(zone.identifier)"
            let raw = try Data(contentsOf: GoldenTests.fixtures.appendingPathComponent("\(dir)/\(file)"))
            let text = ICS.decode(raw)
            XCTAssertEqual(ICS.looksLikeCalendar(text), c["looksLikeCalendar"] as? Bool, label)
            let items = ICS.items(text, source: (file as NSString).deletingPathExtension,
                                  horizonDays: c["horizon"] as! Int, now: now, zone: zone)
            let want = (c["items"] as! [[String: Any]]).map(goldenItem)
            let got = items.map(itemDict)
            total += got.count
            XCTAssertEqual(got.count, want.count, label)
            for (g, w) in zip(got, want) where g != w {
                XCTFail("\(label)\n got \(g)\nwant \(w)")
                break
            }
            let main = items.stableSorted(by: Item.sortLess)
            let (rows, start) = Rows.build(completed: [], main: main, now: now, zone: zone)
            XCTAssertEqual(rowList(rows), goldenRows(c["rows"]), label)
            XCTAssertEqual(start, c["mainStart"] as? Int)
            let (doneRows, doneStart) = Rows.build(completed: Array(main.prefix(3)), main: Array(main.dropFirst(3)), now: now, zone: zone)
            XCTAssertEqual(rowList(doneRows), goldenRows(c["doneRows"]), label + " (completed)")
            XCTAssertEqual(doneStart, c["doneStart"] as? Int)
            XCTAssertEqual(items.filter { $0.isOverdue(now: now, zone: zone) }.map(\.key), c["overdue"] as! [String], label)
            XCTAssertEqual(items.map { $0.timeLabel(zone) }, c["timeLabels"] as! [String], label)
        }
    }

    func testICSPublicFixtures() throws { try runICS("golden/ics.json", dir: "ics") }

    func testICSPrivateFixtures() throws { try runICS("private/ics.json", dir: "private") }

    func testParseWhen() throws {
        let cases = try GoldenTests.json("golden/when.json") as! [[String: Any]]
        for c in cases {
            let zone = TimeZone(identifier: c["zone"] as! String)!
            let now = GoldenTests.date(c["now"])!
            let input = c["input"] as! String
            let got = ParseWhen.parse(input, now: now, zone: zone)
            XCTAssertEqual(GoldenTests.utc(got?.0), c["due"] as? String, "\(input.debugDescription) @ \(c["now"]!) \(zone.identifier)")
            XCTAssertEqual(got?.1, c["allDay"] as? Bool, input)
        }
    }

    func testText() throws {
        let cases = try GoldenTests.json("golden/text.json") as! [[String: Any]]
        for c in cases {
            let input = c["input"] as! String
            XCTAssertEqual(GSDText.clean(input), c["clean"] as! String, input.debugDescription)
            XCTAssertEqual(ICS.deepUnescape(input), c["deep"] as! String, input.debugDescription)
            XCTAssertEqual(ICS.unescape(input), c["unescape"] as! String, input.debugDescription)
            XCTAssertEqual(Py.repr(input), c["repr"] as! String, input.debugDescription)
        }
    }
}
