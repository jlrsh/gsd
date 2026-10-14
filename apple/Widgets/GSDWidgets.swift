import SwiftUI
import WidgetKit

@main
struct GSDWidgets: WidgetBundle {
    var body: some Widget {
        ListWidget()
        TodayWidget()
        SummaryWidget()
    }
}

// MARK: timeline

struct Entry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: Date(), snapshot: .sample) }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: Date(), snapshot: context.isPreview ? WidgetSnapshot.load() ?? .sample : WidgetSnapshot.load()))
    }

    /// The list only changes when the app republishes it, but what's "today"
    /// and "overdue" moves with the clock: re-render at each due time and at
    /// the next two midnights.
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let snapshot = WidgetSnapshot.load()
        let entries = Provider.moments(snapshot).map { Entry(date: $0, snapshot: snapshot) }
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    static func moments(_ snapshot: WidgetSnapshot?) -> [Date] {
        let now = Date()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = snapshot?.timeZone ?? .current
        let midnight = cal.startOfDay(for: now)
        let horizon = cal.date(byAdding: .day, value: 2, to: midnight)!
        var moments: Set<Date> = [now, cal.date(byAdding: .day, value: 1, to: midnight)!, horizon]
        for t in snapshot?.tasks ?? [] where !t.allDay {
            if let due = t.due, due > now, due < horizon { moments.insert(due) }
        }
        return Array(moments.sorted().prefix(60))
    }
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

// MARK: Home Screen: the list

struct ListWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshot.kind, provider: Provider()) { entry in
            ListWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Checklist")
        .description("Your open items, soonest first.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct ListWidgetView: View {
    let entry: Entry
    @Environment(\.widgetFamily) private var family

    private var capacity: Int {
        switch family {
        case .systemLarge: return 13
        default: return 6
        }
    }

    var body: some View {
        if let snapshot = entry.snapshot {
            if snapshot.tasks.isEmpty {
                AllClear(title: "All clear", detail: "Nothing due")
            } else {
                list(snapshot)
            }
        } else {
            AllClear(title: "Open gsd", detail: "to load your list", symbol: "arrow.up.forward.app")
        }
    }

    private func list(_ snapshot: WidgetSnapshot) -> some View {
        let tasks = snapshot.tasks
        let shown = tasks.count > capacity ? Array(tasks.prefix(capacity - 1)) : tasks
        return VStack(alignment: .leading, spacing: family == .systemLarge ? 5 : 4) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, task in
                TaskRow(task: task, snapshot: snapshot, now: entry.date, showSource: family != .systemSmall)
            }
            if tasks.count > shown.count {
                Text("+\(tasks.count - shown.count) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct TaskRow: View {
    let task: WidgetSnapshot.Task
    let snapshot: WidgetSnapshot
    let now: Date
    let showSource: Bool

    private var overdue: Bool { snapshot.isOverdue(task, now: now) }

    /// The time today, the weekday this week, the date further out or once
    /// overdue (as the app shows it).
    private var label: String {
        guard let due = task.due, let day = task.day else { return "" }
        let zone = snapshot.timeZone
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        if overdue {
            f.dateFormat = "MM/dd"
        } else if day == snapshot.today(now) {
            if task.allDay { return "today" }
            f.dateFormat = "HH:mm"
        } else if due.timeIntervalSince(now) < 6 * 86400 {
            f.dateFormat = "EEE"
        } else {
            f.dateFormat = "MM/dd"
        }
        return f.string(from: due)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.caption.monospacedDigit())
                .foregroundStyle(overdue ? Color.red : Color.secondary)
                .frame(width: 38, alignment: .trailing)
            Text(task.title)
                .font(.footnote)
                .lineLimit(1)
            if showSource {
                Spacer(minLength: 4)
                Text(task.source)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
        }
    }
}

struct AllClear: View {
    let title: String
    let detail: String
    var symbol = "checkmark.seal"

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.title)
                .foregroundStyle(Color.accentColor)
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: Lock Screen: what's due today

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshot.todayKind, provider: Provider()) { entry in
            TodayWidgetView(entry: entry)
        }
        .configurationDisplayName("Due Today")
        .description("What's due today, or all clear.")
        .supportedFamilies([.accessoryRectangular, .accessoryInline, .accessoryCircular])
    }
}

struct TodayWidgetView: View {
    let entry: Entry
    @Environment(\.widgetFamily) private var family

    private var today: [WidgetSnapshot.Task] { entry.snapshot?.dueToday(entry.date) ?? [] }

    var body: some View {
        content.containerBackground(for: .widget) {
            if family == .accessoryCircular { AccessoryWidgetBackground() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryInline:
            if entry.snapshot == nil {
                Text("Open gsd")
            } else if today.isEmpty {
                Label("All clear today", systemImage: "checkmark.circle")
            } else {
                Label("\(today.count) due today", systemImage: "checklist")
            }
        case .accessoryCircular:
            VStack(spacing: 0) {
                if today.isEmpty {
                    Image(systemName: "checkmark").font(.title2.weight(.semibold))
                } else {
                    Text("\(today.count)").font(.title.weight(.semibold)).minimumScaleFactor(0.6)
                    Text("today").font(.caption2)
                }
            }
        default:
            rectangular
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            if entry.snapshot == nil {
                Text("gsd").font(.headline)
                Text("Open the app to load today's tasks").foregroundStyle(.secondary)
            } else if today.isEmpty {
                Label("All clear for today", systemImage: "checkmark.circle").font(.headline)
                if let next = entry.snapshot?.tasks.first(where: { $0.due != nil && !entry.snapshot!.isOverdue($0, now: entry.date) }) {
                    Text("Next: \(next.title)").foregroundStyle(.secondary).lineLimit(2)
                }
            } else {
                ForEach(Array(today.prefix(2).enumerated()), id: \.offset) { _, task in
                    Text(task.title).font(.headline).lineLimit(1)
                }
                if today.count > 2 {
                    let more = today.count - 2
                    Text("+\(more) more \(more == 1 ? "task" : "tasks") due today")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetAccentable()
    }
}

#Preview("Lock Screen", as: .accessoryRectangular) {
    TodayWidget()
} timeline: {
    Entry(date: Date(), snapshot: .sample)
    Entry(date: Date(), snapshot: WidgetSnapshot(tasks: [], zone: TimeZone.current.identifier))
}

#Preview("Large", as: .systemLarge) {
    ListWidget()
} timeline: {
    Entry(date: Date(), snapshot: .sample)
}
