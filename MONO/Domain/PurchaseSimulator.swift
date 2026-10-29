import Foundation

/// "What happens if I buy this?" Everything here is an estimate worked out from your current figures. Nothing is saved or recorded.
enum PurchaseSimulator {
    struct GoalPace: Equatable {
        var name: String
        var priority: Int
        /// What the plan puts toward the goal each month, in the reporting currency.
        var monthlyPace: Int
        var remaining: Int
        var estimatedCompletion: Date?
    }

    struct Context: Equatable {
        var availableCash: Int
        /// Safe to spend with your current settings, and over the next 30 days.
        var safeToSpendNow: Int
        var safeToSpend30Days: Int
        var thirtyDaysFrom: Date
        var monthIncome: Int
        var monthExpense: Int
        var budgetTotal: Int?
        var budgetSpent: Int
        var categoryBudgets: [String: (limit: Int, spent: Int)]
        var goals: [GoalPace]

        static func == (a: Context, b: Context) -> Bool {
            a.availableCash == b.availableCash && a.safeToSpendNow == b.safeToSpendNow && a.safeToSpend30Days == b.safeToSpend30Days
                && a.monthIncome == b.monthIncome && a.monthExpense == b.monthExpense && a.budgetTotal == b.budgetTotal
                && a.budgetSpent == b.budgetSpent && a.goals == b.goals && a.thirtyDaysFrom == b.thirtyDaysFrom
        }
    }

    struct GoalDelay: Equatable, Identifiable {
        var name: String
        /// If the price is taken out of what this goal would have received. nil when the goal has no plan to measure against.
        var delayDays: Int?
        var newEstimate: Date?
        var id: String { name }
    }

    struct BudgetEffect: Equatable {
        var limit: Int
        var remainingBefore: Int
        var remainingAfter: Int
        var goesOver: Bool { remainingAfter < 0 && remainingBefore >= 0 }
        var alreadyOver: Bool { remainingBefore < 0 }
    }

    struct Result: Equatable {
        var price: Int
        var cashBefore: Int, cashAfter: Int
        var safeBefore: Int, safeAfter: Int
        /// How far past your safe-to-spend money this would go (0 if it fits).
        var overSafeBy: Int { max(price - safeBefore, 0) }
        var overall: BudgetEffect?
        var category: BudgetEffect?
        var savingsRateBefore: Double?, savingsRateAfter: Double?
        var goalDelays: [GoalDelay]
        var hoursOfWork: Double?
        var fitsSafeToSpend: Bool { price <= safeBefore }
    }

    struct WaitOutcome: Equatable {
        var date: Date
        /// Safe to spend over the next 30 days, after bills and planned savings that fall due before then.
        var safeToSpend: Int
        var leftAfterBuying: Int
        var stillAffordable: Bool
    }

    static func evaluate(price: Int, category: String?, hourlyRate: Int?, now: Date = .now, context c: Context) -> Result {
        let overall = c.budgetTotal.map { BudgetEffect(limit: $0, remainingBefore: $0 - c.budgetSpent, remainingAfter: $0 - c.budgetSpent - price) }
        let cat: BudgetEffect? = category.flatMap { c.categoryBudgets[$0] }.map {
            BudgetEffect(limit: $0.limit, remainingBefore: $0.limit - $0.spent, remainingAfter: $0.limit - $0.spent - price)
        }
        let rate = { (extra: Int) -> Double? in c.monthIncome > 0 ? Double(c.monthIncome - c.monthExpense - extra) / Double(c.monthIncome) : nil }
        let delays = c.goals.sorted { $0.priority != $1.priority ? $0.priority > $1.priority : $0.name < $1.name }.filter { $0.remaining > 0 }.map { g -> GoalDelay in
            guard g.monthlyPace > 0 else { return GoalDelay(name: g.name, delayDays: nil, newEstimate: nil) }
            let days = Int((Double(price) / Double(g.monthlyPace) * (365.2425 / 12)).rounded())
            return GoalDelay(name: g.name, delayDays: days,
                             newEstimate: g.estimatedCompletion.flatMap { Calendar.current.date(byAdding: .day, value: days, to: $0) })
        }
        let hours = hourlyRate.flatMap { $0 > 0 ? Double(price) / Double($0) : nil }
        return Result(price: price, cashBefore: c.availableCash, cashAfter: c.availableCash - price,
                      safeBefore: c.safeToSpendNow, safeAfter: c.safeToSpendNow - price, overall: overall, category: cat,
                      savingsRateBefore: rate(0), savingsRateAfter: rate(price), goalDelays: delays, hoursOfWork: hours)
    }

    /// Waiting doesn't assume any income: it only looks at what is already committed over the next 30 days.
    static func waiting30Days(price: Int, context c: Context) -> WaitOutcome {
        WaitOutcome(date: c.thirtyDaysFrom, safeToSpend: c.safeToSpend30Days, leftAfterBuying: c.safeToSpend30Days - price,
                    stillAffordable: price <= c.safeToSpend30Days)
    }
}

extension PurchaseSimulator {
    /// What a goal's plan puts toward it per month, in the reporting currency (a weekly plan counts 52 ÷ 12 payments a month).
    static func monthlyPace(of g: SavingsGoal, books: Books) -> Int {
        let perYear = SubscriptionSchedule.timesPerYear(unit: g.frequency == .monthly ? .month : .week, interval: g.frequency == .biweekly ? 2 : 1)
        let perMonth = NSDecimalNumber(decimal: Decimal(g.plannedMonthlyCents) * perYear / 12).intValue
        return books.converter.convert(perMonth, from: g.currency) ?? 0
    }

    /// Gathers the figures from stored data, using the same engines as the rest of the app.
    @MainActor
    static func makeContext(now: Date = .now, books: Books, planned: [PlannedExpense], rules: [RecurringRule], goals: [SavingsGoal],
                            costs: [TripCost], entries: [GoalEntry], categories: [MoneyCategory], limits: [BudgetLimit],
                            monthBudgets: [MonthBudget], reserved: [ReservedFund], config: SafeToSpend.Config,
                            calendar: Calendar = .current) -> Context {
        func safe(_ cfg: SafeToSpend.Config) -> SafeToSpend.Result {
            SafeToSpend.make(now: now, config: cfg, books: books, planned: planned, rules: rules, goals: goals, costs: costs, entries: entries,
                             categories: categories, limits: limits, monthBudgets: monthBudgets, reserved: reserved, calendar: calendar)
        }
        var thirty = config; thirty.horizon = .days(30)
        let month = MonthKey(now, calendar: calendar)
        let totals = FinanceEngine.totals(books.reported, in: month, calendar: calendar)
        let summary = FinanceEngine.budgetSummary(month: month, totalLimit: monthBudgets.first { $0.monthKey == month.string }?.totalCents,
                                                  limits: limits, transactions: books.reported, today: now, calendar: calendar)
        var catBudgets: [String: (limit: Int, spent: Int)] = [:]
        for l in summary.lines { catBudgets[l.category] = (l.limit, l.spent) }
        let paces: [GoalPace] = goals.filter(\.isOngoing).compactMap { g in
            let plan = SavingsPlanner.plan(for: g, costs: costs, entries: entries, today: now, calendar: calendar)
            guard plan.remaining > 0, let remaining = books.converter.convert(plan.remaining, from: g.currency) else { return nil }
            return GoalPace(name: g.name, priority: g.priorityRaw, monthlyPace: monthlyPace(of: g, books: books), remaining: remaining,
                            estimatedCompletion: plan.estimatedCompletion)
        }
        return Context(availableCash: books.overview.total, safeToSpendNow: safe(config).flexible,
                       safeToSpend30Days: safe(thirty).flexible,
                       thirtyDaysFrom: calendar.date(byAdding: .day, value: 30, to: calendar.startOfDay(for: now)) ?? now,
                       monthIncome: totals.income, monthExpense: totals.expense, budgetTotal: summary.total, budgetSpent: summary.spent,
                       categoryBudgets: catBudgets, goals: paces)
    }
}
