import Foundation

/// A report on one month, worked out entirely from your records on this device. Every number is actual unless it is labelled an estimate,
/// and every observation is a fact computed from your data, never advice.
///
/// Formulas:
///   Net cash flow  = income − expenses            (transfers between your accounts and money moved into goals are not counted)
///   Savings rate   = net cash flow ÷ income
///   Moved to goals = money put into goals − money taken back out (a transfer to savings, not an expense)
enum MonthlyReview {
    struct CategorySlice: Equatable, Identifiable {
        let category: String
        let cents: Int
        let share: Double
        var id: String { category }
    }

    struct GoalProgress: Equatable, Identifiable {
        let name: String
        let movedThisMonth: Int
        let saved: Int
        let target: Int
        var percent: Double { target > 0 ? min(Double(saved) / Double(target), 1) : 0 }
        var id: String { name }
    }

    struct Comparison: Equatable {
        let previous: MonthKey
        /// Fewer than the previous month's full length: the month is still in progress, so equal numbers of days are compared.
        let days: Int
        let isPartial: Bool
        let income: Int, previousIncome: Int
        let expense: Int, previousExpense: Int
        let categoryShifts: [Insights.CategoryShift]
        var net: Int { income - expense }
        var previousNet: Int { previousIncome - previousExpense }
    }

    struct Recurring: Equatable {
        /// Payments you confirmed this month, and what they came to.
        let paidCount: Int
        let paidTotal: Int
        let activeCount: Int
        /// Estimate: what active subscriptions and bills cost in a typical month.
        let monthlyEstimate: Int
    }

    struct Commitment: Equatable, Identifiable {
        let title: String
        let date: Date
        let cents: Int
        let isSubscription: Bool
        var id: String { "\(title)|\(date.timeIntervalSince1970)|\(cents)" }
    }

    struct Review: Equatable {
        let month: MonthKey
        let isComplete: Bool
        /// Days the month has covered so far (all of them once it is complete).
        let daysCovered: Int
        let income: Int
        let expense: Int
        var net: Int { income - expense }
        let movedToGoals: Int
        let savingsRate: Double?
        let transactionCount: Int
        let categories: [CategorySlice]
        let budget: BudgetSummary?
        let largest: [TransactionRecord]
        let comparison: Comparison?
        let goals: [GoalProgress]
        let recurring: Recurring
        /// Only for the month in progress: what is due in the next 30 days.
        let upcoming: [Commitment]
        let patterns: [String]
        let worthALook: [String]
    }

    static func make(month: MonthKey, now: Date, txs: [TransactionRecord], goalMoves: [(goal: String, cents: Int)], goalProgress: [GoalProgress],
                     budget: BudgetSummary?, recurring: Recurring, upcoming: [Commitment], format: (Int) -> String,
                     calendar: Calendar = .current) -> Review {
        let current = MonthKey(now, calendar: calendar)
        let inMonth = txs.filter { MonthKey($0.date, calendar: calendar) == month && $0.kind != .transfer }
        let income = inMonth.filter { $0.kind == .income }.reduce(0) { $0 + $1.amountCents }
        let expenses = inMonth.filter { $0.kind == .expense }
        let expense = expenses.reduce(0) { $0 + $1.amountCents }
        let complete = month < current
        let days = complete ? month.daysInMonth(calendar: calendar) : (month == current ? calendar.component(.day, from: now) : 0)

        var sums: [String: Int] = [:]
        for t in expenses { sums[t.category, default: 0] += t.amountCents }
        let categories = sums.map { CategorySlice(category: $0.key, cents: $0.value, share: expense > 0 ? Double($0.value) / Double(expense) : 0) }
            .sorted { $0.cents != $1.cents ? $0.cents > $1.cents : $0.category < $1.category }

        // Compare with the previous month: the whole of each once the month is finished, the same number of days while it is in progress.
        var comparison: Comparison?
        let prev = month.adding(-1)
        if txs.contains(where: { MonthKey($0.date, calendar: calendar) <= prev }) {
            let through = complete ? 31 : min(days, prev.daysInMonth(calendar: calendar))
            func sums(_ m: MonthKey) -> (income: Int, expense: Int, byCategory: [String: Int]) {
                var i = 0, e = 0, cats: [String: Int] = [:]
                for t in txs where t.kind != .transfer && MonthKey(t.date, calendar: calendar) == m && calendar.component(.day, from: t.date) <= through {
                    if t.kind == .income { i += t.amountCents } else { e += t.amountCents; cats[t.category, default: 0] += t.amountCents }
                }
                return (i, e, cats)
            }
            let c = sums(month), p = sums(prev)
            let shifts = Set(c.byCategory.keys).union(p.byCategory.keys)
                .map { Insights.CategoryShift(category: $0, current: c.byCategory[$0] ?? 0, previous: p.byCategory[$0] ?? 0) }
                .sorted { abs($0.delta) != abs($1.delta) ? abs($0.delta) > abs($1.delta) : $0.category < $1.category }
            comparison = Comparison(previous: prev, days: complete ? prev.daysInMonth(calendar: calendar) : through, isPartial: !complete,
                                    income: c.income, previousIncome: p.income, expense: c.expense, previousExpense: p.expense, categoryShifts: shifts)
        }

        let largest = Insights.largestExpenses(inMonth, from: .distantPast, through: .distantFuture, limit: 5)
        let moved = goalMoves.reduce(0) { $0 + $1.cents }

        // Patterns: plain facts about the month.
        var patterns: [String] = []
        if let biggest = expenses.max(by: { $0.amountCents < $1.amountCents }) {
            var perDay: [Date: Int] = [:]
            for t in expenses { perDay[calendar.startOfDay(for: t.date), default: 0] += t.amountCents }
            if let top = perDay.max(by: { $0.value < $1.value }) {
                patterns.append("Your highest-spending day was \(top.key.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))): \(format(top.value)).")
            }
            patterns.append("Your largest single expense was \(format(biggest.amountCents)) on \(biggest.category.isEmpty ? "an expense" : biggest.category).")
            let weekend = expenses.filter { calendar.isDateInWeekend($0.date) }.reduce(0) { $0 + $1.amountCents }
            if expense > 0 { patterns.append("\(Int((Double(weekend) / Double(expense) * 100).rounded()))% of your spending was on weekends.") }
            patterns.append("\(expenses.count) \(expenses.count == 1 ? "expense" : "expenses"), averaging \(format(expense / max(expenses.count, 1))).")
        }
        if let top = categories.first, categories.count > 1 {
            patterns.append("\(top.category) was your biggest category at \(Int((top.share * 100).rounded()))% of spending.")
        }

        // Worth a look: thresholds applied to your own numbers, phrased as observations.
        var look: [String] = []
        if let c = comparison {
            for s in c.categoryShifts where s.delta >= 5_000 && s.previous > 0 && Double(s.delta) / Double(s.previous) >= 0.25 {
                look.append("\(s.category) is up \(format(s.delta)) (\(Int((Double(s.delta) / Double(s.previous) * 100).rounded()))%) on \(c.isPartial ? "the same \(c.days) days of " : "")\(c.previous.shortTitle()).")
                if look.count == 2 { break }
            }
        }
        if let b = budget {
            for l in b.lines where l.spent > l.limit { look.append("\(l.category) went \(format(l.spent - l.limit)) over its budget."); if look.count >= 3 { break } }
        }
        let small = expenses.filter { $0.amountCents < 2_000 }
        if small.count >= 8, expense > 0, Double(small.reduce(0) { $0 + $1.amountCents }) / Double(expense) >= 0.10 {
            look.append("\(small.count) small purchases under \(format(2_000)) added up to \(format(small.reduce(0) { $0 + $1.amountCents })).")
        }
        if recurring.activeCount > 0 && recurring.monthlyEstimate > 0 {
            look.append("\(recurring.activeCount) active subscriptions and bills cost about \(format(recurring.monthlyEstimate)) a month (an estimate).")
        }

        return Review(month: month, isComplete: complete, daysCovered: days, income: income, expense: expense, movedToGoals: moved,
                      savingsRate: FinanceEngine.savingsRate(income: income, expense: expense), transactionCount: inMonth.count,
                      categories: categories, budget: budget, largest: largest, comparison: comparison, goals: goalProgress, recurring: recurring,
                      upcoming: month == current ? upcoming : [], patterns: patterns, worthALook: Array(look.prefix(4)))
    }

    /// Months that have any record, oldest first, through the current month.
    static func months(_ txs: [TransactionRecord], entries: [GoalEntry], now: Date, calendar: Calendar = .current) -> [MonthKey] {
        let cur = MonthKey(now, calendar: calendar)
        guard let first = FinanceEngine.firstRecordMonth(transactions: txs, entries: entries, calendar: calendar), first <= cur else { return [cur] }
        return first.months(through: cur)
    }

    // MARK: Export

    /// Always the real numbers: you asked to export it, so Hide amounts doesn't apply to the file.
    static func markdown(_ r: Review, format: (Int) -> String) -> String {
        var out = ["# \(r.month.title()) review", r.isComplete ? "" : "_In progress: \(r.daysCovered) days so far._", "",
                   "## Summary",
                   "- Income: \(format(r.income))", "- Expenses: \(format(r.expense))", "- Net cash flow: \(format(r.net))",
                   "- Moved to goals: \(format(r.movedToGoals))",
                   "- Savings rate: \(r.savingsRate.map { "\(Int(($0 * 100).rounded()))%" } ?? "n/a")", ""]
        if !r.categories.isEmpty {
            out += ["## Spending by category"] + r.categories.map { "- \($0.category): \(format($0.cents)) (\(Int(($0.share * 100).rounded()))%)" } + [""]
        }
        if let b = r.budget, let total = b.total {
            out += ["## Budget", "- Spent \(format(b.spent)) of \(format(total))"] + b.lines.map { "- \($0.category): \(format($0.spent)) of \(format($0.limit))" } + [""]
        }
        if let c = r.comparison {
            out += ["## Compared with \(c.previous.title())\(c.isPartial ? " (first \(c.days) days)" : "")",
                    "- Income: \(format(c.income)) vs \(format(c.previousIncome))", "- Expenses: \(format(c.expense)) vs \(format(c.previousExpense))", ""]
        }
        if !r.largest.isEmpty { out += ["## Largest expenses"] + r.largest.map { "- \(format($0.amountCents)): \($0.merchant.isEmpty ? ($0.title.isEmpty ? $0.category : $0.title) : $0.merchant) (\($0.date.formatted(.dateTime.day().month(.abbreviated))))" } + [""] }
        if !r.goals.isEmpty { out += ["## Savings goals"] + r.goals.map { "- \($0.name): \(format($0.saved)) of \(format($0.target)) (\(format($0.movedThisMonth)) this month)" } + [""] }
        out += ["## Subscriptions and bills", "- Paid this month: \(r.recurring.paidCount) totalling \(format(r.recurring.paidTotal))",
                "- Typical month (estimate): \(format(r.recurring.monthlyEstimate))", ""]
        if !r.patterns.isEmpty { out += ["## Patterns"] + r.patterns.map { "- \($0)" } + [""] }
        if !r.worthALook.isEmpty { out += ["## Worth a look"] + r.worthALook.map { "- \($0)" } + [""] }
        out += ["_Generated on this iPhone from your own records. Net cash flow = income − expenses; savings rate = net ÷ income._"]
        return out.joined(separator: "\n")
    }

    static func csv(_ r: Review, format: (Int) -> String) -> String {
        func cell(_ s: String) -> String { BackupService.cell(s) }
        var rows = ["section,item,amount,note"]
        rows += [["summary", "Income", format(r.income), ""], ["summary", "Expenses", format(r.expense), ""], ["summary", "Net cash flow", format(r.net), ""],
                 ["summary", "Moved to goals", format(r.movedToGoals), ""]].map { $0.map(cell).joined(separator: ",") }
        rows += r.categories.map { ["category", $0.category, format($0.cents), "\(Int(($0.share * 100).rounded()))%"].map(cell).joined(separator: ",") }
        rows += r.largest.map { ["largest expense", $0.merchant.isEmpty ? ($0.title.isEmpty ? $0.category : $0.title) : $0.merchant, format($0.amountCents),
                                 $0.date.formatted(.dateTime.year().month().day())].map(cell).joined(separator: ",") }
        rows += r.goals.map { ["goal", $0.name, format($0.saved), "target \(format($0.target))"].map(cell).joined(separator: ",") }
        return rows.joined(separator: "\r\n") + "\r\n"
    }
}
