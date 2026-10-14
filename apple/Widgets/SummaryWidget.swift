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
        let entries = Provider.moments(snapshot).map {
            SummaryEntry(date: $0, snapshot: snapshot, includeOverdue: configuration.includeOverdue)
        }
        return Timeline(entries: entries, policy: .atEnd)
    }
}

/// Today's counts.  With overdue included, anything still open past its due
/// time (today's or earlier) is overdue; without, it's just today's items,
/// late or not.
struct Summary {
    var done: Int
    var left: Int
    var overdue: Int

    init(_ snapshot: WidgetSnapshot, now: Date, includeOverdue: Bool) {
        let today = snapshot.today(now)
        done = snapshot.doneDays?.filter { $0 == today }.count ?? 0
        if includeOverdue {
            overdue = snapshot.tasks.filter { snapshot.isOverdue($0, now: now) }.count
            left = snapshot.tasks.filter { $0.day == today && !snapshot.isOverdue($0, now: now) }.count
        } else {
            overdue = 0
            left = snapshot.dueToday(now).count
        }
    }

    var total: Int { done + left + overdue }
    var remaining: Int { left + overdue }
    var doneFraction: Double { total == 0 ? 0 : Double(done) / Double(total) }
    var overdueFraction: Double { total == 0 ? 0 : Double(overdue) / Double(total) }
}

// MARK: widget

struct SummaryWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetSnapshot.summaryKind, intent: SummaryIntent.self, provider: SummaryProvider()) { entry in
            SummaryWidgetView(entry: entry)
        }
        .configurationDisplayName("Summary")
        .description("How much of today is done. Overdue items fill in red.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular])
    }
}

struct SummaryWidgetView: View {
    let entry: SummaryEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content.containerBackground(for: .widget) {
            if family == .accessoryCircular { AccessoryWidgetBackground() } else { Color(.systemBackground) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let s = entry.summary {
            switch family {
            case .accessoryCircular:
                ProgressRing(summary: s, lineWidth: 5, numberFont: .title3.weight(.semibold))
                    .padding(2)
                    .widgetAccentable()
            case .systemMedium:
                HStack(spacing: 20) {
                    ProgressRing(summary: s, lineWidth: 12, numberFont: .system(size: 40, weight: .bold, design: .rounded))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(headline(s)).font(.headline)
                        Breakdown(color: .green, count: s.done, label: "done")
                        Breakdown(color: .secondary, count: s.left, label: "left today")
                        if entry.includeOverdue {
                            Breakdown(color: .red, count: s.overdue, label: "overdue")
                        }
                    }
                    Spacer(minLength: 0)
                }
            default:
                VStack(spacing: 8) {
                    ProgressRing(summary: s, lineWidth: 10, numberFont: .system(size: 34, weight: .bold, design: .rounded))
                    Text(headline(s))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(s.overdue > 0 ? Color.red : Color.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
        } else {
            switch family {
            case .accessoryCircular: Image(systemName: "checklist").font(.title2)
            default: AllClear(title: "Open gsd", detail: "to load your list", symbol: "arrow.up.forward.app")
            }
        }
    }

    private func headline(_ s: Summary) -> String {
        if s.total == 0 { return "All clear for today" }
        if s.remaining == 0 { return "All done today" }
        if s.overdue > 0 { return "\(s.overdue) overdue" }
        return "\(s.left) left today"
    }
}

/// Green for done, red for overdue, over a faint track for what's left.  The
/// number in the middle is everything still open.
struct ProgressRing: View {
    let summary: Summary
    let lineWidth: CGFloat
    let numberFont: Font

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.25), lineWidth: lineWidth)
            arc(from: 0, to: summary.doneFraction, color: .green)
            arc(from: summary.doneFraction, to: summary.doneFraction + summary.overdueFraction, color: .red)
            if summary.remaining == 0 {
                Image(systemName: "checkmark")
                    .font(numberFont)
                    .foregroundStyle(summary.total == 0 ? Color.secondary : Color.green)
            } else {
                Text("\(summary.remaining)")
                    .font(numberFont.monospacedDigit())
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .padding(lineWidth)
            }
        }
        .padding(lineWidth / 2)
    }

    @ViewBuilder
    private func arc(from: Double, to: Double, color: Color) -> some View {
        if to > from {
            Circle()
                .trim(from: from, to: to)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                .rotationEffect(.degrees(-90))
        }
    }
}

struct Breakdown: View {
    let color: Color
    let count: Int
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("\(count)").font(.subheadline.monospacedDigit().weight(.semibold))
            Text(label).font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

#Preview("Summary", as: .systemSmall) {
    SummaryWidget()
} timeline: {
    SummaryEntry(date: Date(), snapshot: .sample, includeOverdue: true)
}

#Preview("Summary Medium", as: .systemMedium) {
    SummaryWidget()
} timeline: {
    SummaryEntry(date: Date(), snapshot: .sample, includeOverdue: true)
}
