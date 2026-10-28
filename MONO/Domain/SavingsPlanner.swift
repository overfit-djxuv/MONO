import Foundation

enum FundingStatus: Equatable {
    case funded     // saved >= target
    case onTrack    // planned contributions reach the target by the deadline
    case behind     // planned contributions fall short by the deadline
    case overdue    // deadline has passed and the target is not met
    case open       // no deadline set
}

struct PlanInput: Equatable {
    var target: Int
    var saved: Int
    var plannedMonthly: Int
    var deadline: Date?
    var contributionDay: Int
}

struct SavingsPlan: Equatable {
    let target: Int
    let saved: Int
    let remaining: Int
    let percentFunded: Double
    /// Scheduled contribution dates strictly after today and on/before the deadline.
    let contributionsRemaining: Int
    /// Even monthly amount needed over the remaining scheduled dates. nil if funded or no dates remain.
    let requiredMonthly: Int?
    /// Saved + planned × remaining contributions.
    let expectedAtDeadline: Int
    let shortfall: Int
    let surplus: Int
    let status: FundingStatus
    /// Whole days until the deadline (negative once passed). nil without a deadline.
    let daysToDeadline: Int?
    /// Months to finish at the planned pace, ignoring the deadline. nil if no planned amount.
    let monthsAtPlannedPace: Int?
    /// True when money is still needed but no scheduled contribution date remains before the deadline.
    var needsLumpSum: Bool { remaining > 0 && contributionsRemaining == 0 && status != .open }
}

enum SavingsPlanner {
    /// Contribution dates for a monthly schedule: the chosen day each month (clamped to month end),
    /// strictly after today, up to and including the deadline day.
    static func contributionDates(after today: Date, through deadline: Date, day: Int,
                                  calendar: Calendar = .current) -> [Date] {
        let from = calendar.startOfDay(for: today)
        let to = calendar.startOfDay(for: deadline)
        guard to > from else { return [] }
        let d = min(max(day, 1), 28)
        var out: [Date] = []
        var m = MonthKey(from, calendar: calendar)
        let last = MonthKey(to, calendar: calendar)
        while m <= last && out.count < 600 {
            let dim = m.daysInMonth(calendar: calendar)
            let date = calendar.date(from: DateComponents(year: m.year, month: m.month, day: min(d, dim))) ?? from
            if date > from && date <= to { out.append(date) }
            m = m.adding(1)
        }
        return out
    }

    static func plan(_ i: PlanInput, today: Date = .now, calendar: Calendar = .current) -> SavingsPlan {
        let remaining = max(i.target - i.saved, 0)
        let funded = i.target > 0 && i.saved >= i.target
        let pct = i.target > 0 ? min(max(Double(i.saved) / Double(i.target), 0), 1) : 0

        let dates = i.deadline.map {
            contributionDates(after: today, through: $0, day: i.contributionDay, calendar: calendar)
        } ?? []
        let n = dates.count
        let expected = i.saved + n * i.plannedMonthly
        let required: Int? = (remaining > 0 && n > 0) ? ceilDiv(remaining, n) : nil

        let status: FundingStatus
        var days: Int?
        if let d = i.deadline {
            days = calendar.dateComponents([.day], from: calendar.startOfDay(for: today),
                                           to: calendar.startOfDay(for: d)).day
            if funded { status = .funded }
            else if (days ?? 0) < 0 { status = .overdue }
            else { status = expected >= i.target ? .onTrack : .behind }
        } else {
            status = funded ? .funded : .open
        }

        return SavingsPlan(
            target: i.target, saved: i.saved, remaining: remaining, percentFunded: pct,
            contributionsRemaining: n, requiredMonthly: required, expectedAtDeadline: expected,
            shortfall: i.deadline == nil ? 0 : max(i.target - expected, 0),
            surplus: max(expected - i.target, 0), status: status, daysToDeadline: days,
            monthsAtPlannedPace: (remaining > 0 && i.plannedMonthly > 0) ? ceilDiv(remaining, i.plannedMonthly) : nil
        )
    }

    // MARK: Goal conveniences

    static func tripTarget(costs: [TripCost], goal: SavingsGoal) -> Int {
        costs.filter { $0.goalID == goal.id }.reduce(0) { $0 + $1.amountCents } + goal.bufferCents
    }

    static func target(for goal: SavingsGoal, costs: [TripCost]) -> Int {
        goal.kind == .trip ? tripTarget(costs: costs, goal: goal) : goal.targetCents
    }

    static func input(for goal: SavingsGoal, costs: [TripCost], entries: [GoalEntry]) -> PlanInput {
        PlanInput(target: target(for: goal, costs: costs),
                  saved: FinanceEngine.balance(of: goal.id, entries: entries),
                  plannedMonthly: goal.plannedMonthlyCents,
                  deadline: goal.deadline,
                  contributionDay: goal.contributionDay)
    }

    static func plan(for goal: SavingsGoal, costs: [TripCost], entries: [GoalEntry],
                     today: Date = .now, calendar: Calendar = .current) -> SavingsPlan {
        plan(input(for: goal, costs: costs, entries: entries), today: today, calendar: calendar)
    }
}
