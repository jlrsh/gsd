import AppIntents
import SwiftUI
import WidgetKit

// MARK: configuration

struct SummaryIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Summary"
    static var description = IntentDescription("Today's progress at a glance.")

    @Parameter(title: "Include Overdue", default: true)
    var includeOverdue: Bool
}

struct SummaryEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    let includeOverdue: Bool

    var summary: Summary? { snapshot.map { Summary($0, now: date, includeOverdue: includeOverdue) } }
}

struct SummaryProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> SummaryEntry {
        SummaryEntry(date: Date(), snapshot: .sample, includeOverdue: true)
    }

    func snapshot(for configuration: SummaryIntent, in context: Context) async -> SummaryEntry {
        let snapshot = WidgetSnapshot.load()
        return SummaryEntry(date: Date(), snapshot: context.isPreview ? snapshot ?? .sample : snapshot,
                            includeOverdue: configuration.includeOverdue)
    }

    func timeline(for configuration: SummaryIntent, in context: Context) async -> Timeline<SummaryEntry> {
        let snapshot = WidgetSnapshot.load()
        let entries = WidgetSnapshot.moments(snapshot).map {
            SummaryEntry(date: $0, snapshot: snapshot, includeOverdue: configuration.includeOverdue)
        }
        return Timeline(entries: entries, policy: .atEnd)
    }

    #if os(watchOS)
    /// Watch faces can't edit a configuration, so offer both up front.
    func recommendations() -> [AppIntentRecommendation<SummaryIntent>] {
        [(true, "Today + Overdue"), (false, "Today Only")].map { include, name in
            let intent = SummaryIntent()
            intent.includeOverdue = include
            return AppIntentRecommendation(intent: intent, description: name)
        }
    }
    #endif
}

extension WidgetSnapshot {
    static let sample = WidgetSnapshot(tasks: [
        Task(title: "CS 381 — HW3", due: Date().addingTimeInterval(3600), allDay: false,
             day: WidgetSnapshot.iso(Date(), .current), source: "Canvas"),
        Task(title: "ME 597 — Lab 1", due: Date().addingTimeInterval(7200), allDay: false,
             day: WidgetSnapshot.iso(Date(), .current), source: "Brightspace"),
        Task(title: "MA 266 — Quiz 2", due: Date().addingTimeInterval(86400), allDay: true,
             day: WidgetSnapshot.iso(Date().addingTimeInterval(86400), .current), source: "Gradescope"),
        Task(title: "PHYS 241 — Problem Set 4", due: Date().addingTimeInterval(-86400), allDay: false,
             day: WidgetSnapshot.iso(Date().addingTimeInterval(-86400), .current), source: "Canvas"),
    ].sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) },
    zone: TimeZone.current.identifier,
    doneDays: [WidgetSnapshot.iso(Date(), .current)])
}
