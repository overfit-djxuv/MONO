import Foundation

/// Spending insights computed only from recorded transactions. Every function takes records already expressed in the reporting
/// currency (transfers excluded; see `Books.reported`) and returns plain numbers. Nothing here forecasts: results are either actual,
/// or compare equivalent periods, and are labelled as such by the screens.
enum Insights {
    // MARK: Average daily spending

    struct DailyAverage: Equatable {
        let totalCents: Int
        /// Days the average is spread over: days elapsed so far for the current month, the whole month for a past one.
        let days: Int
        let isPartialMonth: Bool
        var averageCents: Int { days > 0 ? totalCents / days : 0 }
    }

    /// Average spent per day in `month`. For the current month only the days that have happened count, so a half-finished month
    /// isn't made to look cheap. nil for a future month.
    static func dailyAverage(_ txs: [TransactionRecord], month: MonthKey, now: Date, calendar: Calendar = .current) -> DailyAverage? {
        let current = MonthKey(now, calendar: calendar)
        guard month <= current else { return nil }
        let total = txs.filter { $0.kind == .expense && MonthKey($0.date, calendar: calendar) == month }.reduce(0) { $0 + $1.amountCents }
        if month == current { return DailyAverage(totalCents: total, days: calendar.component(.day, from: now), isPartialMonth: true) }
        return DailyAverage(totalCents: total, days: month.daysInMonth(calendar: calendar), isPartialMonth: false)
    }

    // MARK: This month so far vs the same days last month

    struct CategoryShift: Equatable, Identifiable {
        let category: String
        let current: Int
        let previous: Int
        var delta: Int { current - previous }
        var id: String { category }
    }

    struct PeriodComparison: Equatable {
        /// The first `days` days of each month are compared, so a part-finished month meets a part of the last one, never a whole.
        let days: Int
        let current: Int
        let previous: Int
        let categories: [CategoryShift]
        var delta: Int { current - previous }
        var percent: Double? { previous > 0 ? Double(delta) / Double(previous) : nil }
    }

    static func monthToDateComparison(_ txs: [TransactionRecord], now: Date, calendar: Calendar = .current) -> PeriodComparison {
        let cur = MonthKey(now, calendar: calendar), prev = cur.adding(-1)
        let days = min(calendar.component(.day, from: now), prev.daysInMonth(calendar: calendar))
        var curCat: [String: Int] = [:], prevCat: [String: Int] = [:]
        for t in txs where t.kind == .expense {
            let k = MonthKey(t.date, calendar: calendar), day = calendar.component(.day, from: t.date)
            guard day <= days else { continue }
            if k == cur { curCat[t.category, default: 0] += t.amountCents } else if k == prev { prevCat[t.category, default: 0] += t.amountCents }
        }
        let shifts = Set(curCat.keys).union(prevCat.keys).map { CategoryShift(category: $0, current: curCat[$0] ?? 0, previous: prevCat[$0] ?? 0) }
            .sorted { abs($0.delta) != abs($1.delta) ? abs($0.delta) > abs($1.delta) : $0.category < $1.category }
        return PeriodComparison(days: days, current: curCat.values.reduce(0, +), previous: prevCat.values.reduce(0, +), categories: shifts)
    }

    // MARK: Weekly pattern

    struct WeekdayAverage: Equatable, Identifiable {
        /// Calendar weekday: 1 = Sunday … 7 = Saturday.
        let weekday: Int
        let averageCents: Int
        /// How many of this weekday the average covers.
        let occurrences: Int
        var id: Int { weekday }
    }

    /// Average spending on each weekday over the last `weeks` weeks (never before your first record), in the order your calendar shows them.
    static func weekdayPattern(_ txs: [TransactionRecord], weeks: Int = 8, now: Date, calendar: Calendar = .current) -> [WeekdayAverage] {
        let end = calendar.startOfDay(for: now)
        let wanted = calendar.date(byAdding: .day, value: -(weeks * 7 - 1), to: end) ?? end
        let expenses = txs.filter { $0.kind == .expense }
        let first = expenses.map { calendar.startOfDay(for: $0.date) }.min() ?? end
        let start = max(wanted, first)
        var totals: [Int: Int] = [:], counts: [Int: Int] = [:]
        var d = start
        while d <= end {
            counts[calendar.component(.weekday, from: d), default: 0] += 1
            d = calendar.date(byAdding: .day, value: 1, to: d) ?? end.addingTimeInterval(1)
        }
        for t in expenses {
            let day = calendar.startOfDay(for: t.date)
            if day >= start && day <= end { totals[calendar.component(.weekday, from: day), default: 0] += t.amountCents }
        }
        let order = (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
        return order.map { wd in
            let n = counts[wd] ?? 0
            return WeekdayAverage(weekday: wd, averageCents: n > 0 ? (totals[wd] ?? 0) / n : 0, occurrences: n)
        }
    }

    // MARK: Categories over time

    /// Spending in the given categories for each month.
    static func categoryTotals(_ txs: [TransactionRecord], categories: Set<String>, months: [MonthKey],
                               calendar: Calendar = .current) -> [(month: MonthKey, cents: Int)] {
        var sums: [MonthKey: Int] = [:]
        for t in txs where t.kind == .expense && categories.contains(t.category) { sums[MonthKey(t.date, calendar: calendar), default: 0] += t.amountCents }
        return months.map { ($0, sums[$0] ?? 0) }
    }

    // MARK: Largest expenses

    static func largestExpenses(_ txs: [TransactionRecord], from: Date, through: Date, limit: Int = 5) -> [TransactionRecord] {
        txs.filter { $0.kind == .expense && $0.date >= from && $0.date <= through }
            .sorted { $0.amountCents != $1.amountCents ? $0.amountCents > $1.amountCents : $0.date > $1.date }
            .prefix(limit).map { $0 }
    }

    // MARK: Changes in spending habits

    /// How each category's spending changed between the last three COMPLETE months and the three before them.
    /// nil unless your records reach back across both windows: three months against one isn't a comparison.
    static func habitChanges(_ txs: [TransactionRecord], now: Date, monthsPerWindow n: Int = 3, limit: Int = 5,
                             calendar: Calendar = .current) -> [CategoryShift]? {
        let cur = MonthKey(now, calendar: calendar)
        let recent = (1...n).map { cur.adding(-$0) }, before = (n + 1...2 * n).map { cur.adding(-$0) }
        guard let first = txs.map({ MonthKey($0.date, calendar: calendar) }).min(), first <= before.last! else { return nil }
        var a: [String: Int] = [:], b: [String: Int] = [:]
        for t in txs where t.kind == .expense {
            let k = MonthKey(t.date, calendar: calendar)
            if recent.contains(k) { a[t.category, default: 0] += t.amountCents } else if before.contains(k) { b[t.category, default: 0] += t.amountCents }
        }
        return Set(a.keys).union(b.keys).map { CategoryShift(category: $0, current: a[$0] ?? 0, previous: b[$0] ?? 0) }
            .filter { $0.delta != 0 }
            .sorted { abs($0.delta) != abs($1.delta) ? abs($0.delta) > abs($1.delta) : $0.category < $1.category }
            .prefix(limit).map { $0 }
    }

    // MARK: Subscriptions

    /// What you actually paid toward subscriptions and bills each month: only transactions recorded from a schedule.
    static func scheduledPayments(_ txs: [TransactionRecord], months: [MonthKey], calendar: Calendar = .current) -> [(month: MonthKey, cents: Int)] {
        var sums: [MonthKey: Int] = [:]
        for t in txs where t.kind == .expense && !t.occurrenceKey.isEmpty { sums[MonthKey(t.date, calendar: calendar), default: 0] += t.amountCents }
        return months.map { ($0, sums[$0] ?? 0) }
    }
}
