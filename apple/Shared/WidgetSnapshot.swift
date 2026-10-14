import Foundation

/// The open checklist as the app last saw it, handed to the widgets through
/// the App Group container.  The widget extension can't fetch or parse
/// feeds, so the app publishes this whenever its list changes.
struct WidgetSnapshot: Codable, Equatable {
    struct Task: Codable, Hashable {
        var title: String
        var due: Date?
        var allDay: Bool
        var day: String?  // "yyyy-MM-dd" of the due day in `zone`
        var source: String
    }

    /// Open items in list order: overdue, then by day, then undated.
    var tasks: [Task]
    var zone: String
    /// Due day ("yyyy-MM-dd") of each checked item, for progress rings.
    var doneDays: [String]?

    static let kind = "GSDWidget"
    static let todayKind = "GSDTodayWidget"
    static let summaryKind = "GSDSummaryWidget"
    static let fileName = "widget.json"

    var timeZone: TimeZone { TimeZone(identifier: zone) ?? .current }

    // MARK: App Group storage

    static var appGroup: String? { Bundle.main.object(forInfoDictionaryKey: "GSDAppGroup") as? String }

    static var url: URL? {
        guard let group = appGroup,
              let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        return dir.appendingPathComponent(fileName)
    }

    static func load() -> WidgetSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    /// Write if changed; true when the widgets need reloading.
    static func save(_ snapshot: WidgetSnapshot) -> Bool {
        guard let url, load() != snapshot, let data = try? JSONEncoder().encode(snapshot) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    // MARK: reading against a moment

    func today(_ now: Date) -> String { WidgetSnapshot.iso(now, timeZone) }

    func isOverdue(_ t: Task, now: Date) -> Bool {
        guard let due = t.due, let day = t.day else { return false }
        return t.allDay ? day < today(now) : due < now
    }

    /// Items whose due day is today, overdue-by-time or not.
    func dueToday(_ now: Date) -> [Task] {
        let d = today(now)
        return tasks.filter { $0.day == d }
    }

    static func iso(_ date: Date, _ zone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
}
