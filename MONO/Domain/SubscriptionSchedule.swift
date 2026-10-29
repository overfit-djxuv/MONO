import Foundation

/// Dates and costs for repeating payments. Pure functions.
enum SubscriptionSchedule {
    /// The payment after `date`: a number of weeks later, or the same day of a later month or year.
    /// Months and years keep `anchorDay`, so a payment on the 31st falls on the last day of shorter months and returns to the 31st after.
    static func advance(_ date: Date, unit: RecurrenceUnit, interval: Int, anchorDay: Int, calendar: Calendar = .current) -> Date {
        let n = max(interval, 1), start = calendar.startOfDay(for: date)
        switch unit {
        case .week:
            return calendar.date(byAdding: .day, value: 7 * n, to: start) ?? start
        case .month, .year:
            let m = MonthKey(start, calendar: calendar).adding(unit == .month ? n : 12 * n)
            let day = min(max(anchorDay, 1), m.daysInMonth(calendar: calendar))
            return calendar.date(from: DateComponents(year: m.year, month: m.month, day: day)) ?? start
        }
    }

    /// Every payment from `next` up to and including `end`, oldest first. Includes overdue ones (before today) because they are still owed.
    static func dueDates(from next: Date, through end: Date, unit: RecurrenceUnit, interval: Int, anchorDay: Int,
                         limit: Int = 60, calendar: Calendar = .current) -> [Date] {
        var out: [Date] = [], d = calendar.startOfDay(for: next)
        let last = calendar.startOfDay(for: end)
        while d <= last && out.count < limit {
            out.append(d)
            let following = advance(d, unit: unit, interval: interval, anchorDay: anchorDay, calendar: calendar)
            if following <= d { break }
            d = following
        }
        return out
    }

    /// The first payment on or after `date` that keeps the schedule's rhythm. Used when resuming, so nothing missed while paused is owed.
    static func firstOnOrAfter(_ date: Date, from next: Date, unit: RecurrenceUnit, interval: Int, anchorDay: Int,
                               calendar: Calendar = .current) -> Date {
        var d = calendar.startOfDay(for: next)
        let target = calendar.startOfDay(for: date)
        var guardCount = 0
        while d < target && guardCount < 5_000 {
            let following = advance(d, unit: unit, interval: interval, anchorDay: anchorDay, calendar: calendar)
            if following <= d { break }
            d = following; guardCount += 1
        }
        return d
    }

    /// How many payments fall in a year.
    static func timesPerYear(unit: RecurrenceUnit, interval: Int) -> Decimal {
        let n = Decimal(max(interval, 1))
        switch unit { case .week: return 52 / n; case .month: return 12 / n; case .year: return 1 / n }
    }

    private static func rounded(_ d: Decimal) -> Int {
        NSDecimalNumber(decimal: d).rounding(accordingToBehavior: NSDecimalNumberHandler(
            roundingMode: .plain, scale: 0, raiseOnExactness: false, raiseOnOverflow: false, raiseOnUnderflow: false, raiseOnDivideByZero: false)).intValue
    }

    /// An estimate: the amount spread evenly over twelve months.
    static func monthlyCost(_ amountCents: Int, unit: RecurrenceUnit, interval: Int) -> Int {
        rounded(Decimal(amountCents) * timesPerYear(unit: unit, interval: interval) / 12)
    }
    static func annualCost(_ amountCents: Int, unit: RecurrenceUnit, interval: Int) -> Int {
        rounded(Decimal(amountCents) * timesPerYear(unit: unit, interval: interval))
    }

    /// Names a schedule the way people say it.
    static func describe(unit: RecurrenceUnit, interval: Int) -> String {
        switch (unit, interval) {
        case (.week, 1): return "Weekly"; case (.week, 2): return "Every 2 weeks"
        case (.month, 1): return "Monthly"; case (.month, 3): return "Every 3 months"; case (.month, 6): return "Every 6 months"
        case (.year, 1): return "Yearly"
        default: return interval <= 1 ? "Every \(unit.rawValue)" : "Every \(interval) \(unit.rawValue)s"
        }
    }
}

extension RecurringRule {
    var anchorDay: Int { min(max(dayOfMonth, 1), 31) }
    var scheduleText: String { SubscriptionSchedule.describe(unit: unit, interval: interval) }

    /// Unconfirmed payments from the next one through `end`.
    func dueDates(through end: Date, calendar: Calendar = .current) -> [Date] {
        SubscriptionSchedule.dueDates(from: dueDate, through: end, unit: unit, interval: interval, anchorDay: anchorDay, calendar: calendar)
    }
    func following(_ date: Date, calendar: Calendar = .current) -> Date {
        SubscriptionSchedule.advance(date, unit: unit, interval: interval, anchorDay: anchorDay, calendar: calendar)
    }
    var monthlyCostEstimate: Int { SubscriptionSchedule.monthlyCost(amountCents, unit: unit, interval: interval) }
    var annualCostEstimate: Int { SubscriptionSchedule.annualCost(amountCents, unit: unit, interval: interval) }

    /// The key that identifies one occurrence, e.g. "…|2026-03-05".
    func occurrenceKey(for due: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: due)
        return "\(id.uuidString)|" + String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
