import SwiftUI

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

    var headline: String {
        if total == 0 { return "All clear for today" }
        if remaining == 0 { return "All done today" }
        if overdue > 0 { return "\(overdue) overdue" }
        return "\(left) left today"
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
