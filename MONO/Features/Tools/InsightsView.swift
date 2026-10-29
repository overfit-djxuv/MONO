import SwiftUI
import SwiftData
import Charts

/// What your own records say about how you spend. No outside service, no guessing: each card says whether it shows
/// what actually happened or an estimate.
struct InsightsView: View {
    @Query private var rawTxs: [TransactionRecord]
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query private var rates: [ExchangeRate]
    @Query private var rules: [RecurringRule]
    @Query private var categories: [MoneyCategory]
    @Query private var limits: [BudgetLimit]
    @Query private var monthBudgets: [MonthBudget]

    private var now: Date { .now }
    private var month: MonthKey { MonthKey(.now) }
    private var books: Books { Books(accounts: accounts, rates: rates, transactions: rawTxs, entries: []) }

    var body: some View {
        let books = self.books, txs = books.reported
        ScrollView {
            VStack(spacing: 16) {
                if txs.isEmpty {
                    EmptyState(symbol: "chart.bar.doc.horizontal", title: "Nothing to analyse yet",
                               message: "Insights appear as you record spending. Everything is worked out on this iPhone from your own records.")
                        .padding(.top, 40)
                } else {
                    thisMonth(txs)
                    weekly(txs)
                    foodAndGroceries(txs)
                    biggest(txs)
                    changes(txs)
                    subscriptions(txs, books)
                    budgetWatch(txs)
                    NavigationLink { AnalyticsView() } label: {
                        ToolRow(symbol: "chart.xyaxis.line", title: "More charts", detail: "Income vs expenses, savings rate, budgets and goal progress.")
                    }.buttonStyle(PressableStyle())
                    if books.skipped > 0 {
                        Text("\(books.skipped) \(books.skipped == 1 ? "record isn’t" : "records aren’t") included: its currency has no exchange rate.")
                            .font(.caption).foregroundStyle(Theme.warning)
                    }
                }
            }
            .padding(.horizontal, Theme.gutter).padding(.vertical, 8).padding(.bottom, 28)
        }
        .monoScreen()
        .navigationTitle("Spending insights")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Cards

    private func card<C: View>(_ title: String, badge: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeader(title: title)
                Spacer()
                Text(badge).font(.caption2.weight(.semibold)).foregroundStyle(Theme.inkSecondary)
                    .padding(.vertical, 2).padding(.horizontal, 8).background(Theme.accentSoft, in: Capsule())
            }
            content()
        }
        .glass(padding: 18)
    }

    private func thisMonth(_ txs: [TransactionRecord]) -> some View {
        let avg = Insights.dailyAverage(txs, month: month, now: now)
        let cmp = Insights.monthToDateComparison(txs, now: now)
        let lastMonth = month.adding(-1).shortTitle()
        return card("This month so far", badge: "Actual") {
            if let avg {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Money.format(avg.averageCents)).font(.figure(30, weight: .light)).foregroundStyle(Theme.ink)
                    Text("a day · \(avg.days) \(avg.days == 1 ? "day" : "days") so far").font(.subheadline).foregroundStyle(Theme.inkSecondary)
                }
            }
            if cmp.previous > 0 || cmp.current > 0 {
                let up = cmp.delta > 0
                Hairline()
                Text("Compared with the first \(cmp.days) \(cmp.days == 1 ? "day" : "days") of \(lastMonth)")
                    .font(.footnote).foregroundStyle(Theme.inkSecondary)
                HStack {
                    Text(cmp.delta == 0 ? "No change" : "\(up ? "+" : "−")\(Money.format(abs(cmp.delta)))")
                        .font(.figure(18)).foregroundStyle(cmp.delta == 0 ? Theme.ink : (up ? Theme.warning : Theme.accent))
                    if let p = cmp.percent { Text("(\(up ? "+" : "−")\(Int((abs(p) * 100).rounded()))%)").font(.footnote).foregroundStyle(Theme.inkSecondary) }
                    Spacer()
                    Text("\(Money.format(cmp.current)) vs \(Money.format(cmp.previous))").font(.caption).foregroundStyle(Theme.inkSecondary)
                }
                ForEach(cmp.categories.filter { $0.delta != 0 }.prefix(3)) { c in
                    HStack {
                        Text(c.category).font(.subheadline).foregroundStyle(Theme.ink)
                        Spacer()
                        Text("\(c.delta > 0 ? "+" : "−")\(Money.format(abs(c.delta)))").font(.figure(14)).foregroundStyle(Theme.inkSecondary)
                    }
                }
            }
        }
    }

    private func weekly(_ txs: [TransactionRecord]) -> some View {
        let pattern = Insights.weekdayPattern(txs, weeks: 8, now: now)
        let top = pattern.max { $0.averageCents < $1.averageCents }
        let names = Calendar.current.shortWeekdaySymbols
        return card("Weekly pattern", badge: "Actual") {
            if let top, top.averageCents > 0 {
                Text("You spend the most on \(Calendar.current.weekdaySymbols[top.weekday - 1])s: about \(Money.format(top.averageCents)).")
                    .font(.subheadline).foregroundStyle(Theme.ink)
                Chart(pattern) { d in
                    BarMark(x: .value("Day", names[d.weekday - 1]), y: .value("Average", d.averageCents.rm))
                        .foregroundStyle(d.weekday == top.weekday ? Theme.accent : Theme.accent.opacity(0.4))
                        .cornerRadius(4)
                }
                .chartYAxis { AxisMarks(position: .leading) { v in AxisValueLabel { Text(Money.compact(v.as(Double.self) ?? 0)).font(.caption2) } } }
                .frame(height: 150).hidesAmounts()
                Text("Average per day over the last 8 weeks (or since your first record).").font(.caption).foregroundStyle(Theme.inkSecondary)
            } else { Text("No spending recorded in this period.").font(.subheadline).foregroundStyle(Theme.inkSecondary) }
        }
    }

    private func foodAndGroceries(_ txs: [TransactionRecord]) -> some View {
        let names = Set(categories.map(\.name)).intersection(["Food", "Groceries"])
        let months = month.adding(-5).months(through: month)
        let totals = Insights.categoryTotals(txs, categories: names, months: months)
        let complete = totals.dropLast().filter { $0.cents > 0 }
        let avg = complete.isEmpty ? 0 : complete.reduce(0) { $0 + $1.cents } / complete.count
        return card("Food & groceries", badge: "Actual") {
            if names.isEmpty {
                Text("Add Food or Groceries categories to track what you spend on eating.").font(.subheadline).foregroundStyle(Theme.inkSecondary)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Money.format(totals.last?.cents ?? 0)).font(.figure(26, weight: .light)).foregroundStyle(Theme.ink)
                    Text("so far in \(month.shortTitle())").font(.subheadline).foregroundStyle(Theme.inkSecondary)
                }
                Chart(totals, id: \.month) { t in
                    BarMark(x: .value("Month", t.month.shortTitle()), y: .value("Spent", t.cents.rm))
                        .foregroundStyle(t.month == month ? Theme.accent.opacity(0.45) : Theme.accent).cornerRadius(4)
                }
                .chartYAxis { AxisMarks(position: .leading) { v in AxisValueLabel { Text(Money.compact(v.as(Double.self) ?? 0)).font(.caption2) } } }
                .frame(height: 140).hidesAmounts()
                Text(avg > 0 ? "Usual month (completed months): \(Money.format(avg)). The lighter bar is this month, not finished yet."
                              : "Completed months will appear here as you go.").font(.caption).foregroundStyle(Theme.inkSecondary)
            }
        }
    }

    private func biggest(_ txs: [TransactionRecord]) -> some View {
        let from = Calendar.current.date(byAdding: .day, value: -30, to: now) ?? now
        let top = Insights.largestExpenses(txs, from: from, through: now, limit: 5)
        return card("Biggest expenses", badge: "Actual") {
            if top.isEmpty { Text("No expenses in the last 30 days.").font(.subheadline).foregroundStyle(Theme.inkSecondary) }
            ForEach(Array(top.enumerated()), id: \.element.id) { i, t in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(t.merchant.isEmpty ? (t.title.isEmpty ? t.category : t.title) : t.merchant).font(.subheadline).foregroundStyle(Theme.ink).lineLimit(1)
                        Text("\(t.category) · \(t.date.short)").font(.caption).foregroundStyle(Theme.inkSecondary)
                    }
                    Spacer()
                    Text(Money.format(t.amountCents)).font(.figure(15)).foregroundStyle(Theme.ink)
                }
                if i < top.count - 1 { Hairline() }
            }
            if !top.isEmpty { Text("The last 30 days.").font(.caption).foregroundStyle(Theme.inkSecondary) }
        }
    }

    private func changes(_ txs: [TransactionRecord]) -> some View {
        let shifts = Insights.habitChanges(txs, now: now)
        return card("What’s changed", badge: "Actual") {
            if let shifts {
                if shifts.isEmpty { Text("Your spending looks the same as before.").font(.subheadline).foregroundStyle(Theme.inkSecondary) }
                ForEach(shifts) { c in
                    HStack {
                        Image(systemName: c.delta > 0 ? "arrow.up.right" : "arrow.down.right").font(.caption.weight(.bold))
                            .foregroundStyle(c.delta > 0 ? Theme.warning : Theme.accent).frame(width: 18)
                        Text(c.category).font(.subheadline).foregroundStyle(Theme.ink)
                        Spacer()
                        Text("\(c.delta > 0 ? "+" : "−")\(Money.format(abs(c.delta)))").font(.figure(15)).foregroundStyle(Theme.ink)
                    }
                }
                Text("The last 3 completed months compared with the 3 before them.").font(.caption).foregroundStyle(Theme.inkSecondary)
            } else {
                Text("This needs six months of records: three completed months to compare with three before them. It will appear on its own.")
                    .font(.subheadline).foregroundStyle(Theme.inkSecondary)
            }
        }
    }

    private func subscriptions(_ txs: [TransactionRecord], _ books: Books) -> some View {
        let active = rules.filter { $0.status == .active && $0.kind == .expense }
        var monthly = 0, annual = 0
        for r in active {
            let cur = books.account(r.accountID)?.currency ?? Money.reporting
            monthly += books.converter.convert(r.monthlyCostEstimate, from: cur) ?? 0
            annual += books.converter.convert(r.annualCostEstimate, from: cur) ?? 0
        }
        let months = month.adding(-5).months(through: month)
        let paid = Insights.scheduledPayments(txs, months: months)
        return card("Subscriptions & bills", badge: "Estimate + actual") {
            if active.isEmpty && paid.allSatisfy({ $0.cents == 0 }) {
                Text("Add subscriptions in Tools to see what they cost each month and year.").font(.subheadline).foregroundStyle(Theme.inkSecondary)
            } else {
                HStack(alignment: .top, spacing: 16) {
                    Metric(label: "Per month (estimate)", value: Money.format(monthly), footnote: "\(active.count) active")
                    Metric(label: "Per year (estimate)", value: Money.format(annual))
                }
                if paid.contains(where: { $0.cents > 0 }) {
                    Chart(paid, id: \.month) { t in
                        BarMark(x: .value("Month", t.month.shortTitle()), y: .value("Paid", t.cents.rm)).foregroundStyle(Theme.accent).cornerRadius(4)
                    }
                    .chartYAxis { AxisMarks(position: .leading) { v in AxisValueLabel { Text(Money.compact(v.as(Double.self) ?? 0)).font(.caption2) } } }
                    .frame(height: 120).hidesAmounts()
                    Text("Bars: payments you confirmed as paid. The figures above are estimates spread evenly from each schedule.")
                        .font(.caption).foregroundStyle(Theme.inkSecondary)
                } else {
                    Text("Confirmed payments will appear here as you mark them paid.").font(.caption).foregroundStyle(Theme.inkSecondary)
                }
                NavigationLink { SubscriptionsView() } label: {
                    Label("Manage subscriptions", systemImage: "arrow.triangle.2.circlepath").font(.footnote.weight(.medium)).foregroundStyle(Theme.accent)
                }.buttonStyle(PressableStyle())
            }
        }
    }

    private func budgetWatch(_ txs: [TransactionRecord]) -> some View {
        let summary = FinanceEngine.budgetSummary(month: month, totalLimit: monthBudgets.first { $0.monthKey == month.string }?.totalCents,
                                                  limits: limits, transactions: txs)
        let warnings = summary.lines.filter { $0.fraction >= FinanceEngine.warningThreshold }
        return card("Budget watch", badge: "Actual") {
            if summary.total == nil {
                Text("Set a budget to be warned before you overspend.").font(.subheadline).foregroundStyle(Theme.inkSecondary)
            } else if warnings.isEmpty && summary.state != .over {
                Text("Nothing is close to its limit this month.").font(.subheadline).foregroundStyle(Theme.inkSecondary)
            }
            if summary.state == .over { Callout(text: "Over the monthly budget by \(Money.format(summary.overBy)).", tone: .danger) }
            ForEach(warnings) { l in
                HStack {
                    Text(l.category).font(.subheadline).foregroundStyle(Theme.ink)
                    Spacer()
                    Text(l.spent > l.limit ? "over by \(Money.format(l.spent - l.limit))" : "\(Int((l.fraction * 100).rounded()))% used")
                        .font(.footnote.weight(.medium)).foregroundStyle(l.spent > l.limit ? Theme.danger : Theme.warning)
                }
            }
        }
    }
}
