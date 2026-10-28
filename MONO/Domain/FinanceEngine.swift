import Foundation

// Pure calculation logic. No UI, no persistence calls — the views only format what comes back.

struct MonthSummary: Identifiable, Equatable {
    var id: MonthKey { month }
    let month: MonthKey
    let income: Int
    let expense: Int
    let recordCount: Int
    var net: Int { income - expense }
    /// nil when there is no income to measure against (never a made-up 0%).
    var savingsRate: Double? { income > 0 ? Double(income - expense) / Double(income) : nil }
}

enum BudgetState: Equatable { case ok, warning, over }

struct BudgetLine: Identifiable, Equatable {
    var id: String { category }
    let category: String
    let limit: Int
    let spent: Int
    var remaining: Int { limit - spent }
    var overBy: Int { max(spent - limit, 0) }
    var fraction: Double { limit > 0 ? Double(spent) / Double(limit) : (spent > 0 ? 1 : 0) }
    var state: BudgetState {
        if spent > limit { return .over }
        return fraction >= FinanceEngine.warningThreshold ? .warning : .ok
    }
}

struct BudgetSummary: Equatable {
    let month: MonthKey
    /// Explicit monthly total, else the sum of category limits, else nil.
    let total: Int?
    let spent: Int
    let lines: [BudgetLine]
    /// Spending in categories that have no limit.
    let unbudgetedSpent: Int
    let daysLeft: Int

    var remaining: Int? { total.map { $0 - spent } }
    var overBy: Int { max(spent - (total ?? spent), 0) }
    var fraction: Double? {
        guard let t = total, t > 0 else { return nil }
        return Double(spent) / Double(t)
    }
    var state: BudgetState? {
        guard let t = total else { return nil }
        if spent > t { return .over }
        return (fraction ?? 0) >= FinanceEngine.warningThreshold ? .warning : .ok
    }
    /// Suggested average daily spend for the rest of the month. nil for past months / no budget.
    var dailyAllowance: Int? {
        guard let r = remaining, daysLeft > 0 else { return nil }
        return max(r, 0) / daysLeft
    }
    func dailyAllowance(for line: BudgetLine) -> Int? {
        daysLeft > 0 ? max(line.remaining, 0) / daysLeft : nil
    }
}

enum FinanceEngine {
    static let warningThreshold = 0.8

    // MARK: Balances

    static func totals(_ txs: [TransactionRecord], in month: MonthKey,
                       calendar: Calendar = .current) -> (income: Int, expense: Int) {
        var income = 0, expense = 0
        for t in txs where MonthKey(t.date, calendar: calendar) == month {
            if t.kind == .income { income += t.amountCents } else { expense += t.amountCents }
        }
        return (income, expense)
    }

    /// Opening balance + income − expenses − money moved into goals (+ money moved back out).
    /// Goal movements are neither income nor expense, so allocating to a goal can never create or
    /// destroy money; it only moves it between "available cash" and "saved".
    static func availableCash(opening: Int, transactions: [TransactionRecord], entries: [GoalEntry]) -> Int {
        var cash = opening
        for t in transactions { cash += t.kind == .income ? t.amountCents : -t.amountCents }
        for e in entries where e.affectsCash { cash -= e.amountCents }
        return cash
    }

    static func savedTotal(entries: [GoalEntry]) -> Int { entries.reduce(0) { $0 + $1.amountCents } }

    static func balance(of goalID: UUID, entries: [GoalEntry]) -> Int {
        entries.reduce(0) { $0 + ($1.goalID == goalID ? $1.amountCents : 0) }
    }

    static func savingsRate(income: Int, expense: Int) -> Double? {
        income > 0 ? Double(income - expense) / Double(income) : nil
    }

    // MARK: Categories

    static func expensesByCategory(_ txs: [TransactionRecord], in months: ClosedRange<MonthKey>,
                                   calendar: Calendar = .current) -> [(category: String, cents: Int)] {
        var sums: [String: Int] = [:]
        for t in txs where t.kind == .expense && months.contains(MonthKey(t.date, calendar: calendar)) {
            sums[t.category, default: 0] += t.amountCents
        }
        return sums.map { (category: $0.key, cents: $0.value) }
            .sorted { $0.cents != $1.cents ? $0.cents > $1.cents : $0.category < $1.category }
    }

    // MARK: Series

    /// One summary per month in `range`. Months with no records report zeros and recordCount 0.
    static func monthlySummaries(_ txs: [TransactionRecord], range: [MonthKey],
                                 calendar: Calendar = .current) -> [MonthSummary] {
        var income: [MonthKey: Int] = [:], expense: [MonthKey: Int] = [:], count: [MonthKey: Int] = [:]
        for t in txs {
            let k = MonthKey(t.date, calendar: calendar)
            count[k, default: 0] += 1
            if t.kind == .income { income[k, default: 0] += t.amountCents } else { expense[k, default: 0] += t.amountCents }
        }
        return range.map {
            MonthSummary(month: $0, income: income[$0] ?? 0, expense: expense[$0] ?? 0, recordCount: count[$0] ?? 0)
        }
    }

    static func firstRecordMonth(transactions: [TransactionRecord], entries: [GoalEntry] = [],
                                 calendar: Calendar = .current) -> MonthKey? {
        let dates = transactions.map(\.date) + entries.map(\.date)
        return dates.min().map { MonthKey($0, calendar: calendar) }
    }

    /// Cumulative amount held in goals at the end of each month from the first entry to `through`.
    /// Only recorded movements are used; nothing before the first entry is invented.
    static func savingsGrowth(entries: [GoalEntry], through: MonthKey,
                              calendar: Calendar = .current) -> [(month: MonthKey, cents: Int)] {
        guard let first = entries.map(\.date).min() else { return [] }
        var perMonth: [MonthKey: Int] = [:]
        for e in entries { perMonth[MonthKey(e.date, calendar: calendar), default: 0] += e.amountCents }
        var running = 0
        return MonthKey(first, calendar: calendar).months(through: max(through, MonthKey(first, calendar: calendar))).map {
            running += perMonth[$0] ?? 0
            return (month: $0, cents: running)
        }
    }

    // MARK: Budget

    static func budgetSummary(month: MonthKey, totalLimit: Int?, limits: [BudgetLimit],
                              transactions: [TransactionRecord], today: Date = .now,
                              calendar: Calendar = .current) -> BudgetSummary {
        var spentBy: [String: Int] = [:]
        var spent = 0
        for t in transactions where t.kind == .expense && MonthKey(t.date, calendar: calendar) == month {
            spentBy[t.category, default: 0] += t.amountCents
            spent += t.amountCents
        }
        let monthLimits = limits.filter { $0.monthKey == month.string }
        let lines = monthLimits
            .map { BudgetLine(category: $0.category, limit: $0.limitCents, spent: spentBy[$0.category] ?? 0) }
            .sorted { $0.fraction > $1.fraction }
        let budgeted = Set(monthLimits.map(\.category))
        let unbudgeted = spentBy.filter { !budgeted.contains($0.key) }.values.reduce(0, +)

        let sumLimits = monthLimits.reduce(0) { $0 + $1.limitCents }
        let total: Int? = totalLimit ?? (monthLimits.isEmpty ? nil : sumLimits)

        let current = MonthKey(today, calendar: calendar)
        let days = month.daysInMonth(calendar: calendar)
        let left: Int
        if month == current { left = days - calendar.component(.day, from: today) + 1 }
        else if month > current { left = days }
        else { left = 0 }

        return BudgetSummary(month: month, total: total, spent: spent, lines: lines,
                             unbudgetedSpent: unbudgeted, daysLeft: left)
    }

    struct BudgetRollover: Equatable {
        /// Set only when the previous month had an explicit monthly total.
        var totalCents: Int?
        var limits: [(category: String, cents: Int)]
        static func == (a: Self, b: Self) -> Bool {
            a.totalCents == b.totalCents && a.limits.count == b.limits.count
                && zip(a.limits, b.limits).allSatisfy { $0.category == $1.category && $0.cents == $1.cents }
        }
    }

    /// Next month's budget built from `previous`'s: each limit plus whatever was left unspent under it.
    /// Overspending is not carried forward (a debt would only make next month harder).
    static func rollover(from previous: MonthKey, totalLimit: Int?, limits: [BudgetLimit],
                         transactions: [TransactionRecord], calendar: Calendar = .current) -> BudgetRollover {
        let s = budgetSummary(month: previous, totalLimit: totalLimit, limits: limits, transactions: transactions, calendar: calendar)
        let lines = s.lines.map { (category: $0.category, cents: min(Money.maxCents, $0.limit + max(0, $0.limit - $0.spent))) }
        let total = totalLimit.map { t in min(Money.maxCents, t + max(0, t - s.spent)) }
        return BudgetRollover(totalCents: total, limits: lines)
    }

    // MARK: Shopping

    struct ShoppingSummary: Equatable {
        /// Still to buy, at estimated prices.
        let toBuy: Int
        /// Already bought, at actual price (estimate if none entered).
        let purchased: Int
        let toBuyCount: Int
        let purchasedCount: Int
    }

    static func shoppingSummary(_ items: [ShoppingItem]) -> ShoppingSummary {
        var toBuy = 0, bought = 0, n1 = 0, n2 = 0
        for i in items {
            if i.isPurchased { bought += i.effectiveTotal; n2 += 1 } else { toBuy += i.estimatedTotal; n1 += 1 }
        }
        return ShoppingSummary(toBuy: toBuy, purchased: bought, toBuyCount: n1, purchasedCount: n2)
    }

    static func upcoming(_ planned: [PlannedExpense]) -> [PlannedExpense] {
        planned.filter { !$0.isPaid }.sorted { $0.dueDate < $1.dueDate }
    }
}
