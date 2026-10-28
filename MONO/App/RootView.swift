import SwiftUI
import SwiftData

enum AppTab: Hashable { case overview, transactions, budget, shopping, goals }

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var phase
    @AppStorage("appearance") private var appearance = 0
    @State private var tab: AppTab = RootView.initialTab
    @State private var errors = ErrorCenter()
    @State private var lock = AppLock()
    @Query private var recurring: [RecurringRule]
    @Query private var allTx: [TransactionRecord]
    @Query private var planned: [PlannedExpense]
    @Query private var monthBudgets: [MonthBudget]
    @Query private var limits: [BudgetLimit]

    private static var initialTab: AppTab {
        #if DEBUG
        // `-MONOTab 2` opens a given tab; used for simulator screenshots and UI tests.
        if let i = CommandLine.arguments.firstIndex(of: "-MONOTab"), i + 1 < CommandLine.arguments.count,
           let n = Int(CommandLine.arguments[i + 1]) {
            return [.overview, .transactions, .budget, .shopping, .goals][min(max(n, 0), 4)]
        }
        #endif
        return .overview
    }

    private var scheme: ColorScheme? {
        switch appearance { case 1: .light; case 2: .dark; default: nil }
    }

    var body: some View {
        TabView(selection: $tab) {
            OverviewView(tab: $tab)
                .tabItem { Label("Overview", systemImage: "circle.grid.2x2") }
                .tag(AppTab.overview)
            TransactionsView()
                .tabItem { Label("Transactions", systemImage: "list.bullet") }
                .tag(AppTab.transactions)
            BudgetView()
                .tabItem { Label("Budget", systemImage: "chart.pie") }
                .tag(AppTab.budget)
            ShoppingView()
                .tabItem { Label("Shopping", systemImage: "cart") }
                .tag(AppTab.shopping)
            GoalsView()
                .tabItem { Label("Goals", systemImage: "flag") }
                .tag(AppTab.goals)
        }
        .tint(Theme.accent)
        .preferredColorScheme(scheme)
        .environment(errors)
        .environment(lock)
        .overlay { if phase != .active { PrivacyCover() } }
        .overlay { if lock.isLocked { LockView(lock: lock).transition(.opacity) } }
        .accessibilityHidden(lock.isLocked)
        .animation(.easeOut(duration: 0.15), value: phase)
        .animation(.easeOut(duration: 0.15), value: lock.isLocked)
        .onChange(of: plannedSignature) { _, _ in refreshReminders() }
        .onChange(of: allTx.count) { _, _ in refreshBudgetAlert(); migrateAccounts() }
        .onChange(of: phase) { _, new in
            switch new {
            case .background: lock.lockIfEnabled()
            case .active:
                postRecurring()
                refreshReminders()
                refreshBudgetAlert()
                if lock.isLocked { Task { await lock.unlock() } }
            default: break
            }
        }
        .alert("Something went wrong", isPresented: Binding(get: { errors.message != nil },
                                                           set: { if !$0 { errors.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errors.message ?? "") }
        .task {
            if lock.isLocked { await lock.unlock() }
            DefaultCategories.seedIfNeeded(context)
            migrateAccounts()
            postRecurring()
            #if DEBUG
            DemoData.loadIfRequested(context)
            #endif
        }
    }
}

extension RootView {
    /// Changes whenever a planned expense is added, edited, paid or removed.
    fileprivate var plannedSignature: [String] {
        planned.map { "\($0.id)|\($0.title)|\($0.amountCents)|\($0.dueDate.timeIntervalSince1970)|\($0.isPaid)" }
    }

    /// Gives every record an account (see AccountMigration). Cheap and idempotent, so it also runs after imports and restores.
    fileprivate func migrateAccounts() {
        do { try AccountMigration.run(in: context) }
        catch { errors.report(error, doing: "Couldn’t set up accounts. Your data was not changed") }
    }

    fileprivate func refreshReminders() {
        guard Reminders.isEnabled else { return }
        let snapshot = planned
        Task { await Reminders.syncPlanned(snapshot) }
    }

    fileprivate func refreshBudgetAlert() {
        guard Reminders.isEnabled else { return }
        let month = MonthKey(.now)
        let summary = FinanceEngine.budgetSummary(month: month, totalLimit: monthBudgets.first { $0.monthKey == month.string }?.totalCents,
                                                  limits: limits, transactions: allTx)
        if let message = Reminders.checkBudget(summary) { Task { await Reminders.post(budgetMessage: message) } }
    }

    /// Adds any recurring transactions that have come due. Safe to call repeatedly.
    fileprivate func postRecurring() {
        do { try Ledger.postDueRecurring(recurring, in: context) }
        catch { errors.report(error, doing: "Couldn’t add recurring transactions") }
    }
}

private struct LockView: View {
    let lock: AppLock

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "lock").font(.system(size: 30, weight: .light)).foregroundStyle(Theme.inkTertiary)
                Text("MONO").font(.system(size: 28, weight: .light)).tracking(6).foregroundStyle(Theme.inkTertiary)
                Button { Task { await lock.unlock() } } label: {
                    Label("Unlock", systemImage: "faceid").font(.body.weight(.medium))
                }
                .buttonStyle(.bordered).tint(Theme.accent)
            }
        }
    }
}

/// Hides balances in the app-switcher snapshot.
private struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            Text("MONO").font(.system(size: 28, weight: .light)).tracking(6).foregroundStyle(Theme.inkTertiary)
        }
        .transition(.opacity)
    }
}
