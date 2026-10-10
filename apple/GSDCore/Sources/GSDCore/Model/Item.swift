import CryptoKit
import Foundation

/// One checklist entry (`gsd.models.Item`).
public struct Item: Hashable, Sendable, Identifiable {
    public var key: String
    public var title: String
    public var due: Date?  // nil for an undated VTODO
    public var allDay: Bool
    public var link: String?
    public var source: String
    public var manual: Bool

    public var id: String { key }

    public init(key: String, title: String, due: Date?, allDay: Bool, link: String? = nil,
                source: String = "manual", manual: Bool = false) {
        self.key = key; self.title = title; self.due = due; self.allDay = allDay
        self.link = link; self.source = source; self.manual = manual
    }

    public func day(_ zone: TimeZone) -> Day? { due.map { Clock.day($0, zone) } }

    /// All-day items go overdue once their whole day has elapsed; timed items
    /// the instant their due time passes.
    public func isOverdue(now: Date, zone: TimeZone) -> Bool {
        guard let due else { return false }
        if allDay { return Clock.day(due, zone) < Clock.day(now, zone) }
        return due < now
    }

    /// "HH:mm", or "" for all-day / undated.
    public func timeLabel(_ zone: TimeZone) -> String {
        guard let due, !allDay else { return "" }
        let w = WallTime(instant: due, zone: zone)
        return String(format: "%02d:%02d", w.hour, w.minute)
    }

    /// `sort_key`: dated first by instant, then title case-insensitively.
    public static func sortLess(_ a: Item, _ b: Item) -> Bool {
        switch (a.due, b.due) {
        case let (x?, y?) where x != y: return x < y
        case (nil, _?): return false
        case (_?, nil): return true
        default: break
        }
        let la = Py.lower(a.title), lb = Py.lower(b.title)
        if la != lb { return Py.less(la, lb) }
        return false
    }
}

extension Array {
    /// Stable sort (Python's `sorted` is stable; ties keep input order).
    func stableSorted(by less: (Element, Element) -> Bool) -> [Element] {
        enumerated().sorted { a, b in
            if less(a.element, b.element) { return true }
            if less(b.element, a.element) { return false }
            return a.offset < b.offset
        }.map(\.element)
    }
}

public enum Keys {
    static func sha1Hex(_ s: String) -> String {
        Insecure.SHA1.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// `gsd.ical.item_key`: UID plus the occurrence's UTC date.
    public static func ics(uid: String, occurrence: Date?) -> String {
        let stamp = occurrence.map { Clock.day($0, .utc).compact } ?? "nodate"
        return String(sha1Hex("\(uid)\u{0}\(stamp)").prefix(20))
    }

    /// `gsd.sources._gradescope_key`.
    public static func gradescope(courseID: String, key: String) -> String {
        String(sha1Hex("gradescope\u{0}\(courseID):\(key)").prefix(20))
    }

    /// Stable feed identifier; matches the Python cache file name.
    public static func feed(url: String) -> String { "ics:" + sha256Hex(url).prefix(24) }

    public static func manual() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}
