import SwiftUI
import SwiftData

enum OverviewRoute: Hashable { case analytics, settings, appIcon, history, theme, accounts, tools, safeToSpend, subscriptions, insights, purchase, whatIf, review, receipts, backup }

struct OverviewView: View {
    @Binding var tab: AppTab
    @Query(sort: \TransactionRecord.date, order: .reverse) private var txs: [TransactionRecord]
    @Query private var entries: [GoalEntry]
    @Query private var goals: [SavingsGoal]
    @Query private var costs: [TripCost]
    @Query private var monthBudgets: [MonthBudget]
    @Query private var limits: [BudgetLimit]
    @Query(sort: \PlannedExpense.dueDate) private var planned: [PlannedExpense]
    @Query(sort: \MoneyCategory.sortOrder) private var categories: [MoneyCategory]
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query private var rates: [ExchangeRate]
    @Query private var rules: [RecurringRule]
    @Query private var reservedFunds: [ReservedFund]
    @AppStorage("openingBalanceCents") private var opening = 0
    @AppStorage("lastBackupAt") private var lastBackupAt = 0.0

    @State private var showAdd = false
    @State private var path: [OverviewRoute] = OverviewView.initialPath

    private static var initialPath: [OverviewRoute] {
        #if DEBUG
        if let i = CommandLine.arguments.firstIndex(of: "-MONOScreen"), i + 1 < CommandLine.arguments.count {
            switch CommandLine.arguments[i + 1] { case "analytics": return [.analytics]; case "settings": return [.settings]; case "appicon": return [.appIcon]; case "history": return [.history]; case "theme": return [.theme]; case "accounts": return [.accounts]; case "tools": return [.tools]; case "safe": return [.safeToSpend]; case "subs": return [.subscriptions]; case "insights": return [.insights]; case "purchase": return [.purchase]; case "whatif": return [.whatIf]; case "review": return [.review]; default: break }
        }
        #endif
        return []
    }

    private var month: MonthKey { MonthKey(.now) }
    private var books: Books { Books(accounts: accounts, rates: rates, transactions: txs, entries: entries, legacyOpening: opening) }

    var body: some View {
        let books = self.books
        let cash = books.overview.total
        let saved = books.savedTotal(goals: goals, entries: entries).total
        let t = FinanceEngine.totals(books.reported, in: month)
        let budget = FinanceEngine.budgetSummary(month: month, totalLimit: monthBudgets.first { $0.monthKey == month.string }?.totalCents,
                                                 limits: limits, transactions: books.reported)
        let rate = FinanceEngine.savingsRate(income: t.income, expense: t.expense)

        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if BackupService.isBackupStale(lastBackup: lastBackupAt > 0 ? Date(timeIntervalSince1970: lastBackupAt) : nil,
                                                   hasData: !txs.isEmpty) {
                        Button { path.append(.settings) } label: {
                            Callout(text: lastBackupAt > 0 ? "No backup in over a week. Tap to back up your data."
                                                           : "You haven’t backed up yet. Tap to save a copy of your data.",
                                    tone: .warning, symbol: "externaldrive.badge.exclamationmark")
                        }
                        .buttonStyle(PressableStyle())
                    }
                    hero(cash: cash, saved: saved).entrance(0)
                    if !books.overview.unconverted.isEmpty || books.skipped > 0 {
                        Button { path.append(.accounts) } label: {
                            Callout(text: "Some money is in a currency with no exchange rate, so it isn’t in these totals. Tap to add a rate.",
                                    tone: .warning, symbol: "arrow.left.arrow.right")
                        }
                        .buttonStyle(PressableStyle())
                    }
                    if !txs.isEmpty || !accounts.isEmpty { safeLine(books).entrance(1) }
                    if books.hasSeveralAccounts { accountsCard(books).card().entrance(1) }
                    metrics(income: t.income, expense: t.expense, budget: budget, rate: rate).entrance(1)
                    cashFlow.card().entrance(2)
                    spending.card().entrance(3)
                    savings(saved: saved).card().entrance(4)
                    recent.card().entrance(5)
                    upcoming.card().entrance(6)
                    Button { path.append(.analytics) } label: {
                        HStack {
                            Label("All analytics", systemImage: "chart.xyaxis.line").font(.body)
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(Theme.inkTertiary)
                        }
                        .foregroundStyle(Theme.ink)
                        .card()
                    }
                    .buttonStyle(PressableStyle())
                }
                .padding(.horizontal, Theme.gutter).padding(.top, 4).padding(.bottom, 40)
            }
            .monoScreen()
            .navigationTitle("Overview")
            .navigationDestination(for: OverviewRoute.self) { r in
                switch r { case .analytics: AnalyticsView(); case .settings: SettingsView(); case .appIcon: ThemeEditorView(initialTab: .icon); case .history: VersionHistoryView(); case .theme: ThemeEditorView(); case .accounts: AccountsView(); case .tools: ToolsView(); case .safeToSpend: SafeToSpendView(); case .subscriptions: SubscriptionsView(); case .insights: InsightsView(); case .purchase: PurchaseSimulatorView(); case .whatIf: WhatIfLabView(); case .review: MonthlyReviewView(); default: ToolsView() }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { path.append(.settings) } label: { Image(systemName: "gearshape") }.accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { path.append(.tools) } label: { Image(systemName: "square.grid.2x2") }.accessibilityLabel("Tools")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { path.append(.analytics) } label: { Image(systemName: "chart.xyaxis.line") }.accessibilityLabel("Analytics")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add transaction").accessibilityIdentifier("overviewAdd")
                }
            }
            .sheet(isPresented: $showAdd) { TransactionForm(editing: nil) }
        }
    }

    // MARK: Hero

    private func hero(cash: Int, saved: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Available cash").font(.footnote.weight(.medium)).foregroundStyle(Theme.onPrimary.opacity(0.74))
            Text(Money.format(cash))
                .font(.figure(44, weight: .light)).foregroundStyle(Theme.onPrimary)
                .lineLimit(1).minimumScaleFactor(0.6)
                .contentTransition(.numericText())
                .accessibilityIdentifier("availableCash")
            HStack(spacing: 6) {
                Image(systemName: "lock").font(.caption2)
                Text("\(Money.format(saved)) set aside in goals").font(.footnote)
            }
            .foregroundStyle(Theme.onPrimary.opacity(0.74))
            .padding(.top, 2)
            if cash == 0 && txs.isEmpty {
                Button { path.append(.accounts) } label: {
                    Text("Add your starting balance to see what you have today")
                        .font(.footnote.weight(.medium)).foregroundStyle(Theme.onPrimary)
                        .underline(true, color: Theme.onPrimary.opacity(0.4))
                }
                .buttonStyle(PressableStyle()).padding(.top, 6)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HeroBackground())
        .overlay(alignment: .topTrailing) {
            Button { PrivacyStore.shared.toggle(); Haptics.tap() } label: {
                Image(systemName: PrivacyStore.shared.hidden ? "eye.slash" : "eye").font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.onPrimary.opacity(0.85)).frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .padding(8)
            .accessibilityLabel(PrivacyStore.shared.hidden ? "Show amounts" : "Hide amounts")
            .accessibilityIdentifier("toggleHideAmounts")
        }
    }

    // MARK: Metrics

    private func metrics(income: Int, expense: Int, budget: BudgetSummary, rate: Double?) -> some View {
        let tint = budget.state == .over ? Theme.danger : budget.state == .warning ? Theme.warning : Theme.accent
        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: month.title()).padding(.horizontal, 4)
            HStack(spacing: 12) {
                StatTile(title: "Income", value: Money.format(income), symbol: "arrow.down.left", tint: Theme.income)
                StatTile(title: "Expenses", value: Money.format(expense), symbol: "arrow.up.right")
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                budgetTile(budget, tint: tint)
                VStack(spacing: 12) {
                    if let rate {
                        StatTile(title: "Saved", value: "\(Int((rate * 100).rounded()))%", symbol: "leaf",
                                 tint: rate < 0 ? Theme.danger : Theme.ink, footnote: rate < 0 ? "Spending exceeds income" : "of income")
                    } else {
                        StatTile(title: "Saved", value: "—", symbol: "leaf", footnote: "No income yet")
                    }
                    StatTile(title: "Per day", value: budget.dailyAllowance.map { Money.format($0) } ?? "—", symbol: "calendar",
                             footnote: budget.dailyAllowance == nil ? "No budget set" : "\(budget.daysLeft) \(budget.daysLeft == 1 ? "day" : "days") left")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func budgetTile(_ b: BudgetSummary, tint: Color) -> some View {
        VStack(spacing: 12) {
            RingGauge(value: b.fraction ?? 0, tint: tint, lineWidth: 11) {
                VStack(spacing: 0) {
                    Text(b.fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—").font(.figure(24)).foregroundStyle(Theme.ink)
                    Text("used").font(.caption2).foregroundStyle(Theme.inkTertiary)
                }
            }
            .frame(width: 104, height: 104)
            VStack(spacing: 2) {
                Text(b.remaining.map { $0 < 0 ? "Over by \(Money.format(-$0))" : "\(Money.format($0)) left" } ?? "No budget set")
                    .font(.footnote.weight(.medium)).foregroundStyle(b.state == .over ? Theme.danger : Theme.ink)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text("Budget").font(.caption).foregroundStyle(Theme.inkTertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glass(radius: 22)
        .accessibilityElement(children: .combine)
    }

    /// One quiet line; the full breakdown is a tap away.
    private func safeLine(_ books: Books) -> some View {
        let r = SafeToSpend.make(config: SafeToSpend.Config.load(), books: books, planned: planned, rules: rules, goals: goals, costs: costs,
                                 entries: entries, categories: categories, limits: limits, monthBudgets: monthBudgets, reserved: reservedFunds)
        return Button { path.append(.safeToSpend) } label: {
            HStack(spacing: 12) {
                Image(systemName: "shield.lefthalf.filled").foregroundStyle(r.isShortfall ? Theme.warning : Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(r.isShortfall ? "Short by \(Money.format(abs(r.flexible)))" : "Safe to spend \(Money.format(r.flexible))")
                        .font(.subheadline.weight(.medium)).foregroundStyle(Theme.ink)
                    Text("until \(r.horizonEnd.formatted(.dateTime.day().month(.abbreviated))) · after bills, savings and essentials")
                        .font(.caption).foregroundStyle(Theme.inkSecondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(Theme.inkTertiary)
            }
            .glass(padding: 14, radius: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityElement(children: .combine)
    }

    private func accountsCard(_ books: Books) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title: "Accounts", trailing: "Manage") { path.append(.accounts) }.padding(.bottom, 6)
            ForEach(Array(books.active.enumerated()), id: \.element.id) { i, a in
                HStack(spacing: 12) {
                    CategoryGlyph(symbol: a.kind.symbol, tint: Theme.inkSecondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.name).font(.body).foregroundStyle(Theme.ink).lineLimit(1)
                        if a.currencyCode != Money.reporting.code {
                            Text(books.reportingBalance(of: a).map { "≈ \(Money.format($0))" } ?? "No exchange rate yet")
                                .font(.caption).foregroundStyle(books.needsRate(a) ? Theme.warning : Theme.inkSecondary)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(Money.format(books.balance(of: a), currency: a.currency)).font(.figure(16)).foregroundStyle(Theme.ink)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                .padding(.vertical, 6)
                .accessibilityElement(children: .combine)
                if i < books.active.count - 1 { Hairline() }
            }
        }
    }

    // MARK: Charts

    private var cashFlow: some View {
        let reported = books.reported
        let first = FinanceEngine.firstRecordMonth(transactions: reported)
        let start = first.map { max($0, month.adding(-5)) } ?? month
        let months = FinanceEngine.monthlySummaries(reported, range: start.months(through: month))
        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Cash flow", trailing: "Details") { path.append(.analytics) }
            if txs.isEmpty {
                Text("Add a few transactions to see income and expenses by month.")
                    .font(.subheadline).foregroundStyle(Theme.inkSecondary)
            } else {
                IncomeExpenseChart(months: months).hidesAmounts()
                if let first, first > month.adding(-5) {
                    Text("Showing records from \(first.title()). Earlier months aren’t estimated.")
                        .font(.caption).foregroundStyle(Theme.inkTertiary)
                }
            }
        }
    }

    private var spending: some View {
        let slices = FinanceEngine.expensesByCategory(books.reported, in: month...month)
        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Spending by category")
            if slices.isEmpty {
                Text("No expenses recorded in \(month.title()).").font(.subheadline).foregroundStyle(Theme.inkSecondary)
            } else {
                CategoryDonut(slices: slices).hidesAmounts()
                CategoryBreakdownList(slices: slices, limit: 5)
            }
        }
    }

    private func savings(saved: Int) -> some View {
        let trips = goals.filter { $0.kind == .trip }
        let trip = trips.filter { SavingsPlanner.plan(for: $0, costs: costs, entries: entries).status != .funded }
            .min { ($0.deadline ?? .distantFuture) < ($1.deadline ?? .distantFuture) } ?? trips.first
        let growth = FinanceEngine.savingsGrowth(entries: books.reportableEntries(goals: goals, entries: entries), through: month)
        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Savings", trailing: "Goals") { tab = .goals }
            if let trip {
                let plan = SavingsPlanner.plan(for: trip, costs: costs, entries: entries)
                Button { tab = .goals } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label(trip.name, systemImage: "airplane").font(.body).foregroundStyle(Theme.ink)
                            Spacer()
                            StatusChip(text: plan.statusText, tint: plan.statusTint)
                        }
                        ProgressLine(value: plan.percentFunded, tint: plan.status == .overdue ? Theme.danger : Theme.accent)
                        HStack {
                            Text("\(trip.money(plan.saved)) of \(trip.money(plan.target))").font(.figure(14)).foregroundStyle(Theme.ink)
                            Spacer()
                            if let r = plan.requiredMonthly, plan.status != .funded {
                                Text("\(trip.money(r))/\(trip.frequency == .monthly ? "mo" : trip.frequency == .weekly ? "wk" : "2wk") needed").font(.footnote).foregroundStyle(Theme.inkSecondary)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
            } else {
                Text("Plan a trip to track how much you need to save each month.")
                    .font(.subheadline).foregroundStyle(Theme.inkSecondary)
            }
            if growth.count >= 2 { SavingsGrowthChart(points: growth, height: 110).hidesAmounts() }
        }
    }

    // MARK: Lists

    private var recent: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title: "Recent", trailing: txs.isEmpty ? nil : "See all") { tab = .transactions }.padding(.bottom, 6)
            if txs.isEmpty {
                EmptyState(symbol: "tray", title: "Nothing yet", message: "Your latest income and expenses will show up here.",
                           actionTitle: "Add transaction") { showAdd = true }
            }
            ForEach(Array(txs.prefix(5).enumerated()), id: \.element.id) { i, tx in
                TransactionRow(tx: tx, symbol: categories.symbol(for: tx.category), directory: AccountDirectory(accounts))
                if i < min(txs.count, 5) - 1 { Hairline() }
            }
        }
    }

    /// Planned expenses and the next payments of your active subscriptions, soonest first.
    private struct UpcomingItem: Identifiable {
        let id: String; let title: String; let date: Date; let category: String; let amount: String; let isSubscription: Bool
    }

    private var upcoming: some View {
        let dir = AccountDirectory(accounts)
        let horizon = Calendar.current.date(byAdding: .day, value: 14, to: .now) ?? .now
        let plannedItems = FinanceEngine.upcoming(planned).map {
            UpcomingItem(id: "p-\($0.id)", title: $0.title, date: $0.dueDate, category: $0.category, amount: Money.format($0.amountCents), isSubscription: false)
        }
        let subs = rules.filter { $0.status == .active && $0.kind == .expense && $0.dueDate <= horizon }.map {
            UpcomingItem(id: "s-\($0.id)", title: $0.title, date: $0.dueDate, category: $0.category,
                         amount: Money.format($0.amountCents, currency: dir.account($0.accountID)?.currency), isSubscription: true)
        }
        let list = Array((plannedItems + subs).sorted { $0.date < $1.date }.prefix(4))
        return VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title: "Upcoming", trailing: "Manage") { tab = .budget }.padding(.bottom, 6)
            if list.isEmpty {
                Text("Nothing due soon. Add bills in Budget, or subscriptions in Tools.")
                    .font(.subheadline).foregroundStyle(Theme.inkSecondary)
            }
            ForEach(Array(list.enumerated()), id: \.element.id) { i, p in
                let overdue = p.date < Calendar.current.startOfDay(for: .now)
                HStack(spacing: 12) {
                    CategoryGlyph(symbol: p.isSubscription ? "arrow.triangle.2.circlepath" : categories.symbol(for: p.category),
                                  tint: overdue ? Theme.warning : Theme.inkSecondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.title).font(.body).foregroundStyle(Theme.ink).lineLimit(1)
                        Text("\(overdue ? "Overdue" : "Due") \(p.date.short)\(p.isSubscription ? " · subscription" : "")")
                            .font(.caption).foregroundStyle(overdue ? Theme.warning : Theme.inkSecondary)
                    }
                    Spacer()
                    Text(p.amount).font(.figure(15)).foregroundStyle(Theme.ink)
                }
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
                if i < list.count - 1 { Hairline() }
            }
        }
    }
}
