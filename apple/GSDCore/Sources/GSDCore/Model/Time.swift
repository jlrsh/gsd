import Foundation

/// A proleptic-Gregorian calendar date, like Python's `datetime.date`.
public struct Day: Hashable, Comparable, Codable, Sendable {
    public var year: Int, month: Int, day: Int

    public init(_ year: Int, _ month: Int, _ day: Int) {
        self.year = year; self.month = month; self.day = day
    }

    /// Validating initializer: nil for e.g. Feb 30, like `date()` raising.
    public init?(valid year: Int, _ month: Int, _ day: Int) {
        guard (1...9999).contains(year), (1...12).contains(month),
              day >= 1, day <= Day.daysIn(year, month) else { return nil }
        self.init(year, month, day)
    }

    public static func isLeap(_ y: Int) -> Bool { (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 }

    public static func daysIn(_ y: Int, _ m: Int) -> Int {
        switch m {
        case 2: return isLeap(y) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// Days since 1970-01-01 (Howard Hinnant's days_from_civil).
    public var ordinal: Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    public init(ordinal z0: Int) {
        let z = z0 + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        self.init(yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }

    public func adding(days n: Int) -> Day { Day(ordinal: ordinal + n) }

    /// Python `date.weekday()`: Monday = 0.
    public var weekday: Int { ((ordinal % 7) + 7 + 3) % 7 }

    public static func < (a: Day, b: Day) -> Bool { a.ordinal < b.ordinal }

    public var compact: String { String(format: "%04d%02d%02d", year, month, day) }
    public var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }
}

/// An aware wall-clock datetime: Python's `datetime` with a `tzinfo`.
/// Arithmetic is on the wall clock (like `datetime + timedelta` with ZoneInfo);
/// comparisons are on the instant.
public struct WallTime: Comparable, Sendable {
    public var day: Day
    public var hour: Int, minute: Int, second: Int
    public var zone: TimeZone
    public let instant: Date

    public init(_ day: Day, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0, zone: TimeZone) {
        self.day = day; self.hour = hour; self.minute = minute; self.second = second
        self.zone = zone
        self.instant = WallTime.resolve(day, hour, minute, second, zone)
    }

    /// Python `datetime.replace(tzinfo=...)` semantics via zoneinfo, fold=0:
    /// a wall time is interpreted with the offset in effect just before it.
    static func resolve(_ d: Day, _ h: Int, _ m: Int, _ s: Int, _ zone: TimeZone) -> Date {
        let naive = TimeInterval(d.ordinal * 86400 + h * 3600 + m * 60 + s)
        func offset(_ t: TimeInterval) -> TimeInterval {
            TimeInterval(zone.secondsFromGMT(for: Date(timeIntervalSince1970: t)))
        }
        // Offsets in force a day either side; at most one transition between.
        let before = offset(naive - 86400), after = offset(naive + 86400)
        let valid = Set([before, after]).map { naive - $0 }.filter { naive - offset($0) == $0 }
        if let earliest = valid.min() { return Date(timeIntervalSince1970: earliest) }
        // Nonexistent wall time (spring gap): fold=0 keeps the earlier offset.
        return Date(timeIntervalSince1970: naive - before)
    }

    public init(instant: Date, zone: TimeZone) {
        let off = zone.secondsFromGMT(for: instant)
        let t = Int(floor(instant.timeIntervalSince1970)) + off
        let days = Int(floor(Double(t) / 86400))
        let rem = t - days * 86400
        self.day = Day(ordinal: days)
        self.hour = rem / 3600; self.minute = (rem % 3600) / 60; self.second = rem % 60
        self.zone = zone
        self.instant = instant
    }

    public func addingDays(_ n: Int) -> WallTime {
        WallTime(day.adding(days: n), hour, minute, second, zone: zone)
    }

    public func with(day newDay: Day) -> WallTime { WallTime(newDay, hour, minute, second, zone: zone) }

    public func astimezone(_ z: TimeZone) -> WallTime { WallTime(instant: instant, zone: z) }

    public var weekday: Int { day.weekday }

    public static func < (a: WallTime, b: WallTime) -> Bool { a.instant < b.instant }
    public static func == (a: WallTime, b: WallTime) -> Bool { a.instant == b.instant }
}

public extension TimeZone {
    static let utc = TimeZone(identifier: "UTC")!
}

public enum Clock {
    /// Local calendar day of an instant in `zone`.
    public static func day(_ date: Date, _ zone: TimeZone) -> Day { WallTime(instant: date, zone: zone).day }

    /// Midnight of `day` in `zone`.
    public static func midnight(_ day: Day, _ zone: TimeZone) -> Date { WallTime(day, zone: zone).instant }

    /// ISO 8601 with numeric offset in `zone`, seconds precision (Python
    /// `isoformat(timespec="seconds")`).
    public static func iso(_ date: Date, _ zone: TimeZone) -> String {
        let w = WallTime(instant: date, zone: zone)
        let off = zone.secondsFromGMT(for: date)
        let sign = off < 0 ? "-" : "+"
        let a = abs(off)
        return String(format: "%@T%02d:%02d:%02d%@%02d:%02d", w.day.iso, w.hour, w.minute, w.second,
                      sign, a / 3600, (a % 3600) / 60)
    }

    public static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded(.down)) }

    public static func date(ms: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(ms) / 1000) }
}
