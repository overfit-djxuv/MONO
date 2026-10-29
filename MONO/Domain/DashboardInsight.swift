import Foundation

/// The single most useful thing to say on the Dashboard. Pure, so the choice is tested; the screen only words it.
enum DashboardInsight: Equatable {
    case overBudget(category: String, overBy: Int)
    case nearLimit(category: String, remaining: Int, percent: Int)
    case paymentDue(title: String, date: Date, overdue: Bool)
    case goalBehind(name: String)

    /// Priority: over a limit, a payment that is overdue or due within 3 days, close to a limit, a goal behind plan.
    static func pick(budget: BudgetSummary, payments: [(title: String, date: Date)], behindGoals: [String],
                     now: Date = .now, calendar: Calendar = .current) -> DashboardInsight? {
        if let over = budget.lines.first(where: { $0.state == .over }) { return .overBudget(category: over.category, overBy: over.overBy) }
        let today = calendar.startOfDay(for: now)
        let soon = payments.sorted { $0.date < $1.date }.first { p in
            let days = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: p.date)).day ?? 99
            return days <= 3
        }
        if let soon {
            return .paymentDue(title: soon.title, date: soon.date, overdue: calendar.startOfDay(for: soon.date) < today)
        }
        if let near = budget.lines.first(where: { $0.state == .warning }) {
            return .nearLimit(category: near.category, remaining: near.remaining, percent: Int((near.fraction * 100).rounded()))
        }
        if let g = behindGoals.first { return .goalBehind(name: g) }
        return nil
    }
}
