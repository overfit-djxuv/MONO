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
    /// The planned amount of each contribution (per week, fortnight or month, depending on `frequency`).
    var plannedMonthly: Int
    var deadline: Date?
    var contributionDay: Int
    var frequency: ContributionFrequency = .monthly
    /// Schedule start. Weekly and fortnightly contributions fall on this date's rhythm; nothing is scheduled before it.
    var anchor: Date? = nil
    /// Net amount actually contributed over the last 90 days (excluding money you already had saved), used only when no plan exists.
    var recentNet90Days: Int = 0
}

enum EstimateBasis: Equatable {
    /// Based on the planned contribution.
    case plan
    /// Based on how much you actually contributed lately.
    case actualPace
    case none
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
    /// The monthly saving needed if the remainder were spread evenly over the months left:
    /// (target − saved) ÷ remaining months. Under one month left counts as one month. nil when funded or no deadline.
    let requiredMonthlyEquivalent: Int?
    let monthsRemaining: Double?
    /// When the goal is expected to be funded at the planned (or recent actual) pace. An estimate, not a promise.
    let estimatedCompletion: Date?
    let estimateBasis: EstimateBasis
    let frequency: ContributionFrequency
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

    /// Scheduled contribution dates strictly after `today`, never before `anchor`, up to `limit` dates and (if given) the deadline.
    /// Monthly uses the chosen day of the month; weekly and fortnightly keep the rhythm that starts on `anchor`.
    static func schedule(after today: Date, through deadline: Date?, frequency: ContributionFrequency, day: Int, anchor: Date?,
                         limit: Int = 600, calendar: Calendar = .current) -> [Date] {
        let from = calendar.startOfDay(for: today)
        let first = anchor.map { calendar.startOfDay(for: $0) }
        let far = calendar.date(byAdding: .year, value: 100, to: from) ?? from
        let to = deadline.map { calendar.startOfDay(for: $0) } ?? far
        guard to > from else { return [] }

        if let step = frequency.stepDays {
            guard var d = first ?? Optional(from) else { return [] }
            if d <= from {
                let gap = calendar.dateComponents([.day], from: d, to: from).day ?? 0
                d = calendar.date(byAdding: .day, value: (gap / step + 1) * step, to: d) ?? d
            }
            var out: [Date] = []
            while d <= to && out.count < limit {
                out.append(d)
                d = calendar.date(byAdding: .day, value: step, to: d) ?? to.addingTimeInterval(1)
            }
            return out
        }
        let all = contributionDates(after: today, through: to, day: day, calendar: calendar)
        return Array(all.filter { first == nil || $0 >= first! }.prefix(limit))
    }

    static func plan(_ i: PlanInput, today: Date = .now, calendar: Calendar = .current) -> SavingsPlan {
        let remaining = max(i.target - i.saved, 0)
        let funded = i.target > 0 && i.saved >= i.target
        let pct = i.target > 0 ? min(max(Double(i.saved) / Double(i.target), 0), 1) : 0

        let dates = i.deadline.map {
            schedule(after: today, through: $0, frequency: i.frequency, day: i.contributionDay, anchor: i.anchor, calendar: calendar)
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

        // (target − saved) ÷ remaining months; under a month left counts as a month so the figure never explodes.
        var months: Double?
        var monthlyEquivalent: Int?
        if let d = days, d >= 0, let deadline = i.deadline {
            months = Double(d) / (365.2425 / 12)
            // Whole calendar months left, at least one: a few extra days never shrink the amount you are told to save.
            let whole = calendar.dateComponents([.month], from: calendar.startOfDay(for: today), to: calendar.startOfDay(for: deadline)).month ?? 0
            if remaining > 0 { monthlyEquivalent = ceilDiv(remaining, max(whole, 1)) }
        }

        let (completion, basis) = estimate(remaining: remaining, input: i, today: today, calendar: calendar)

        return SavingsPlan(
            target: i.target, saved: i.saved, remaining: remaining, percentFunded: pct,
            contributionsRemaining: n, requiredMonthly: required, expectedAtDeadline: expected,
            shortfall: i.deadline == nil ? 0 : max(i.target - expected, 0),
            surplus: max(expected - i.target, 0), status: status, daysToDeadline: days,
            monthsAtPlannedPace: (remaining > 0 && i.plannedMonthly > 0) ? ceilDiv(remaining, i.plannedMonthly) : nil,
            requiredMonthlyEquivalent: monthlyEquivalent, monthsRemaining: months,
            estimatedCompletion: completion, estimateBasis: basis, frequency: i.frequency
        )
    }

    /// When the goal will be funded: the date of the contribution that finishes it at the planned amount, or, with no plan,
    /// the month it would finish at the recent actual pace. nil if there is neither (or it is already funded).
    static func estimate(remaining: Int, input i: PlanInput, today: Date, calendar: Calendar) -> (Date?, EstimateBasis) {
        guard remaining > 0 else { return (nil, .none) }
        if i.plannedMonthly > 0 {
            let needed = ceilDiv(remaining, i.plannedMonthly)
            let dates = schedule(after: today, through: nil, frequency: i.frequency, day: i.contributionDay, anchor: i.anchor,
                                 limit: needed, calendar: calendar)
            if dates.count == needed, let last = dates.last { return (last, .plan) }
            return (nil, .none)
        }
        let perMonth = i.recentNet90Days / 3
        if perMonth > 0 {
            let months = ceilDiv(remaining, perMonth)
            return (calendar.date(byAdding: .month, value: months, to: calendar.startOfDay(for: today)), .actualPace)
        }
        return (nil, .none)
    }

    // MARK: Goal conveniences

    static func tripTarget(costs: [TripCost], goal: SavingsGoal) -> Int {
        costs.filter { $0.goalID == goal.id }.reduce(0) { $0 + $1.amountCents } + goal.bufferCents
    }

    static func target(for goal: SavingsGoal, costs: [TripCost]) -> Int {
        goal.kind == .trip ? tripTarget(costs: costs, goal: goal) : goal.targetCents
    }

    static func input(for goal: SavingsGoal, costs: [TripCost], entries: [GoalEntry],
                      today: Date = .now, calendar: Calendar = .current) -> PlanInput {
        let since = calendar.date(byAdding: .day, value: -90, to: today) ?? today
        // Money you already had before MONO (not taken from cash) is a starting point, not a saving pace.
        let recent = entries.filter { $0.goalID == goal.id && $0.affectsCash && $0.date >= since && $0.date <= today }
            .reduce(0) { $0 + $1.amountCents }
        return PlanInput(target: target(for: goal, costs: costs),
                         saved: FinanceEngine.balance(of: goal.id, entries: entries),
                         plannedMonthly: goal.plannedMonthlyCents,
                         deadline: goal.deadline,
                         contributionDay: goal.contributionDay,
                         frequency: goal.frequency,
                         anchor: goal.scheduleStart,
                         recentNet90Days: recent)
    }

    static func plan(for goal: SavingsGoal, costs: [TripCost], entries: [GoalEntry],
                     today: Date = .now, calendar: Calendar = .current) -> SavingsPlan {
        plan(input(for: goal, costs: costs, entries: entries, today: today, calendar: calendar), today: today, calendar: calendar)
    }
}
