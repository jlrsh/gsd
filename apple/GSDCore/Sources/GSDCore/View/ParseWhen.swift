import Foundation

/// `gsd.events.parse_when`: manual due dates like "fri 5pm" or "9/12 23:59".
public enum ParseWhen {
    static let weekdayNames: [[String]] = [
        ["mon", "monday"],
        ["tue", "tues", "tuesday"],
        ["wed", "weds", "wednesday"],
        ["thu", "thur", "thurs", "thursday"],
        ["fri", "friday"],
        ["sat", "saturday"],
        ["sun", "sunday"],
    ]
    static let monthsShort = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    static let monthsLong = ["january", "february", "march", "april", "may", "june", "july",
                             "august", "september", "october", "november", "december"]

    // strptime directive regexes (CPython _strptime, IGNORECASE).
    static let d = #"(3[01]|[12]\d|0[1-9]|[1-9]| [1-9])"#
    static let m = #"(1[0-2]|0[1-9]|[1-9])"#
    static let Y = #"(\d\d\d\d)"#
    static let y = #"(\d\d)"#
    static let b = "(" + monthsShort.joined(separator: "|") + ")"
    static let B = "(" + monthsLong.joined(separator: "|") + ")"

    enum Field { case year4, year2, month, monthName, day }

    struct Format {
        let regex: NSRegularExpression
        let fields: [Field]
        let hasYear: Bool
        init(_ parts: [(String, Field?)], hasYear: Bool) {
            var pattern = "^"
            var fields: [Field] = []
            for (p, f) in parts { pattern += p; if let f { fields.append(f) } }
            regex = try! NSRegularExpression(pattern: pattern + "$", options: [.caseInsensitive])
            self.fields = fields
            self.hasYear = hasYear
        }
    }

    /// The formats in `_DATE_FORMATS`; year-less ones gain " %Y" (they are
    /// always tried with an explicit year).
    static func formats(withYear: Bool) -> [Format] {
        let sp = (#"\s+"#, Field?.none)
        let ys: [(String, Field?)] = withYear ? [sp, (Y, .year4)] : []
        return [
            Format([(Y, .year4), ("-", nil), (m, .month), ("-", nil), (d, .day)], hasYear: true),
            Format([(Y, .year4), ("/", nil), (m, .month), ("/", nil), (d, .day)], hasYear: true),
            Format([(m, .month), ("/", nil), (d, .day), ("/", nil), (Y, .year4)], hasYear: true),
            Format([(m, .month), ("/", nil), (d, .day), ("/", nil), (y, .year2)], hasYear: true),
            Format([(m, .month), ("/", nil), (d, .day)] + ys, hasYear: false),
            Format([(m, .month), ("-", nil), (d, .day)] + ys, hasYear: false),
            Format([(b, .monthName), sp, (d, .day)] + ys, hasYear: false),
            Format([(d, .day), sp, (b, .monthName)] + ys, hasYear: false),
            Format([(B, .monthName), sp, (d, .day)] + ys, hasYear: false),
        ]
    }

    static let dated = formats(withYear: true)

    static func strptime(_ s: String, _ f: Format) -> Day? {
        let ns = s as NSString
        guard let match = f.regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        var year = 1900, month = 1, day = 1
        for (i, field) in f.fields.enumerated() {
            let raw = Py.strip(ns.substring(with: match.range(at: i + 1)))
            switch field {
            case .year4: year = Int(raw)!
            case .year2: let v = Int(raw)!; year = v <= 68 ? 2000 + v : 1900 + v
            case .month: month = Int(raw)!
            case .day: day = Int(raw)!
            case .monthName:
                let l = raw.lowercased()
                month = (monthsShort.firstIndex(of: l) ?? monthsLong.firstIndex(of: l)!) + 1
            }
        }
        return Day(valid: year, month, day)
    }

    static let timeRegex = try! NSRegularExpression(pattern: #"^(\d{1,2})(?::(\d{2}))?\s*(am|pm)?$"#)

    public static func timeToken(_ tok: String) -> (Int, Int)? {
        let t = Py.strip(tok).lowercased()
        let ns = t as NSString
        guard let m = timeRegex.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func group(_ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        guard var hour = Int(group(1)!) else { return nil }
        let minute = group(2).flatMap { Int($0) } ?? 0
        if let ampm = group(3) {
            guard (1...12).contains(hour) else { return nil }
            hour = hour % 12 + (ampm == "pm" ? 12 : 0)
        } else if group(2) == nil {
            return nil  // a bare number is a day, not a time
        }
        guard hour <= 23, minute <= 59 else { return nil }
        return (hour, minute)
    }

    /// (due, all_day), or nil when unreadable.
    public static func parse(_ text: String, now: Date, zone: TimeZone) -> (Date, Bool)? {
        let raw = Py.collapse(text)
        let today = Clock.day(now, zone)
        if raw.isEmpty { return (Clock.midnight(today, zone), true) }

        var clock: (Int, Int)?
        var tokens = raw.components(separatedBy: " ")
        if tokens.count > 1, let t = timeToken(tokens.last!) {
            clock = t
            tokens.removeLast()
        }
        let body = tokens.joined(separator: " ").lowercased()

        var day: Day?
        if ["", "today", "tod"].contains(body) {
            day = today
        } else if ["tomorrow", "tmr", "tom"].contains(body) {
            day = today.adding(days: 1)
        } else if body.wholeMatch(of: #/\+\d+/#) != nil, let n = Int(body.dropFirst()), n < 2_900_000 {
            day = today.adding(days: n)
        } else if let idx = weekdayNames.firstIndex(where: { $0.contains(body) }) {
            let ahead = (idx - today.weekday).floorMod(7)
            day = today.adding(days: ahead == 0 ? 7 : ahead)
        }
        if day == nil {
            outer: for f in dated {
                if f.hasYear {
                    if let got = strptime(body, f) { day = got; break outer }
                    continue
                }
                // Year-less means the next such date; trying successive years
                // also resolves 29 Feb onto the next leap year.
                for bump in 0..<5 {
                    if let c = strptime("\(body) \(today.year + bump)", f), c >= today { day = c; break }
                }
                if day != nil { break }
            }
        }
        guard let day else { return nil }
        guard let clock else { return (Clock.midnight(day, zone), true) }
        return (WallTime(day, clock.0, clock.1, zone: zone).instant, false)
    }
}
