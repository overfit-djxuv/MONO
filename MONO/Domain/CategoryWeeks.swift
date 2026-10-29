import Foundation

/// Spending in a month split into its five calendar weeks (days 1-7, 8-14, 15-21, 22-28, and 29 to the end).
enum CategoryWeeks {
    static func spend(_ txs: [TransactionRecord], category: String, month: MonthKey, calendar: Calendar = .current) -> [Int] {
        var weeks = [Int](repeating: 0, count: 5)
        for t in txs where t.kind == .expense && t.category == category && MonthKey(t.date, calendar: calendar) == month {
            let day = calendar.component(.day, from: t.date)
            weeks[min((day - 1) / 7, 4)] += t.amountCents
        }
        return weeks
    }

    /// Weeks that have not started yet are shown empty rather than as "no spending".
    static func started(_ index: Int, month: MonthKey, now: Date = .now, calendar: Calendar = .current) -> Bool {
        let current = MonthKey(now, calendar: calendar)
        if month < current { return true }
        if month > current { return false }
        return calendar.component(.day, from: now) > index * 7
    }
}
