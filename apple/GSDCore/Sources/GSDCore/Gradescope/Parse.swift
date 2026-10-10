import Foundation
import SwiftSoup

public enum Gradescope {
    public static let base = "https://www.gradescope.com"

    public struct Course: Codable, Hashable, Sendable {
        public var id: String
        public var name: String
        public var fullName: String
        public var url: String
    }

    /// One scraped assignment, the same record the Python plugin caches.
    public struct Row: Codable, Hashable, Sendable {
        public var key: String
        public var title: String
        public var dueISO: String
        public var status: String
        public var course: String
        public var courseID: String
        public var url: String

        enum CodingKeys: String, CodingKey {
            case key, title, status, course, url
            case dueISO = "due_iso"
            case courseID = "course_id"
        }
    }

    // MARK: text

    /// bs4 `get_text()`: all text nodes, excluding script/style/template.
    static func allText(_ node: Node) -> String {
        var out = ""
        func walk(_ n: Node) {
            if let t = n as? TextNode {
                out += t.getWholeText()
            } else if n is DataNode || n is Comment {
                return
            } else if let e = n as? Element, ["script", "style", "template"].contains(e.tagName()) {
                return
            } else {
                for child in n.getChildNodes() { walk(child) }
            }
        }
        walk(node)
        return out
    }

    /// `_text`: whitespace runs to one space, stripped.
    static func text(_ node: Element?) -> String {
        guard let node else { return "" }
        return Py.collapse(allText(node))
    }

    static func classes(_ e: Element) -> [String] {
        Py.split((try? e.attr("class")) ?? "")
    }

    static func attr(_ e: Element, _ name: String) -> String? {
        e.hasAttr(name) ? (try? e.attr(name)) : nil
    }

    // MARK: dates

    static let isoPattern = try! NSRegularExpression(
        pattern: #"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2})?)(?:\.\d+)?\s*(Z|[+-]\d{2}:?\d{2})?$"#)

    /// `normalize_datetime`: Gradescope's `datetime` attribute to ISO 8601.
    public static func normalizeDatetime(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let original = Py.strip(raw)
        let value = original.replacingOccurrences(of: #"^(\d{4}-\d{2}-\d{2})[ T]"#, with: "$1T", options: .regularExpression)
        let ns = value as NSString
        if let m = isoPattern.firstMatch(in: value, range: NSRange(location: 0, length: ns.length)) {
            var base = ns.substring(with: m.range(at: 1))
            if base.count == 16 { base += ":00" }
            if m.range(at: 2).location != NSNotFound {
                var offset = ns.substring(with: m.range(at: 2))
                if offset != "Z" && !offset.contains(":") {
                    offset = String(offset.prefix(3)) + ":" + String(offset.dropFirst(3))
                }
                return base + offset
            }
        }
        for candidate in [original.replacingOccurrences(of: "Z", with: "+00:00"),
                          replaceFirst(original, " ", "T").replacingOccurrences(of: "Z", with: "+00:00")] {
            if let parsed = ISODate.parse(candidate) { return parsed.isoformat() }
        }
        return nil
    }

    static func replaceFirst(_ s: String, _ a: String, _ b: String) -> String {
        guard let r = s.range(of: a) else { return s }
        return s.replacingCharacters(in: r, with: b)
    }

    // MARK: pages

    public static func parseCourses(_ html: String, allTerms: Bool = false) throws -> [Course] {
        let doc = try SwiftSoup.parse(html, base)
        var groups: [Element] = []
        let lists = try doc.select(".courseList")
        if !lists.isEmpty() {
            for listing in lists {
                let terms = try listing.select(".courseList--coursesForTerm").array()
                groups += allTerms ? terms : Array(terms.prefix(1))
            }
        } else {
            groups = [doc]
        }
        var courses: [Course] = []
        var seen = Set<String>()
        for group in groups {
            for box in try group.select("a.courseBox, .courseBox") {
                if classes(box).contains("courseBox-new") { continue }
                let href = attr(box, "href") ?? ""
                guard let m = href.firstMatch(of: #/\/courses\/(\d+)/#) else { continue }
                let cid = String(m.1)
                guard seen.insert(cid).inserted else { continue }
                let short = text(try box.select(".courseBox--shortname").first())
                let full = text(try box.select(".courseBox--name").first())
                courses.append(Course(id: cid, name: !short.isEmpty ? short : (!full.isEmpty ? full : "Course \(cid)"),
                                      fullName: !full.isEmpty ? full : short, url: "\(base)/courses/\(cid)"))
            }
        }
        return courses
    }

    /// `_due`: the due-date `<time>`, skipping release and late-due ones.
    static func due(_ row: Element) throws -> String? {
        let times = try row.select("time[datetime]").array()
        func label(_ t: Element) -> String {
            ((attr(t, "aria-label") ?? "") + " " + classes(t).joined(separator: " ")).lowercased()
        }
        let candidates = times.filter { t in !["released", "releasedate", "late due"].contains { label(t).contains($0) } }
        let fallback = candidates.first ?? times.last
        let picked = candidates.first { label($0).contains("due") } ?? fallback
        guard let picked else { return nil }
        return normalizeDatetime(attr(picked, "datetime"))
    }

    public static func parseAssignments(_ html: String, course: Course) throws -> [Row] {
        let doc = try SwiftSoup.parse(html, base)
        let scope: Element = try doc.select("#assignments-student-table").first() ?? doc
        var rows = try scope.select("tbody tr").array()
        if rows.isEmpty { rows = try scope.select("tr").array() }
        var out: [Row] = []
        var used = Set<String>()
        for row in rows {
            guard try row.select("td").first() != nil else { continue }
            let cells = try row.select("th, td").array()
            let first = cells[0]
            let link = try first.select("a[href*=\"/assignments/\"]").first()
            let button = try first.select("button[data-assignment-id]").first() ?? first.select("button").first()
            let title = text(link ?? button ?? first)
            guard !title.isEmpty, let due = try due(row) else { continue }
            var aid = button.flatMap { attr($0, "data-assignment-id") }
            if aid?.isEmpty ?? true, let link {
                aid = (attr(link, "href") ?? "").firstMatch(of: #/assignments\/(\d+)/#).map { String($0.1) }
            }
            if aid?.isEmpty == true { aid = nil }
            var key = aid.map { "a\($0)" } ?? "t:\(title)"
            let baseKey = key
            var suffix = 2
            while used.contains(key) { key = "\(baseKey)#\(suffix)"; suffix += 1 }
            used.insert(key)
            out.append(Row(key: key, title: title, dueISO: due, status: cells.count > 1 ? text(cells[1]) : "",
                           course: course.name, courseID: course.id,
                           url: aid.map { "\(base)/courses/\(course.id)/assignments/\($0)" } ?? course.url))
        }
        return out
    }

    // MARK: status

    public static func isSubmitted(_ status: String) -> Bool {
        status.range(of: #"submitted|graded|\d+\s*/\s*\d+"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The submission window is shut (says nothing about whether anything was turned in).
    public static func isClosed(_ status: String) -> Bool {
        status.range(of: #"closed|no longer accept"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: adapter

    public static func itemKey(_ row: Row) -> String { Keys.gradescope(courseID: row.courseID, key: row.key) }

    /// `gradescope_items`: scraped rows straight into Items.
    public static func items(_ rows: [Row], zone: TimeZone) -> [Item] {
        rows.compactMap { row in
            guard let due = ISODate.parse(row.dueISO.replacingOccurrences(of: "Z", with: "+00:00"))?.date(naiveZone: zone) else { return nil }
            return Item(key: itemKey(row), title: GSDText.clean("\(row.course) — \(row.title)"), due: due,
                        allDay: false, link: row.url, source: "Gradescope")
        }
    }

    /// Closed with something turned in: nothing left to do.
    public static func autoCompleteKeys(_ rows: [Row]) -> Set<String> {
        Set(rows.filter { isClosed($0.status) && isSubmitted($0.status) }.map(itemKey))
    }
}

/// Python `datetime.fromisoformat` (3.11+) for the shapes Gradescope emits.
public struct ISODate: Sendable {
    public var day: Day
    public var hour = 0, minute = 0, second = 0, micro = 0
    public var offset: Int?  // seconds east of UTC; nil = naive

    static let pattern = try! NSRegularExpression(pattern:
        #"^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2})(?::(\d{2})(?::(\d{2})(?:[.,](\d{1,6}))?)?)?)? ?(?:(Z)|([+-])(\d{2})(?::?(\d{2})(?::?(\d{2}))?)?)?$"#)

    public static func parse(_ s: String) -> ISODate? {
        let ns = s as NSString
        guard let m = pattern.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func g(_ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        guard let day = Day(valid: Int(g(1)!)!, Int(g(2)!)!, Int(g(3)!)!) else { return nil }
        var out = ISODate(day: day)
        if let h = g(4) {
            out.hour = Int(h)!
            out.minute = g(5).flatMap { Int($0) } ?? 0
            out.second = g(6).flatMap { Int($0) } ?? 0
            if let f = g(7) { out.micro = Int(f.padding(toLength: 6, withPad: "0", startingAt: 0))! }
            guard out.hour < 24, out.minute < 60, out.second < 60 else { return nil }
        } else if g(8) != nil || g(9) != nil {
            return nil  // an offset needs a time
        }
        if g(8) != nil {
            out.offset = 0
        } else if let sign = g(9) {
            let hh = Int(g(10)!)!, mm = g(11).flatMap { Int($0) } ?? 0, ss = g(12).flatMap { Int($0) } ?? 0
            guard hh < 24, mm < 60, ss < 60 else { return nil }
            out.offset = (sign == "-" ? -1 : 1) * (hh * 3600 + mm * 60 + ss)
        }
        return out
    }

    public func date(naiveZone: TimeZone) -> Date {
        let frac = TimeInterval(micro) / 1_000_000
        if let offset {
            let t = TimeInterval(day.ordinal * 86400 + hour * 3600 + minute * 60 + second - offset)
            return Date(timeIntervalSince1970: t + frac)
        }
        return WallTime(day, hour, minute, second, zone: naiveZone).instant.addingTimeInterval(frac)
    }

    /// `datetime.isoformat()`.
    public func isoformat() -> String {
        var s = String(format: "%@T%02d:%02d:%02d", day.iso, hour, minute, second)
        if micro != 0 { s += String(format: ".%06d", micro) }
        if let offset {
            let sign = offset < 0 ? "-" : "+"
            let a = abs(offset)
            s += String(format: "%@%02d:%02d", sign, a / 3600, (a % 3600) / 60)
            if a % 60 != 0 { s += String(format: ":%02d", a % 60) }
        }
        return s
    }
}
