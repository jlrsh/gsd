import Foundation
import XCTest
@testable import GSDCore

final class GradescopeTests: XCTestCase {
    func run(_ path: String, dir: String) throws {
        guard let golden = try GoldenTests.json(path) as? [String: Any] else { throw XCTSkip("no golden at \(path)") }
        let zone = TimeZone(identifier: "America/Indiana/Indianapolis")!
        var checked = 0
        for c in golden["courses"] as! [[String: Any]] {
            let html = try String(contentsOf: GoldenTests.fixtures.appendingPathComponent("\(dir)/\(c["file"] as! String)"), encoding: .utf8)
            let got = try Gradescope.parseCourses(html, allTerms: c["allTerms"] as! Bool)
            let want = (c["courses"] as! [[String: String]]).map {
                Gradescope.Course(id: $0["id"]!, name: $0["name"]!, fullName: $0["full_name"]!, url: $0["url"]!)
            }
            XCTAssertEqual(got, want, "\(c["file"]!) allTerms=\(c["allTerms"]!)")
            checked += got.count
        }
        for c in golden["assignments"] as! [[String: Any]] {
            let file = c["file"] as! String
            let html = try String(contentsOf: GoldenTests.fixtures.appendingPathComponent("\(dir)/\(file)"), encoding: .utf8)
            let cd = c["course"] as! [String: String]
            let course = Gradescope.Course(id: cd["id"]!, name: cd["name"]!, fullName: cd["name"]!, url: cd["url"]!)
            let got = try Gradescope.parseAssignments(html, course: course)
            let want = try JSONDecoder().decode([Gradescope.Row].self, from: JSONSerialization.data(withJSONObject: c["rows"]!))
            XCTAssertEqual(got, want, file)
            checked += got.count
            let items = Gradescope.items(got, zone: zone)
            let wantItems = c["items"] as! [[String: Any]]
            XCTAssertEqual(items.map(\.key), wantItems.map { $0["key"] as! String }, file)
            XCTAssertEqual(items.map(\.title), wantItems.map { $0["title"] as! String }, file)
            XCTAssertEqual(items.map { GoldenTests.utc($0.due)! }, wantItems.map { $0["due"] as! String }, file)
            XCTAssertEqual(Gradescope.autoCompleteKeys(got).sorted(), c["autoComplete"] as! [String], file)
            XCTAssertEqual(got.map { Gradescope.isSubmitted($0.status) }, c["submitted"] as! [Bool], file)
            XCTAssertEqual(got.map { Gradescope.isClosed($0.status) }, c["closed"] as! [Bool], file)
        }
        print("Gradescope parity: \(checked) courses+rows from \(path)")
    }

    func testPublicPages() throws { try run("golden/gradescope.json", dir: "html") }
    func testPrivatePages() throws { try run("private/gradescope.json", dir: "private") }

    func testNormalizeDatetime() throws {
        for c in try GoldenTests.json("golden/normalize.json") as! [[String: Any]] {
            let input = c["input"] as! String
            XCTAssertEqual(Gradescope.normalizeDatetime(input), c["output"] as? String, input)
        }
    }
}
