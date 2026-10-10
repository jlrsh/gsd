import Foundation

extension ICS {
    static let weekdays: [String: Int] = ["MO": 0, "TU": 1, "WE": 2, "TH": 3, "FR": 4, "SA": 5, "SU": 6]

    static func parseRRule(_ value: String) -> [String: String] {
        var rule: [String: String] = [:]
        for part in value.split(separator: ";", omittingEmptySubsequences: false) {
            guard let eq = part.firstIndex(of: "=") else { continue }
            rule[Py.strip(String(part[..<eq])).uppercased()] = Py.strip(String(part[part.index(after: eq)...]))
        }
        return rule
    }

    /// `int(s)` for the forms RRULE values take (optional sign, digits, spaces).
    static func pyInt(_ s: String) -> Int? {
        let t = Py.strip(s)
        var body = Substring(t)
        var sign = 1
        if let f = body.first, f == "+" || f == "-" { sign = f == "-" ? -1 : 1; body = body.dropFirst() }
        guard !body.isEmpty, body.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(body) else { return nil }
        return sign * n
    }

    private static func addMonths(_ d: WallTime, _ n: Int) -> WallTime? {
        let y = d.day.year + (d.day.month - 1 + n).floorDiv(12)
        let m = (d.day.month - 1 + n).floorMod(12) + 1
        guard let day = Day(valid: y, m, d.day.day) else { return nil }
        return d.with(day: day)
    }

    private static func nthWeekday(_ year: Int, _ month: Int, _ weekday: Int, _ nth: Int) -> Day? {
        let first = Day(year, month, 1)
        let offset = (weekday - first.weekday).floorMod(7)
        var days: [Day] = []
        var d = first.adding(days: offset)
        while d.month == month { days.append(d); d = d.adding(days: 7) }
        if nth > 0 { return nth <= days.count ? days[nth - 1] : nil }
        // Python: days[nth] if -nth <= len(days); days[0] when nth == 0.
        guard -nth <= days.count else { return nil }
        return nth == 0 ? days.first : days[days.count + nth]
    }

    private static func monthEnd(_ year: Int, _ month: Int, _ offset: Int) -> Day? {
        let next = month == 12 ? Day(year + 1, 1, 1) : Day(year, month + 1, 1)
        let d = next.adding(days: offset)
        return d.month == month ? d : nil
    }

    /// Expand DAILY/WEEKLY/MONTHLY rules within [lo, hi].  Unsupported rule
    /// parts degrade to the lone DTSTART.  COUNT is tallied from DTSTART.
    static func expand(_ dtstart: WallTime, _ rule: [String: String], lo: Date, hi: Date,
                       local: TimeZone, cap: Int = 500) -> [WallTime] {
        let freq = (rule["FREQ"] ?? "").uppercased()
        guard ["DAILY", "WEEKLY", "MONTHLY"].contains(freq) else { return [dtstart] }
        for unsupported in ["BYSETPOS", "BYWEEKNO", "BYYEARDAY", "BYMONTH", "BYHOUR"] {
            if let v = rule[unsupported], !v.isEmpty { return [dtstart] }
        }
        let interval = max(1, pyInt(rule["INTERVAL"] ?? "1") ?? 1)
        let count: Int? = (rule["COUNT"].flatMap { $0.isEmpty ? nil : $0 }).flatMap(pyInt)
        var until: Date?
        if let u = rule["UNTIL"], !u.isEmpty { until = parseDate(u, [], local: local)?.0.instant }

        let rawByday = (rule["BYDAY"] ?? "").split(separator: ",", omittingEmptySubsequences: false)
            .map { Py.strip(String($0)).uppercased() }.filter { !$0.isEmpty }
        let byday = rawByday.compactMap { weekdays[String($0.suffix(2))] }
        var nthByday: [(Int, Int)] = []
        for tok in rawByday {
            guard let m = tok.wholeMatch(of: #/([+-]?\d+)(MO|TU|WE|TH|FR|SA|SU)/#),
                  let n = pyInt(String(m.1)) else { continue }
            nthByday.append((n, weekdays[String(m.2)]!))
        }
        var bymonthday: [Int] = []
        for x in (rule["BYMONTHDAY"] ?? "").split(separator: ",", omittingEmptySubsequences: false)
        where !Py.strip(String(x)).isEmpty {
            guard let n = pyInt(String(x)) else { bymonthday = []; break }
            bymonthday.append(n)
        }

        var out: [WallTime] = []
        var emitted = 0
        func emit(_ occ: WallTime) -> Bool {
            if let until, occ.instant > until { return false }
            emitted += 1
            if let count, emitted > count { return false }
            if occ.instant > hi { return false }
            if occ.instant >= lo { out.append(occ) }
            return out.count < cap
        }

        if freq == "WEEKLY" && !byday.isEmpty {
            // DTSTART is always the first instance, even off-pattern.
            if !byday.contains(dtstart.weekday) && !emit(dtstart) { return out }
            let week0 = dtstart.addingDays(-dtstart.weekday)
            let limit = hi.addingTimeInterval(7 * 86400)
            let sortedDays = byday.sorted()
            for w in 0..<600 {
                let week = week0.addingDays(w * interval * 7)
                if week.instant > limit { break }
                for wd in sortedDays {
                    let occ = week.addingDays(wd)
                    if occ < dtstart { continue }
                    if !emit(occ) { return out }
                }
            }
            return out
        }

        if freq == "MONTHLY" && (!bymonthday.isEmpty || !nthByday.isEmpty) {
            let firstOfMonth = dtstart.with(day: Day(dtstart.day.year, dtstart.day.month, 1))
            for i in 0..<400 {
                guard let anchor = addMonths(firstOfMonth, interval * i) else { continue }
                // datetime.combine(date(y, m, 1), clock) > hi
                if anchor.instant > hi { break }
                var days: [Day] = []
                for md in bymonthday {
                    if md > 0 {
                        if let d = Day(valid: anchor.day.year, anchor.day.month, md) { days.append(d) }
                    } else if let d = monthEnd(anchor.day.year, anchor.day.month, md) {
                        days.append(d)
                    }
                }
                for (nth, wd) in nthByday {
                    if let d = nthWeekday(anchor.day.year, anchor.day.month, wd, nth) { days.append(d) }
                }
                for d in days.sorted() {
                    let occ = dtstart.with(day: d)
                    if occ < dtstart { continue }
                    if !emit(occ) { return out }
                }
            }
            return out
        }

        var occ: WallTime? = dtstart
        for i in 0..<2000 {
            if let o = occ, !emit(o) { break }
            let step = interval * (i + 1)
            switch freq {
            case "DAILY": occ = dtstart.addingDays(step)
            case "WEEKLY": occ = dtstart.addingDays(7 * step)
            default: occ = addMonths(dtstart, step)
            }
            if let o = occ, o.instant > hi { break }
        }
        return out
    }
}

extension Int {
    func floorDiv(_ d: Int) -> Int { Int((Double(self) / Double(d)).rounded(.down)) }
    func floorMod(_ d: Int) -> Int { ((self % d) + d) % d }
}
