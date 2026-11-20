import SwiftUI
import WidgetKit

@main
struct GSDWatchWidgets: WidgetBundle {
    var body: some Widget {
        WatchSummaryWidget()
    }
}

/// The Summary ring as a complication.  Full-color faces keep the green and
/// red; tinted ones fall back to one color.
struct WatchSummaryWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetSnapshot.summaryKind, intent: SummaryIntent.self, provider: SummaryProvider()) { entry in
            WatchSummaryView(entry: entry)
                .containerBackground(for: .widget) { AccessoryWidgetBackground() }
        }
        .configurationDisplayName("Summary")
        .description("How much of today is done. Overdue items fill in red.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline])
    }
}

struct WatchSummaryView: View {
    let entry: SummaryEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let s = entry.summary {
            switch family {
            case .accessoryCorner:
                Text(s.remaining == 0 ? "✓" : "\(s.remaining)")
                    .font(.title2.weight(.semibold))
                    .widgetLabel {
                        ProgressView(value: s.doneFraction + s.overdueFraction)
                            .tint(s.overdue > 0 ? .red : .green)
                    }
            case .accessoryRectangular:
                HStack(spacing: 8) {
                    ProgressRing(summary: s, lineWidth: 5, numberFont: .headline)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(s.headline).font(.headline).lineLimit(1).minimumScaleFactor(0.8)
                        Text("\(s.done) done · \(s.left) left").foregroundStyle(.secondary)
                        if entry.includeOverdue, s.overdue > 0 {
                            Text("\(s.overdue) overdue").foregroundStyle(.red)
                        }
                    }
                    Spacer(minLength: 0)
                }
            case .accessoryInline:
                Text(s.remaining == 0 ? "gsd: \(s.headline)" : "gsd: \(s.remaining) open")
            default:
                ProgressRing(summary: s, lineWidth: 5, numberFont: .title3.weight(.semibold))
            }
        } else {
            Image(systemName: "checklist")
        }
    }
}
