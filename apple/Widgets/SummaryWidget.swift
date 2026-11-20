import SwiftUI
import WidgetKit

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
                        Text(s.headline).font(.headline)
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
                    Text(s.headline)
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
