import Foundation

/// A sandbox for "what if?". It projects the next months from your recent averages and compares a hypothetical scenario with
/// your current plan. It reads your records and never writes to them: a scenario is only a set of assumptions.
enum WhatIf {
    struct GoalLine: Equatable, Identifiable {
        var name: String
        var remaining: Int
        /// What your plan puts toward this goal each month (reporting currency).
        var monthlyPace: Int
        var id: String { name }
    }

    struct Baseline: Equatable {
        var monthlyIncome: Int
        var monthlySpending: Int
        /// Money leaving your accounts for goals each month under your current plans.
        var monthlyGoalSavings: Int
        var startingCash: Int
        var budgetTotal: Int?
        var goals: [GoalLine]
        /// How the income and spending figures were worked out, shown beside them.
        var basis: String
        var basisMonths: Int
    }

    struct Scenario: Codable, Equatable, Identifiable {
        var id = UUID()
        var name = "My scenario"
        /// −100…+100. −20 means income is a fifth lower every month.
        var incomeChangePercent = 0.0
        var incomeChangeAmount = 0
        /// A new recurring cost each month (a new subscription, higher rent…).
        var newMonthlyCost = 0
        /// Replace normal monthly spending with this amount (a tighter or looser budget). nil keeps your current spending.
        var spendingOverride: Int? = nil
        var oneTimeExpense = 0
        /// Which month (1 = next month) the one-time expense happens in.
        var oneTimeMonth = 1
        var extraGoalName: String? = nil
        var extraGoalMonthly = 0

        var isUnchanged: Bool {
            incomeChangePercent == 0 && incomeChangeAmount == 0 && newMonthlyCost == 0 && spendingOverride == nil
                && oneTimeExpense == 0 && (extraGoalName == nil || extraGoalMonthly == 0)
        }
    }

    struct GoalOutlook: Equatable, Identifiable {
        var name: String
        var baselineDate: Date?
        var scenarioDate: Date?
        var id: String { name }
    }

    struct Projection: Equatable {
        /// Cash at the start (index 0) and after each month.
        var balances: [Int]
        var monthlyIncome: Int
        var monthlySpending: Int
        var monthlyGoalSavings: Int
        var monthlySurplus: Int { monthlyIncome - monthlySpending - monthlyGoalSavings }
        var endingBalance: Int { balances.last ?? 0 }
        var lowestBalance: Int { balances.min() ?? 0 }
        /// The first month the money would run out (1 = next month), or nil if it never does within the projection.
        var runsOutInMonth: Int? { balances.dropFirst().firstIndex { $0 < 0 }.map { $0 } }
    }

    // MARK: Baseline

    /// Typical month from your own records: the average of up to the last three COMPLETED months you have records for.
    /// With none yet, it falls back to this month so far and says so.
    static func baseline(_ txs: [TransactionRecord], now: Date, startingCash: Int, goals: [GoalLine], budgetTotal: Int?,
                         calendar: Calendar = .current) -> Baseline {
        let cur = MonthKey(now, calendar: calendar)
        let first = txs.map { MonthKey($0.date, calendar: calendar) }.min()
        let completed = (1...3).map { cur.adding(-$0) }.filter { m in first.map { $0 <= m } ?? false }
        let months = completed.isEmpty ? [cur] : completed
        var income = 0, spending = 0
        for m in months { let t = FinanceEngine.totals(txs, in: m, calendar: calendar); income += t.income; spending += t.expense }
        let n = max(months.count, 1)
        let basis = completed.isEmpty ? "this month so far (there are no completed months yet)"
                                      : "the average of your last \(completed.count) completed \(completed.count == 1 ? "month" : "months")"
        return Baseline(monthlyIncome: income / n, monthlySpending: spending / n, monthlyGoalSavings: goals.reduce(0) { $0 + $1.monthlyPace },
                        startingCash: startingCash, budgetTotal: budgetTotal, goals: goals, basis: basis, basisMonths: completed.count)
    }

    // MARK: Projection

    static func project(_ b: Baseline, scenario s: Scenario? = nil, months: Int = 12) -> Projection {
        let n = max(months, 1)
        let scenario = s ?? Scenario()
        let income = Int((Double(b.monthlyIncome) * (1 + scenario.incomeChangePercent / 100)).rounded()) + scenario.incomeChangeAmount
        let spending = (scenario.spendingOverride ?? b.monthlySpending) + scenario.newMonthlyCost
        let goalSavings = b.monthlyGoalSavings + (scenario.extraGoalName == nil ? 0 : max(scenario.extraGoalMonthly, 0))
        var balances = [b.startingCash]
        for m in 1...n {
            var next = balances[m - 1] + max(income, 0) - spending - goalSavings
            if scenario.oneTimeExpense > 0 && scenario.oneTimeMonth == m { next -= scenario.oneTimeExpense }
            balances.append(next)
        }
        return Projection(balances: balances, monthlyIncome: max(income, 0), monthlySpending: spending, monthlyGoalSavings: goalSavings)
    }

    /// When each goal finishes at its monthly pace, with and without the scenario's extra saving.
    static func goalOutlook(_ b: Baseline, scenario s: Scenario, now: Date, calendar: Calendar = .current) -> [GoalOutlook] {
        func finish(_ remaining: Int, _ pace: Int) -> Date? {
            guard remaining > 0, pace > 0 else { return nil }
            return calendar.date(byAdding: .month, value: ceilDiv(remaining, pace), to: calendar.startOfDay(for: now))
        }
        return b.goals.filter { $0.remaining > 0 }.map { g in
            let extra = (s.extraGoalName == g.name) ? max(s.extraGoalMonthly, 0) : 0
            return GoalOutlook(name: g.name, baselineDate: finish(g.remaining, g.monthlyPace), scenarioDate: finish(g.remaining, g.monthlyPace + extra))
        }
    }
}

/// Scenarios live only on this iPhone, in the app's own storage.
@Observable
final class WhatIfStore {
    static let shared = WhatIfStore()
    static let key = "whatIfScenarios.v1"
    static let maxScenarios = 3
    private let defaults: UserDefaults
    private(set) var scenarios: [WhatIf.Scenario]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        scenarios = (defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([WhatIf.Scenario].self, from: $0) }) ?? []
    }

    func reload() { scenarios = (defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([WhatIf.Scenario].self, from: $0) }) ?? [] }

    func upsert(_ s: WhatIf.Scenario) {
        if let i = scenarios.firstIndex(where: { $0.id == s.id }) { scenarios[i] = s }
        else if scenarios.count < Self.maxScenarios { scenarios.append(s) }
        persist()
    }
    func delete(_ id: UUID) { scenarios.removeAll { $0.id == id }; persist() }
    func removeAll() { scenarios = []; persist() }
    private func persist() { if let d = try? JSONEncoder().encode(scenarios) { defaults.set(d, forKey: Self.key) } }
}
