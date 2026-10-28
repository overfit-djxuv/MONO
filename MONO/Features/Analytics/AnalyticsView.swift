import SwiftUI
import SwiftData
import Charts

enum AnalyticsRange: String, CaseIterable, Identifiable {
    case m3 = "3M", m6 = "6M", m12 = "12M", all = "All"
    var id: String { rawValue }
    var months: Int? { switch self { case .m3: 3; case .m6: 6; case .m12: 12; case .all: nil } }
}

struct AnalyticsView: View {
    @Query private var rawTxs: [TransactionRecord]
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query private var rates: [ExchangeRate]
    @Query private var entries: [GoalEntry]
    @Query private var goals: [SavingsGoal]
    @Query private var costs: [TripCost]
    @Query private var monthBudgets: [MonthBudget]
    @Query private var limits: [BudgetLimit]

    @State private var range: AnalyticsRange = .m6
    @State private var budgetMonth = MonthKey(.now)
    @State private var tripID: UUID?

    private var now: MonthKey { MonthKey(.now) }
    /// Every figure here is in the reporting currency: foreign-currency records are converted with your own rates, and transfers are excluded.
    private var txs: [TransactionRecord] { Books(accounts: accounts, rates: rates, transactions: rawTxs, entries: []).reported }

    /// Only months from the first real record onward. Nothing earlier is shown or implied.
    private var monthRange: [MonthKey] {
        guard let first = FinanceEngine.firstRecordMonth(transactions: txs) else { return [] }
        let start = range.months.map { max(first, now.adding(-($0 - 1))) } ?? first
        return start.months(through: now)
    }

    var body: some View {
        let months = FinanceEngine.monthlySummaries(txs, range: monthRange)
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                Picker("Range", selection: $range) {
                    ForEach(AnalyticsRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                if txs.isEmpty && entries.isEmpty {
                    EmptyState(symbol: "chart.xyaxis.line", title: "Nothing to analyse yet",
                               message: "Charts appear as you record transactions and savings. MONO never fills in history it doesn’t have.")
                } else {
                    if !txs.isEmpty {
                        section("Income vs expenses") { IncomeExpenseChart(months: months, height: 200) }.entrance(0)
                        section("Monthly savings rate") { savingsRate(months) }.entrance(1)
                        section("Spending trend") { trend(months) }.entrance(2)
                        section("Where it went") { breakdown }.entrance(3)
                        section("Budget vs actual") { budgetVsActual }.entrance(4)
                    }
                    section("Savings growth") { growth }.entrance(5)
                    section("Trip funding") { tripFunding }.entrance(6)
                    if let first = FinanceEngine.firstRecordMonth(transactions: txs, entries: entries) {
                        Text("Based on records since \(first.title()). Earlier months aren’t estimated or filled in.")
                            .font(.caption).foregroundStyle(Theme.inkTertiary)
                    }
                }
            }
            .padding(.horizontal, Theme.gutter).padding(.top, 8).padding(.bottom, 40)
        }
        .monoScreen()
        .navigationTitle("Analytics")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: title)
            content()
        }
    }

    // MARK: Savings rate

    @ViewBuilder private func savingsRate(_ months: [MonthSummary]) -> some View {
        let rated = months.filter { $0.savingsRate != nil }
        if rated.isEmpty {
            Text("Savings rate needs income. Record income to see it.").font(.subheadline).foregroundStyle(Theme.inkSecondary)
        } else {
            SavingsRateChart(months: rated)
            if rated.count < months.count {
                Text("\(months.count - rated.count) \(months.count - rated.count == 1 ? "month" : "months") without income left out.")
                    .font(.caption).foregroundStyle(Theme.inkTertiary)
            }
        }
    }

    // MARK: Trend

    @ViewBuilder private func trend(_ months: [MonthSummary]) -> some View {
        if months.count < 2 {
            Text("A trend needs at least two months of records.").font(.subheadline).foregroundStyle(Theme.inkSecondary)
        } else {
            SpendingTrendChart(months: months)
        }
    }

    // MARK: Breakdown

    @ViewBuilder private var breakdown: some View {
        if let first = monthRange.first, let last = monthRange.last {
            let slices = FinanceEngine.expensesByCategory(txs, in: first...last)
            if slices.isEmpty {
                Text("No expenses in this period.").font(.subheadline).foregroundStyle(Theme.inkSecondary)
            } else {
                CategoryDonut(slices: slices)
                CategoryBreakdownList(slices: slices)
            }
        }
    }

    // MARK: Budget vs actual

    @ViewBuilder private var budgetVsActual: some View {
        let options = monthRange.reversed() as [MonthKey]
        let summary = FinanceEngine.budgetSummary(month: budgetMonth, totalLimit: monthBudgets.first { $0.monthKey == budgetMonth.string }?.totalCents,
                                                  limits: limits, transactions: txs)
        if !options.isEmpty {
            Picker("Month", selection: $budgetMonth) {
                ForEach(options) { Text($0.title()).tag($0) }
            }
            .pickerStyle(.menu).tint(Theme.accent).padding(.leading, -8)
        }
        if summary.lines.isEmpty {
            Text("No category limits for \(budgetMonth.title()). Set some in Budget to compare.").font(.subheadline).foregroundStyle(Theme.inkSecondary)
        } else {
            BudgetActualChart(lines: summary.lines)
        }
    }

    // MARK: Savings growth

    @ViewBuilder private var growth: some View {
        let pts = FinanceEngine.savingsGrowth(entries: Books(accounts: accounts, rates: rates, transactions: [], entries: []).reportableEntries(goals: goals, entries: entries), through: now)
        if pts.isEmpty {
            Text("Add money to a goal to start tracking savings growth.").font(.subheadline).foregroundStyle(Theme.inkSecondary)
        } else if pts.count == 1 {
            Text("\(Money.format(pts[0].cents)) saved so far. Growth appears once there is more than one month of history.")
                .font(.subheadline).foregroundStyle(Theme.inkSecondary)
        } else {
            SavingsGrowthChart(points: pts, height: 170)
        }
    }

    // MARK: Trip funding

    @ViewBuilder private var tripFunding: some View {
        let trips = goals.filter { $0.kind == .trip }
        if trips.isEmpty {
            Text("Plan a trip in Goals to see its funding progress.").font(.subheadline).foregroundStyle(Theme.inkSecondary)
        } else {
            let selected = trips.first { $0.id == tripID } ?? trips[0]
            if trips.count > 1 {
                Picker("Trip", selection: Binding(get: { selected.id }, set: { tripID = $0 })) {
                    ForEach(trips) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.segmented)
            }
            TripFundingChart(goal: selected, costs: costs, entries: entries)
        }
    }
}

// MARK: - Chart views

struct SavingsRateChart: View {
    let months: [MonthSummary]
    @State private var selected: Date?

    var body: some View {
        let sel = selected.flatMap { d in months.first { $0.month == MonthKey(d) } }
        Chart {
            ForEach(months) { m in
                BarMark(x: .value("Month", m.month.start(), unit: .month), y: .value("Rate", (m.savingsRate ?? 0) * 100), width: .ratio(0.6))
                    .foregroundStyle((m.savingsRate ?? 0) >= 0 ? Theme.accent : Theme.danger)
                    .cornerRadius(2)
            }
            RuleMark(y: .value("Zero", 0)).foregroundStyle(Theme.inkTertiary).lineStyle(StrokeStyle(lineWidth: 0.5))
            if let s = sel {
                RuleMark(x: .value("Month", s.month.start(), unit: .month)).foregroundStyle(Theme.line)
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        ChartTip(title: s.month.title(), lines: [("Savings rate", "\(Int(((s.savingsRate ?? 0) * 100).rounded()))%", Theme.accent),
                                                                  ("Saved", Money.format(s.net, signed: true), Theme.inkSecondary)])
                    }
            }
        }
        .chartXSelection(value: $selected)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Theme.line)
                AxisValueLabel { Text("\(Int(v.as(Double.self) ?? 0))%").font(.caption2).foregroundStyle(Theme.inkTertiary) }
            }
        }
        .monoMonthAxis(count: months.count)
        .frame(height: 160)
        .accessibilityElement()
        .accessibilityLabel("Monthly savings rate")
        .accessibilityValue(months.map { "\($0.month.title()): \(Int((($0.savingsRate ?? 0) * 100).rounded())) percent" }.joined(separator: ". "))
    }
}

struct SpendingTrendChart: View {
    let months: [MonthSummary]
    @State private var selected: Date?

    var body: some View {
        let avg = months.map(\.expense).reduce(0, +) / max(months.count, 1)
        let sel = selected.flatMap { d in months.first { $0.month == MonthKey(d) } }
        Chart {
            ForEach(months) { m in
                LineMark(x: .value("Month", m.month.start(), unit: .month), y: .value("Spent", m.expense.rm))
                    .foregroundStyle(Theme.ink).lineStyle(StrokeStyle(lineWidth: 1.75, lineCap: .round)).interpolationMethod(.monotone)
                PointMark(x: .value("Month", m.month.start(), unit: .month), y: .value("Spent", m.expense.rm))
                    .foregroundStyle(Theme.ink).symbolSize(20)
            }
            RuleMark(y: .value("Average", avg.rm))
                .foregroundStyle(Theme.accent).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .annotation(position: .top, alignment: .leading) {
                    Text("avg \(Money.formatWhole(avg))").font(.caption2).foregroundStyle(Theme.accent)
                }
            if let s = sel {
                RuleMark(x: .value("Month", s.month.start(), unit: .month)).foregroundStyle(Theme.line)
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        ChartTip(title: s.month.title(), lines: [("Spent", Money.format(s.expense), Theme.ink)])
                    }
            }
        }
        .chartXSelection(value: $selected)
        .monoYAxis()
        .monoMonthAxis(count: months.count)
        .frame(height: 170)
        .accessibilityElement()
        .accessibilityLabel("Monthly spending trend")
        .accessibilityValue(months.map { "\($0.month.title()): \(Money.format($0.expense))" }.joined(separator: ". "))
    }
}

struct BudgetActualChart: View {
    let lines: [BudgetLine]

    var body: some View {
        Chart {
            ForEach(lines) { l in
                BarMark(x: .value("Amount", l.limit.rm), y: .value("Category", l.category), height: .ratio(0.5))
                    .foregroundStyle(by: .value("Series", "Budget")).position(by: .value("Series", "Budget"))
                BarMark(x: .value("Amount", l.spent.rm), y: .value("Category", l.category), height: .ratio(0.5))
                    .foregroundStyle(by: .value("Series", "Spent")).position(by: .value("Series", "Spent"))
                    .annotation(position: .trailing, spacing: 4) {
                        if l.overBy > 0 { Text("+\(Money.compact(l.overBy.rm))").font(.caption2).foregroundStyle(Theme.danger) }
                    }
            }
        }
        .chartForegroundStyleScale(["Budget": Theme.line.opacity(1), "Spent": Theme.accent])
        .chartLegend(position: .bottom, alignment: .leading)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { v in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Theme.line)
                AxisValueLabel { Text(Money.compact(v.as(Double.self) ?? 0)).font(.caption2).foregroundStyle(Theme.inkTertiary) }
            }
        }
        .chartYAxis { AxisMarks { _ in AxisValueLabel().font(.caption).foregroundStyle(Theme.ink) } }
        .frame(height: CGFloat(lines.count) * 54 + 40)
        .accessibilityElement()
        .accessibilityLabel("Budget versus actual spending")
        .accessibilityValue(lines.map { "\($0.category): spent \(Money.format($0.spent)) of \(Money.format($0.limit))" }.joined(separator: ". "))
    }
}

struct TripFundingChart: View {
    let goal: SavingsGoal
    let costs: [TripCost]
    let entries: [GoalEntry]

    private struct Point: Identifiable { let id = UUID(); let date: Date; let cents: Int; let series: String }

    var body: some View {
        let plan = SavingsPlanner.plan(for: goal, costs: costs, entries: entries)
        let mine = entries.filter { $0.goalID == goal.id }
        let hist = FinanceEngine.savingsGrowth(entries: mine, through: MonthKey(.now))
        var pts = hist.map { Point(date: $0.month.start(), cents: $0.cents, series: "Saved") }
        if let d = goal.deadline, goal.plannedMonthlyCents > 0 {
            pts.append(Point(date: .now, cents: plan.saved, series: "Planned"))
            for (i, date) in SavingsPlanner.contributionDates(after: .now, through: d, day: goal.contributionDay).enumerated() {
                pts.append(Point(date: date, cents: plan.saved + (i + 1) * goal.plannedMonthlyCents, series: "Planned"))
            }
        }
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(goal.money(plan.saved)) of \(goal.money(plan.target))").font(.figure(15)).foregroundStyle(Theme.ink)
                Spacer()
                StatusChip(text: plan.statusText, tint: plan.statusTint)
            }
            ProgressLine(value: plan.percentFunded)
            if plan.target > 0 && pts.count >= 2 {
                Chart {
                    ForEach(pts) { p in
                        LineMark(x: .value("Date", p.date), y: .value("Amount", p.cents.rm), series: .value("Series", p.series))
                            .foregroundStyle(by: .value("Series", p.series))
                            .lineStyle(StrokeStyle(lineWidth: 1.75, lineCap: .round, dash: p.series == "Planned" ? [4, 4] : []))
                    }
                    RuleMark(y: .value("Target", plan.target.rm)).foregroundStyle(Theme.warning)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("Target \(goal.money(plan.target))").font(.caption2).foregroundStyle(Theme.warning)
                        }
                }
                .chartForegroundStyleScale(["Saved": Theme.accent, "Planned": Theme.inkSecondary])
                .chartLegend(position: .bottom, alignment: .leading)
                .monoYAxis()
                .frame(height: 170)
                Text("Dashed line is your planned contributions, not a forecast of what will happen.")
                    .font(.caption).foregroundStyle(Theme.inkTertiary)
            } else if plan.target > 0 {
                Text("Add money or a monthly plan to draw the funding line.").font(.subheadline).foregroundStyle(Theme.inkSecondary)
            }
        }
    }
}
