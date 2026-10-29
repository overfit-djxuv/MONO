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

    @State private var sheet: DashboardSheet?
    @State private var path: [OverviewRoute] = OverviewView.initialPath

    private static var initialPath: [OverviewRoute] {
        #if DEBUG
        if let i = CommandLine.arguments.firstIndex(of: "-MONOScreen"), i + 1 < CommandLine.arguments.count {
            switch CommandLine.arguments[i + 1] { case "analytics": return [.analytics]; case "settings": return [.settings]; case "appicon": return [.appIcon]; case "history": return [.history]; case "theme": return [.theme]; case "accounts": return [.accounts]; case "tools": return [.tools]; case "safe": return [.safeToSpend]; case "subs": return [.subscriptions]; case "insights": return [.insights]; case "purchase": return [.purchase]; case "whatif": return [.whatIf]; case "review": return [.review]; case "backup": return [.backup]; case "receipts": return [.receipts]; default: break }
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
                VStack(alignment: .leading, spacing: 20) {
                    if BackupService.isBackupStale(lastBackup: lastBackupAt > 0 ? Date(timeIntervalSince1970: lastBackupAt) : nil,
                                                   hasData: !txs.isEmpty) {
                        Button { path.append(.backup) } label: {
                            Callout(text: lastBackupAt > 0 ? "No copy saved outside MONO in over a week. Tap to save one."
                                                           : "No copy of your data is saved outside MONO yet. Tap to save one.",
                                    tone: .warning, symbol: "externaldrive.badge.exclamationmark")
                        }
                        .buttonStyle(PressableStyle())
                    }
                    hero(books: books, cash: cash, saved: saved).entrance(0)
                    if !books.overview.unconverted.isEmpty || books.skipped > 0 {
                        Button { path.append(.accounts) } label: {
                            Callout(text: "Some money is in a currency with no exchange rate, so it isn’t in these totals. Tap to add a rate.",
                                    tone: .warning, symbol: "arrow.left.arrow.right")
                        }
                        .buttonStyle(PressableStyle())
                    }
                    summary(income: t.income, expense: t.expense, budget: budget, rate: rate).entrance(1)
                    quickActions.entrance(2)
                    insightLine(budget).entrance(2)
                    if books.hasSeveralAccounts { accountsCard(books).surface().entrance(3) }
                    cashFlow.entrance(3)
                    spending.entrance(3)
                    goalsSection.entrance(3)
                    savingsGrowth.entrance(4)
                    upcoming.entrance(4)
                    recent.entrance(5)
                    allAnalytics.entrance(5)
                }
                .padding(.horizontal, Theme.gutter).padding(.top, 4).padding(.bottom, 40)
            }
            .monoScreen()
            .navigationTitle("Dashboard")
            .navigationDestination(for: OverviewRoute.self) { r in
                switch r { case .analytics: AnalyticsView(); case .settings: SettingsView(); case .appIcon: ThemeEditorView(initialTab: .icon); case .history: VersionHistoryView(); case .theme: ThemeEditorView(); case .accounts: AccountsView(); case .tools: ToolsView(); case .safeToSpend: SafeToSpendView(); case .subscriptions: SubscriptionsView(); case .insights: InsightsView(); case .purchase: PurchaseSimulatorView(); case .whatIf: WhatIfLabView(); case .review: MonthlyReviewView(); case .backup: BackupCenterView(); case .receipts: ReceiptsView(); default: ToolsView() }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { PrivacyStore.shared.toggle(); Haptics.tap() } label: {
                        Image(systemName: PrivacyStore.shared.hidden ? "eye.slash" : "eye")
                    }
                    .accessibilityLabel(PrivacyStore.shared.hidden ? "Show amounts" : "Hide amounts")
                    .accessibilityIdentifier("toggleHideAmounts")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { path.append(.analytics) } label: { Label("Analytics", systemImage: "chart.xyaxis.line") }
                        Button { path.append(.tools) } label: { Label("Tools", systemImage: "square.grid.2x2") }
                        Button { path.append(.receipts) } label: { Label("Receipts", systemImage: "doc.text.viewfinder") }
                        Button { path.append(.accounts) } label: { Label("Accounts & currency", systemImage: "wallet.pass") }
                        Divider()
                        Button { path.append(.backup) } label: { Label("Backup & recovery", systemImage: "externaldrive.badge.checkmark") }
                        Button { path.append(.settings) } label: { Label("Settings", systemImage: "gearshape") }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("More")
                    .accessibilityIdentifier("dashboardMore")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { sheet = .expense } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add transaction").accessibilityIdentifier("overviewAdd")
                }
            }
            .sheet(item: $sheet) { s in
                switch s {
                case .expense: TransactionForm(editing: nil, kind: .expense)
                case .income: TransactionForm(editing: nil, kind: .income)
                case .transfer: TransactionForm(editing: nil, kind: .transfer)
                case .scan: ReceiptScanFlow()
                case .toGoal(let g): MoveMoneySheet(goal: g, withdraw: false)
                }
            }
        }
    }

    enum DashboardSheet: Identifiable {
        case expense, income, transfer, scan, toGoal(SavingsGoal)
        var id: String { switch self { case .expense: "e"; case .income: "i"; case .transfer: "t"; case .scan: "s"; case .toGoal(let g): "g\(g.id)" } }
    }

    // MARK: Hero

    private func hero(books: Books, cash: Int, saved: Int) -> some View {
        let r = SafeToSpend.make(config: SafeToSpend.Config.load(), books: books, planned: planned, rules: rules, goals: goals, costs: costs,
                                 entries: entries, categories: categories, limits: limits, monthBudgets: monthBudgets, reserved: reservedFunds)
        return VStack(alignment: .leading, spacing: 4) {
            Text("Available").font(.footnote.weight(.medium)).foregroundStyle(Theme.onPrimary.opacity(0.78))
            Text(Money.format(cash))
                .font(.figure(40, weight: .semibold)).foregroundStyle(Theme.onPrimary)
                .lineLimit(1).minimumScaleFactor(0.6)
                .contentTransition(.numericText())
                .accessibilityIdentifier("availableCash")
            if cash == 0 && txs.isEmpty {
                Button { path.append(.accounts) } label: {
                    Text("Add your starting balance to see what you have today")
                        .font(.footnote.weight(.medium)).foregroundStyle(Theme.onPrimary)
                        .underline(true, color: Theme.onPrimary.opacity(0.4))
                }
                .buttonStyle(PressableStyle()).padding(.top, 6)
            } else {
                Rectangle().fill(Theme.onPrimary.opacity(0.22)).frame(height: 0.5).padding(.vertical, 10)
                Button { path.append(.safeToSpend) } label: {
                    HStack {
                        Text(r.isShortfall ? "Short for bills and plans" : "Safe to spend until \(r.horizonEnd.formatted(.dateTime.day().month(.abbreviated)))")
                            .foregroundStyle(Theme.onPrimary.opacity(0.78))
                        Spacer(minLength: 8)
                        Text(Money.format(abs(r.flexible))).font(.figure(15, weight: .semibold)).foregroundStyle(Theme.onPrimary)
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Theme.onPrimary.opacity(0.6))
                    }
                    .font(.subheadline).contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .accessibilityElement(children: .combine)
                HStack {
                    Text("Set aside in goals").foregroundStyle(Theme.onPrimary.opacity(0.78))
                    Spacer()
                    Text(Money.format(saved)).font(.figure(15)).foregroundStyle(Theme.onPrimary)
                }
                .font(.subheadline).padding(.top, 4)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HeroBackground())
    }

    // MARK: Summary

    private func summary(income: Int, expense: Int, budget: BudgetSummary, rate: Double?) -> some View {
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
        Button { tab = .budget } label: {
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
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityElement(children: .combine)
    }

    // MARK: Analytics summaries

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
        .surface()
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
        .surface()
    }

    @ViewBuilder private var savingsGrowth: some View {
        let growth = FinanceEngine.savingsGrowth(entries: books.reportableEntries(goals: goals, entries: entries), through: month)
        if growth.count >= 2 {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Savings growth", trailing: "Goals") { tab = .goals }
                SavingsGrowthChart(points: growth, height: 110).hidesAmounts()
            }
            .surface()
        }
    }

    private var allAnalytics: some View {
        Button { path.append(.analytics) } label: {
            HStack {
                Label("All analytics", systemImage: "chart.xyaxis.line").font(.body)
                Spacer()
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(Theme.inkTertiary)
            }
            .foregroundStyle(Theme.ink)
            .surface()
        }
        .buttonStyle(PressableStyle())
    }

    // MARK: Quick actions

    private var quickActions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                QuickChip(title: "Expense", symbol: "minus") { sheet = .expense }.accessibilityIdentifier("overviewAdd")
                QuickChip(title: "Income", symbol: "plus") { sheet = .income }
                QuickChip(title: "Transfer", symbol: "arrow.left.arrow.right") { sheet = .transfer }
                QuickChip(title: "To goal", symbol: "flag") {
                    let open = goals.filter { $0.isOngoing }.filter { SavingsPlanner.plan(for: $0, costs: costs, entries: entries).status != .funded }
                    if open.count == 1, let g = open.first { sheet = .toGoal(g) } else { tab = .goals }
                }
                QuickChip(title: "Shopping", symbol: "cart") { tab = .shopping }
                QuickChip(title: "Scan", symbol: "doc.viewfinder") { sheet = .scan }
            }
            .padding(.horizontal, Theme.gutter)
        }
        .padding(.horizontal, -Theme.gutter)
    }

    // MARK: Insight (at most one)

    @ViewBuilder private func insightLine(_ budget: BudgetSummary) -> some View {
        let payments = subscriptionPayments + FinanceEngine.upcoming(planned).map { (title: $0.title, date: $0.dueDate) }
        let behind = goals.filter(\.isOngoing).filter { SavingsPlanner.plan(for: $0, costs: costs, entries: entries).status == .behind }.map(\.name)
        if let i = DashboardInsight.pick(budget: budget, payments: payments, behindGoals: behind) {
            switch i {
            case .overBudget(let c, let over):
                Button { tab = .budget } label: { Callout(text: "\(c) is \(Money.format(over)) over its limit this month.", tone: .danger, symbol: "exclamationmark.circle") }.buttonStyle(PressableStyle())
            case .nearLimit(let c, let left, let pct):
                Button { tab = .budget } label: { Callout(text: "\(c) is at \(pct)% of its limit, \(Money.format(left)) left.", tone: .warning, symbol: "gauge.with.dots.needle.67percent") }.buttonStyle(PressableStyle())
            case .paymentDue(let title, let date, let overdue):
                Callout(text: "\(title) \(overdue ? "was due" : "is due") \(date.short).", tone: overdue ? .danger : .warning, symbol: "calendar.badge.exclamationmark")
            case .goalBehind(let name):
                Button { tab = .goals } label: { Callout(text: "\(name) is behind plan.", tone: .warning, symbol: "flag") }.buttonStyle(PressableStyle())
            }
        }
    }

    private var subscriptionPayments: [(title: String, date: Date)] {
        rules.filter { $0.status == .active && $0.kind == .expense }.map { (title: $0.title, date: $0.dueDate) }
    }

    // MARK: Goals

    private var goalsSection: some View {
        let active = goals.filter(\.isOngoing).filter { SavingsPlanner.plan(for: $0, costs: costs, entries: entries).status != .funded }
            .sorted { ($0.priority.rawValue, $0.deadline ?? .distantFuture) > ($1.priority.rawValue, $1.deadline ?? .distantFuture) }
            .prefix(3)
        return VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: "Goals", trailing: goals.contains(where: \.isOngoing) ? "See all" : nil) { tab = .goals }.padding(.bottom, 2)
            if goals.isEmpty {
                Button { tab = .goals } label: {
                    Text("Plan a trip or a purchase to see how much to save each month.").font(.subheadline).foregroundStyle(Theme.inkSecondary).multilineTextAlignment(.leading)
                }.buttonStyle(PressableStyle()).padding(.vertical, 8)
            }
            ForEach(Array(active.enumerated()), id: \.element.id) { i, g in
                let plan = SavingsPlanner.plan(for: g, costs: costs, entries: entries)
                Button { tab = .goals } label: {
                    ProgressRow(symbol: g.kind == .trip ? "airplane" : g.symbol, title: g.name,
                                subtitle: "\(g.money(plan.saved)) of \(g.money(plan.target))",
                                trailing: "\(Int((plan.percentFunded * 100).rounded()))%", value: plan.percentFunded,
                                tint: plan.status == .overdue ? Theme.danger : plan.status == .behind ? Theme.warning : Theme.accent,
                                note: g.progressNote(plan), noteTint: plan.status == .behind ? Theme.warning : Theme.inkSecondary)
                }
                .buttonStyle(PressableStyle())
                if i < active.count - 1 { Hairline() }
            }
        }
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

    // MARK: Lists

    private var recent: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: "Recent", trailing: txs.isEmpty ? nil : "All transactions") { tab = .transactions }.padding(.bottom, 2)
            if txs.isEmpty {
                EmptyState(symbol: "tray", title: "Nothing yet", message: "Your latest income and expenses will show up here.",
                           actionTitle: "Add transaction") { sheet = .expense }
            }
            ForEach(Array(txs.prefix(5).enumerated()), id: \.element.id) { i, tx in
                TransactionRow(tx: tx, symbol: categories.symbol(for: tx.category), directory: AccountDirectory(accounts))
                    .padding(.vertical, 6)
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
            SectionTitle(title: "Coming up", trailing: "Budget") { tab = .budget }.padding(.bottom, 2)
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
