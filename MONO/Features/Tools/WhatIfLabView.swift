import SwiftUI
import SwiftData
import Charts

/// A separate space for hypotheticals. Nothing here is a transaction and nothing is applied to your real records.
struct WhatIfLabView: View {
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query private var rates: [ExchangeRate]
    @Query private var txs: [TransactionRecord]
    @Query private var entries: [GoalEntry]
    @Query private var goals: [SavingsGoal]
    @Query private var costs: [TripCost]
    @Query private var monthBudgets: [MonthBudget]
    @AppStorage("openingBalanceCents") private var legacyOpening = 0

    private let store = WhatIfStore.shared
    @State private var selected: UUID?
    @State private var draft = WhatIf.Scenario()
    @State private var incomeText = ""
    @State private var costText = ""
    @State private var overrideOn = false
    @State private var overrideText = ""
    @State private var oneTimeText = ""
    @State private var extraText = ""

    private var books: Books { Books(accounts: accounts, rates: rates, transactions: txs, entries: entries, legacyOpening: legacyOpening) }

    private var baseline: WhatIf.Baseline {
        let b = books
        let lines = goals.compactMap { g -> WhatIf.GoalLine? in
            let plan = SavingsPlanner.plan(for: g, costs: costs, entries: entries)
            guard plan.remaining > 0, let remaining = b.converter.convert(plan.remaining, from: g.currency) else { return nil }
            return WhatIf.GoalLine(name: g.name, remaining: remaining, monthlyPace: PurchaseSimulator.monthlyPace(of: g, books: b))
        }
        let month = MonthKey(.now)
        return WhatIf.baseline(b.reported, now: .now, startingCash: b.overview.total, goals: lines,
                               budgetTotal: FinanceEngine.budgetSummary(month: month, totalLimit: monthBudgets.first { $0.monthKey == month.string }?.totalCents,
                                                                         limits: [], transactions: []).total)
    }

    var body: some View {
        let base = baseline
        ScrollView {
            VStack(spacing: 16) {
                Callout(text: "A sandbox. Scenarios are assumptions kept on this iPhone; nothing here is recorded or applied to your real money.", tone: .info, symbol: "flask")
                planCard(base)
                scenarioPicker
                if selected != nil {
                    editor(base)
                    results(base)
                } else {
                    Text("Create a scenario to compare it with your current plan.").font(.footnote).foregroundStyle(Theme.inkSecondary)
                }
            }
            .padding(.horizontal, Theme.gutter).padding(.vertical, 8).padding(.bottom, 28)
        }
        .monoScreen()
        .navigationTitle("What-if lab")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if selected == nil, let s = store.scenarios.first { choose(s) } }
    }

    // MARK: Current plan

    private func planCard(_ b: WhatIf.Baseline) -> some View {
        let plan = WhatIf.project(b)
        return VStack(alignment: .leading, spacing: 10) {
            HStack { SectionHeader(title: "Your current plan"); Spacer(); badge("Based on your records") }
            row("Income each month", Money.format(plan.monthlyIncome))
            row("Spending each month", Money.format(plan.monthlySpending))
            row("Saved for goals each month", Money.format(plan.monthlyGoalSavings))
            Hairline()
            row("Left over each month", Money.format(plan.monthlySurplus), bold: true, warn: plan.monthlySurplus < 0)
            Text("Income and spending are \(b.basis). Starting cash is \(Money.format(b.startingCash)).").font(.caption).foregroundStyle(Theme.inkSecondary)
        }
        .glass(padding: 18)
    }

    private func badge(_ t: String) -> some View {
        Text(t).font(.caption2.weight(.semibold)).foregroundStyle(Theme.inkSecondary).padding(.vertical, 2).padding(.horizontal, 8).background(Theme.accentSoft, in: Capsule())
    }

    private func row(_ l: String, _ v: String, bold: Bool = false, warn: Bool = false) -> some View {
        HStack { Text(l).font(.subheadline).foregroundStyle(Theme.inkSecondary); Spacer()
            Text(v).font(.figure(15, weight: bold ? .semibold : .regular)).foregroundStyle(warn ? Theme.danger : Theme.ink) }
    }

    // MARK: Scenarios

    private var scenarioPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(store.scenarios) { s in
                    Button { choose(s) } label: {
                        Text(s.name).font(.footnote.weight(.medium)).lineLimit(1)
                            .padding(.vertical, 8).padding(.horizontal, 14)
                            .background(selected == s.id ? Theme.accent : Theme.accentSoft, in: Capsule())
                            .foregroundStyle(selected == s.id ? Theme.onPrimary : Theme.accent)
                    }.buttonStyle(PressableStyle())
                }
                if store.scenarios.count < WhatIfStore.maxScenarios {
                    Button { addScenario() } label: { Label("New scenario", systemImage: "plus").font(.footnote.weight(.medium))
                        .padding(.vertical, 8).padding(.horizontal, 14).overlay(Capsule().strokeBorder(Theme.accent.opacity(0.5), lineWidth: 1)).foregroundStyle(Theme.accent) }
                        .buttonStyle(PressableStyle())
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func choose(_ s: WhatIf.Scenario) {
        selected = s.id; draft = s
        incomeText = ""; costText = Money.editable(s.newMonthlyCost)
        overrideOn = s.spendingOverride != nil; overrideText = Money.editable(s.spendingOverride ?? 0)
        oneTimeText = Money.editable(s.oneTimeExpense); extraText = Money.editable(s.extraGoalMonthly)
    }

    private func addScenario() {
        var s = WhatIf.Scenario(); s.name = "Scenario \(store.scenarios.count + 1)"
        store.upsert(s); choose(s)
    }

    private func save() { store.upsert(draft) }

    // MARK: Editor

    private func editor(_ b: WhatIf.Baseline) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { SectionHeader(title: "Assumptions"); Spacer()
                Button("Reset") { var fresh = WhatIf.Scenario(); fresh.id = draft.id; fresh.name = draft.name; draft = fresh; choose(fresh); save() }
                    .font(.footnote.weight(.medium)).foregroundStyle(Theme.accent).buttonStyle(PressableStyle()) }
            TextField("Name", text: $draft.name).onChange(of: draft.name) { _, _ in save() }
            Hairline()
            VStack(alignment: .leading, spacing: 4) {
                HStack { Text("Income").font(.subheadline); Spacer()
                    Text(draft.incomeChangePercent == 0 ? "no change" : String(format: "%+.0f%%", draft.incomeChangePercent)).font(.figure(14)).foregroundStyle(Theme.inkSecondary) }
                Slider(value: $draft.incomeChangePercent, in: -60...40, step: 5).tint(Theme.accent).onChange(of: draft.incomeChangePercent) { _, _ in save() }
            }
            Hairline()
            HStack { Text("New monthly cost"); AmountField(text: $costText).onChange(of: costText) { _, v in draft.newMonthlyCost = Money.parse(v) ?? 0; save() } }
            Toggle("Change monthly spending to a set amount", isOn: $overrideOn).tint(Theme.accent)
                .onChange(of: overrideOn) { _, on in draft.spendingOverride = on ? (Money.parse(overrideText) ?? b.monthlySpending) : nil
                    if on && overrideText.isEmpty { overrideText = Money.editable(b.monthlySpending) }; save() }
            if overrideOn {
                HStack { Text("Spend each month"); AmountField(text: $overrideText).onChange(of: overrideText) { _, v in draft.spendingOverride = Money.parse(v) ?? 0; save() } }
            }
            Hairline()
            HStack { Text("One-time expense"); AmountField(text: $oneTimeText).onChange(of: oneTimeText) { _, v in draft.oneTimeExpense = Money.parse(v) ?? 0; save() } }
            if draft.oneTimeExpense > 0 {
                Stepper("In month \(draft.oneTimeMonth)", value: $draft.oneTimeMonth, in: 1...12).onChange(of: draft.oneTimeMonth) { _, _ in save() }
            }
            if !b.goals.isEmpty {
                Hairline()
                Picker("Save more for", selection: Binding(get: { draft.extraGoalName ?? "" }, set: { draft.extraGoalName = $0.isEmpty ? nil : $0; save() })) {
                    Text("No goal").tag(""); ForEach(b.goals) { Text($0.name).tag($0.name) }
                }
                if draft.extraGoalName != nil {
                    HStack { Text("Extra each month"); AmountField(text: $extraText).onChange(of: extraText) { _, v in draft.extraGoalMonthly = Money.parse(v) ?? 0; save() } }
                }
            }
            Button("Delete scenario", role: .destructive) { store.delete(draft.id); selected = nil; if let n = store.scenarios.first { choose(n) } }
                .font(.footnote)
        }
        .glass(padding: 18)
    }

    // MARK: Results

    private struct Point: Identifiable { let id = UUID(); let month: Int; let cents: Int; let series: String }

    private func results(_ b: WhatIf.Baseline) -> some View {
        let current = WhatIf.project(b), what = WhatIf.project(b, scenario: draft)
        let points = current.balances.enumerated().map { Point(month: $0.offset, cents: $0.element, series: "Current plan") }
                   + what.balances.enumerated().map { Point(month: $0.offset, cents: $0.element, series: draft.name) }
        let diff = what.endingBalance - current.endingBalance
        return VStack(alignment: .leading, spacing: 12) {
            HStack { SectionHeader(title: "In 12 months"); Spacer(); badge("Projection") }
            Chart(points) { p in
                LineMark(x: .value("Month", p.month), y: .value("Cash", p.cents.rm), series: .value("Series", p.series))
                    .foregroundStyle(by: .value("Series", p.series)).interpolationMethod(.monotone)
            }
            .chartForegroundStyleScale([ "Current plan": Theme.inkTertiary, draft.name: Theme.accent ])
            .chartYAxis { AxisMarks(position: .leading) { v in AxisGridLine(); AxisValueLabel { Text(Money.compact(v.as(Double.self) ?? 0)).font(.caption2) } } }
            .chartXAxis { AxisMarks(values: [0, 3, 6, 9, 12]) { v in AxisValueLabel { Text(v.as(Int.self).map { $0 == 0 ? "Now" : "\($0)m" } ?? "").font(.caption2) } } }
            .frame(height: 170).hidesAmounts()
            Text(diff == 0 ? "No difference from your current plan."
                           : "You’d have \(Money.format(abs(diff))) \(diff > 0 ? "more" : "less") than your current plan: \(Money.format(what.endingBalance)) instead of \(Money.format(current.endingBalance)).")
                .font(.subheadline.weight(.medium)).foregroundStyle(diff < 0 ? Theme.warning : Theme.ink)
            Hairline()
            compare("Left over each month", Money.format(current.monthlySurplus), Money.format(what.monthlySurplus), bad: what.monthlySurplus < current.monthlySurplus)
            compare("Spending each month", Money.format(current.monthlySpending), Money.format(what.monthlySpending), bad: what.monthlySpending > current.monthlySpending)
            if let bt = b.budgetTotal {
                compare("Against your \(Money.format(bt)) budget", Money.format(current.monthlySpending - bt, signed: true),
                        Money.format(what.monthlySpending - bt, signed: true), bad: what.monthlySpending > bt)
            }
            compare("Lowest cash", Money.format(current.lowestBalance), Money.format(what.lowestBalance), bad: what.lowestBalance < 0)
            if let m = what.runsOutInMonth { Callout(text: "In this scenario your cash runs out in month \(m) (about \(monthName(m))).", tone: .danger) }
            let outlook = WhatIf.goalOutlook(b, scenario: draft, now: .now)
            if !outlook.isEmpty {
                Hairline()
                SectionHeader(title: "Goals finish")
                ForEach(outlook) { g in
                    HStack {
                        Text(g.name).font(.subheadline).foregroundStyle(Theme.ink)
                        Spacer()
                        Text(g.baselineDate.map { $0.formatted(.dateTime.month(.abbreviated).year()) } ?? "no plan").font(.caption).foregroundStyle(Theme.inkSecondary)
                        if g.scenarioDate != g.baselineDate {
                            Image(systemName: "arrow.right").font(.caption2).foregroundStyle(Theme.inkTertiary)
                            Text(g.scenarioDate.map { $0.formatted(.dateTime.month(.abbreviated).year()) } ?? "no plan").font(.figure(13, weight: .medium)).foregroundStyle(Theme.accent)
                        }
                    }
                }
            }
            Text("Based on \(b.basis). Real life will differ; this just shows the effect of your assumptions.").font(.caption).foregroundStyle(Theme.inkSecondary)
        }
        .glass(padding: 18)
    }

    private func monthName(_ offset: Int) -> String {
        (Calendar.current.date(byAdding: .month, value: offset, to: .now) ?? .now).formatted(.dateTime.month(.wide).year())
    }

    private func compare(_ label: String, _ a: String, _ b: String, bad: Bool) -> some View {
        HStack {
            Text(label).font(.subheadline).foregroundStyle(Theme.inkSecondary).lineLimit(2)
            Spacer()
            Text(a).font(.figure(13)).foregroundStyle(Theme.inkSecondary)
            Image(systemName: "arrow.right").font(.caption2).foregroundStyle(Theme.inkTertiary)
            Text(b).font(.figure(14, weight: .medium)).foregroundStyle(bad ? Theme.warning : Theme.ink)
        }
    }
}
