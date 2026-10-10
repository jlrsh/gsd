import Foundation

/// Item snapshot in the Python app's JSON shape (`Item.to_json`).
public struct Snapshot: Codable, Hashable, Sendable {
    public var key: String
    public var title: String
    public var due: String?
    public var allDay: Bool
    public var link: String?
    public var source: String
    public var manual: Bool

    enum CodingKeys: String, CodingKey {
        case key, title, due, link, source, manual
        case allDay = "all_day"
    }

    public init(_ item: Item, zone: TimeZone) {
        key = item.key; title = item.title; due = item.due.map { Clock.iso($0, zone) }
        allDay = item.allDay; link = item.link; source = item.source; manual = item.manual
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? Keys.manual()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "(untitled)"
        if title.isEmpty { title = "(untitled)" }
        due = try c.decodeIfPresent(String.self, forKey: .due)
        allDay = try c.decodeIfPresent(Bool.self, forKey: .allDay) ?? false
        link = try c.decodeIfPresent(String.self, forKey: .link)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "manual"
        if source.isEmpty { source = "manual" }
        manual = try c.decodeIfPresent(Bool.self, forKey: .manual) ?? false
    }

    /// `Item.from_json`: nil when the due string is unreadable.
    public func item(zone: TimeZone) -> Item? {
        var date: Date?
        if let due, !due.isEmpty {
            guard let parsed = ISODate.parse(due) else { return nil }
            date = parsed.date(naiveZone: zone)
        }
        return Item(key: key, title: title, due: date, allDay: allDay, link: link, source: source, manual: manual)
    }
}

/// Per-key check state.  `at` is a Lamport-ish ms stamp for later merging.
public struct Record: Codable, Hashable, Sendable {
    public var done: Bool
    public var at: Int64
    public var by: String
    public var completedAt: String?
    public var src: String?
    public var due: String?
    public var snap: Snapshot?
}

public struct ManualEntry: Codable, Hashable, Sendable {
    public var at: Int64
    public var by: String
    public var deleted: Bool
    public var item: Snapshot?
}

public struct FeedEntry: Codable, Hashable, Sendable {
    public var at: Int64
    public var by: String
    public var deleted: Bool
    public var url: String
    public var name: String
    public var enabled: Bool
}

public enum SettingValue: Codable, Hashable, Sendable {
    case string(String), int(Int), bool(Bool)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int.self) { self = .int(i) }
        else { self = .string(try c.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .int(let i): try c.encode(i)
        case .bool(let b): try c.encode(b)
        }
    }
}

public struct Setting: Codable, Hashable, Sendable {
    public var v: SettingValue
    public var at: Int64
    public var by: String
}

/// Last-good fetch of one source.  ICS text itself lives in a cache file
/// (it must be re-expanded as time passes); Gradescope keeps its rows here.
public struct SourceSnapshot: Codable, Hashable, Sendable {
    public var fetchedAt: Int64?
    public var error: String?
    public var rows: [Gradescope.Row]?
    /// Device that did the fetch (nil = this device, before sync existed).
    public var by: String?
    /// Raw ICS text; only present in published sync files.
    public var text: String?
}

public struct DeviceInfo: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var platform: String
    public var wrote: Int64
}

public struct StateDoc: Codable, Hashable, Sendable {
    public var schema = 1
    public var device: DeviceInfo
    public var records: [String: Record] = [:]
    public var manual: [String: ManualEntry] = [:]
    public var feeds: [String: FeedEntry] = [:]
    public var settings: [String: Setting] = [:]
    public var sources: [String: SourceSnapshot] = [:]

    public init(device: DeviceInfo) { self.device = device }
}

public enum SettingKey {
    public static let timezone = "timezone"
    public static let horizonDays = "horizonDays"
    public static let retentionDays = "retentionDays"
    public static let fetchTimeout = "fetchTimeout"
    public static let gradescopeEnabled = "gradescope.enabled"
    public static let gradescopeEmail = "gradescope.email"
    public static let gradescopeAllTerms = "gradescope.allTerms"
    public static let gradescopeSkipSubmitted = "gradescope.skipSubmitted"
}

public extension StateDoc {
    static let gradescopeSource = "gradescope"

    func string(_ k: String, _ d: String) -> String { if case .string(let s)? = settings[k]?.v { return s }; return d }
    func int(_ k: String, _ d: Int) -> Int { if case .int(let i)? = settings[k]?.v { return i }; return d }
    func bool(_ k: String, _ d: Bool) -> Bool { if case .bool(let b)? = settings[k]?.v { return b }; return d }

    var timezoneSetting: String { string(SettingKey.timezone, "auto") }
    var horizonDays: Int { int(SettingKey.horizonDays, 120) }
    var retentionDays: Int { int(SettingKey.retentionDays, 30) }
    var fetchTimeout: Int { int(SettingKey.fetchTimeout, 10) }
    var gradescopeEnabled: Bool { bool(SettingKey.gradescopeEnabled, false) }
    var gradescopeEmail: String { string(SettingKey.gradescopeEmail, "") }
    var gradescopeAllTerms: Bool { bool(SettingKey.gradescopeAllTerms, false) }
    var gradescopeSkipSubmitted: Bool { bool(SettingKey.gradescopeSkipSubmitted, false) }

    /// The one zone everything renders in (`auto` = the device's).
    var zone: TimeZone {
        let name = Py.strip(timezoneSetting)
        if name.isEmpty || name.lowercased() == "auto" { return .current }
        return ICS.ianaZone(name) ?? .current
    }

    /// Feeds in a stable order (by name, then id).
    var activeFeeds: [(id: String, feed: FeedEntry)] {
        feeds.filter { !$0.value.deleted }
            .sorted { ($0.value.name.lowercased(), $0.key) < ($1.value.name.lowercased(), $1.key) }
            .map { ($0.key, $0.value) }
    }

    /// Next stamp for a key: wall-clock ms, but always past the prior stamp.
    func stamp(after prior: Int64?, now: Date) -> Int64 { max(Clock.ms(now), (prior ?? 0) + 1) }

    mutating func set(_ k: String, _ v: SettingValue, now: Date) {
        guard settings[k]?.v != v else { return }
        settings[k] = Setting(v: v, at: stamp(after: settings[k]?.at, now: now), by: device.id)
    }
}
