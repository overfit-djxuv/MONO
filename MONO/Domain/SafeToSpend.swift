import Foundation

/// "How much can I spend without touching what I've already committed to?"
///
///   safe to spend = money in the chosen accounts
///                 − unpaid bills due before the horizon
///                 − planned savings contributions due before the horizon
///                 − remaining budget for essential categories
///                 − funds you have reserved
///
/// Every figure is in the reporting currency. Nothing here is a forecast of income: only money you already have counts.
enum SafeToSpend {
    struct Config: Codable, Equatable {
        enum Horizon: Codable, Equatable { case endOfMonth, days(Int) }
        var horizon: Horizon = .endOfMonth
        var includeBills = true
        var includeSavings = true
        var includeEssentials = true
        var includeReserved = true
        /// Accounts whose money is left out (a savings account you never spend from, for example).
        var excludedAccountIDs: [UUID] = []

        private static let key = "safeToSpendConfig.v1"
        static func load(_ defaults: UserDefaults = .standard) -> Config {
            guard let d = defaults.data(forKey: key), let c = try? JSONDecoder().decode(Config.self, from: d) else { return Config() }
            return c
        }
        func save(_ defaults: UserDefaults = .standard) {
            if let d = try? JSONEncoder().encode(self) { defaults.set(d, forKey: Self.key) }
        }
    }

    // MARK: Inputs (already expressed in the reporting currency)

    struct AccountMoney: Equatable { var id: UUID; var name: String; var reportingCents: Int? }

    struct Commitment: Equatable {
        enum Source: Equatable { case planned, recurring }
        var title: String
        var amountCents: Int
        var dueDate: Date
        var category: String
        var source: Source
    }

    struct GoalPlan: Equatable {
        var name: String
        var plannedPerContribution: Int
        var remaining: Int
        /// Scheduled contribution dates after today (the caller limits them to the goal's own deadline).
        var dates: [Date]
    }

    struct EssentialBudget: Equatable { var category: String; var limit: Int; var spent: Int }

    // MARK: Output

    struct Item: Identifiable, Equatable {
        var id: String
        var title: String
        var detail: String
        var amountCents: Int
    }

    struct Result: Equatable {
        var horizonEnd: Date
        var horizonDays: Int
        /// ACTUAL money: the included accounts' balances.
        var accountMoney: Int
        var includedAccounts: [AccountMoney]
        /// Accounts left out because their currency has no exchange rate. Their money is not in `accountMoney`.
        var unconvertedAccounts: [String]
        /// PLANNED: money already spoken for, each with the individual items behind it.
        var bills: [Item], savings: [Item], essentials: [Item]
        /// RESERVED: money you set aside by hand.
        var reserved: [Item]
        var billsTotal: Int, savingsTotal: Int, essentialsTotal: Int, reservedTotal: Int
        /// What remains. Negative means your commitments exceed your money.
        var flexible: Int
        var perDay: Int?
        var isShortfall: Bool { flexible < 0 }
    }

    // MARK: Calculation

    static func horizonEnd(_ h: Config.Horizon, now: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        switch h {
        case .days(let n): return calendar.date(byAdding: .day, value: max(n, 1) - 1, to: today) ?? today
        case .endOfMonth:
            let m = MonthKey(today, calendar: calendar)
            return calendar.date(from: DateComponents(year: m.year, month: m.month, day: m.daysInMonth(calendar: calendar))) ?? today
        }
    }

    static func calculate(now: Date, config: Config, accounts: [AccountMoney], commitments: [Commitment], goals: [GoalPlan],
                          essentials: [EssentialBudget], reserved: [(name: String, cents: Int)],
                          calendar: Calendar = .current) -> Result {
        let today = calendar.startOfDay(for: now)
        let end = horizonEnd(config.horizon, now: now, calendar: calendar)
        let horizonDays = max((calendar.dateComponents([.day], from: today, to: end).day ?? 0) + 1, 1)

        // Actual money in the chosen accounts.
        let included = accounts.filter { !config.excludedAccountIDs.contains($0.id) }
        let money = included.reduce(0) { $0 + ($1.reportingCents ?? 0) }
        let unconverted = included.filter { $0.reportingCents == nil }.map(\.name)

        // Bills: anything unpaid due on or before the horizon. Overdue ones still have to be paid, so they count.
        // Paid bills never appear here: paying one already lowered the account balance.
        let dueBills = commitments.filter { calendar.startOfDay(for: $0.dueDate) <= end && $0.amountCents > 0 }
            .sorted { $0.dueDate < $1.dueDate }
        let bills = dueBills.enumerated().map { i, c in
            Item(id: "bill-\(i)", title: c.title.isEmpty ? c.category : c.title,
                 detail: (calendar.startOfDay(for: c.dueDate) < today ? "Overdue · " : "Due ") + c.dueDate.formatted(.dateTime.day().month(.abbreviated)),
                 amountCents: c.amountCents)
        }

        // Planned savings: only contributions still to come before the horizon, never more than the goal still needs.
        // Contributions already made have already left your accounts.
        var savings: [Item] = []
        for (i, g) in goals.enumerated() where g.remaining > 0 && g.plannedPerContribution > 0 {
            let due = g.dates.filter { calendar.startOfDay(for: $0) > today && calendar.startOfDay(for: $0) <= end }.count
            let amount = min(due * g.plannedPerContribution, g.remaining)
            if amount > 0 {
                savings.append(Item(id: "goal-\(i)", title: g.name,
                                    detail: "\(due) \(due == 1 ? "contribution" : "contributions") planned", amountCents: amount))
            }
        }

        // Essentials: what is left of each essential category's budget this month, scaled to the horizon.
        // A bill already counted above is taken out of its own category so the same money isn't held back twice.
        let monthEnd = horizonEnd(.endOfMonth, now: now, calendar: calendar)
        let daysLeftInMonth = max((calendar.dateComponents([.day], from: today, to: monthEnd).day ?? 0) + 1, 1)
        let factor = min(1.0, Double(horizonDays) / Double(daysLeftInMonth))
        var essentialItems: [Item] = []
        for (i, e) in essentials.enumerated() {
            let left = max(e.limit - e.spent, 0)
            let scaled = Int((Double(left) * factor).rounded())
            let alreadyCounted = dueBills.filter { $0.category == e.category }.reduce(0) { $0 + $1.amountCents }
            let amount = max(scaled - alreadyCounted, 0)
            if amount > 0 {
                essentialItems.append(Item(id: "essential-\(i)", title: e.category,
                                           detail: alreadyCounted > 0 ? "Budget left, less bills already counted" : "Budget left this month",
                                           amountCents: amount))
            }
        }

        let reservedItems = reserved.enumerated().filter { $0.element.cents > 0 }.map {
            Item(id: "reserved-\($0.offset)", title: $0.element.name, detail: "Set aside by you", amountCents: $0.element.cents)
        }

        func total(_ items: [Item], _ on: Bool) -> Int { on ? items.reduce(0) { $0 + $1.amountCents } : 0 }
        let billsTotal = total(bills, config.includeBills), savingsTotal = total(savings, config.includeSavings)
        let essentialsTotal = total(essentialItems, config.includeEssentials), reservedTotal = total(reservedItems, config.includeReserved)
        let flexible = money - billsTotal - savingsTotal - essentialsTotal - reservedTotal

        return Result(horizonEnd: end, horizonDays: horizonDays, accountMoney: money, includedAccounts: included,
                      unconvertedAccounts: unconverted, bills: bills, savings: savings, essentials: essentialItems,
                      reserved: reservedItems, billsTotal: billsTotal, savingsTotal: savingsTotal,
                      essentialsTotal: essentialsTotal, reservedTotal: reservedTotal, flexible: flexible,
                      perDay: flexible > 0 ? flexible / horizonDays : nil)
    }
}

// MARK: - Building the inputs from stored data

extension SafeToSpend {
    /// Gathers the inputs from what is stored: balances and exchange rates, unpaid planned expenses, recurring bills that haven't
    /// posted yet, goal schedules, essential categories with this month's budget, and your reserved funds.
    @MainActor
    static func make(now: Date = .now, config: Config, books: Books, planned: [PlannedExpense], rules: [RecurringRule],
                     goals: [SavingsGoal], costs: [TripCost], entries: [GoalEntry], categories: [MoneyCategory],
                     limits: [BudgetLimit], monthBudgets: [MonthBudget], reserved: [ReservedFund],
                     calendar: Calendar = .current) -> Result {
        let end = horizonEnd(config.horizon, now: now, calendar: calendar)
        let accounts = books.accounts.map { AccountMoney(id: $0.id, name: $0.name, reportingCents: books.reportingBalance(of: $0)) }

        var commitments = planned.filter { !$0.isPaid }.map {
            Commitment(title: $0.title, amountCents: $0.amountCents, dueDate: $0.dueDate, category: $0.category, source: .planned)
        }
        // A repeating payment you haven't confirmed yet is still owed: every occurrence up to the horizon counts, overdue ones included.
        // Paused and cancelled payments owe nothing. Amounts are in the paying account's currency, converted with your rates.
        for r in rules where r.status == .active && r.kind == .expense {
            let currency = books.account(r.accountID)?.currency ?? Money.reporting
            guard let amount = books.converter.convert(r.amountCents, from: currency), amount > 0 else { continue }
            for due in r.dueDates(through: end, calendar: calendar) {
                commitments.append(Commitment(title: r.title, amountCents: amount, dueDate: due, category: r.category, source: .recurring))
            }
        }

        var goalPlans: [GoalPlan] = []
        for g in goals where g.isOngoing {
            let plan = SavingsPlanner.plan(for: g, costs: costs, entries: entries, today: now, calendar: calendar)
            guard plan.remaining > 0, g.plannedMonthlyCents > 0,
                  let remaining = books.converter.convert(plan.remaining, from: g.currency),
                  let perContribution = books.converter.convert(g.plannedMonthlyCents, from: g.currency) else { continue }
            let last = min(end, g.deadline.map { calendar.startOfDay(for: $0) } ?? end)
            let dates = SavingsPlanner.schedule(after: now, through: last, frequency: g.frequency, day: g.contributionDay,
                                                anchor: g.scheduleStart, calendar: calendar)
            goalPlans.append(GoalPlan(name: g.name, plannedPerContribution: perContribution, remaining: remaining, dates: dates))
        }

        let month = MonthKey(now, calendar: calendar)
        let summary = FinanceEngine.budgetSummary(month: month, totalLimit: monthBudgets.first { $0.monthKey == month.string }?.totalCents,
                                                  limits: limits, transactions: books.reported, today: now, calendar: calendar)
        let essentialNames = Set(categories.filter { $0.isEssential && $0.kind == .expense }.map(\.name))
        let essentials = summary.lines.filter { essentialNames.contains($0.category) }
            .map { EssentialBudget(category: $0.category, limit: $0.limit, spent: $0.spent) }

        return calculate(now: now, config: config, accounts: accounts, commitments: commitments, goals: goalPlans, essentials: essentials,
                         reserved: reserved.filter(\.isActive).map { ($0.name, $0.amountCents) }, calendar: calendar)
    }
}
