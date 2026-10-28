import Foundation

/// A read-only snapshot of "how the money stands", built from the stored accounts, exchange rates and records.
/// Screens build one from their queries instead of each re-deriving balances and conversions.
struct Books {
    let accounts: [Account]
    let converter: CurrencyConverter
    let overview: AccountEngine.Overview
    /// Income and expense records in the reporting currency (transfers excluded). Feed these to the analytics engine.
    let reported: [TransactionRecord]
    /// Records left out of `reported` because their currency has no exchange rate yet.
    let skipped: Int

    init(accounts: [Account], rates: [ExchangeRate], transactions: [TransactionRecord], entries: [GoalEntry], legacyOpening: Int = 0) {
        self.accounts = accounts
        converter = CurrencyConverter(reporting: Money.reporting,
                                      rates: rates.map { (from: $0.fromCode, to: $0.toCode, micros: $0.rateMicros) })
        overview = AccountEngine.overview(accounts: accounts, transactions: transactions, entries: entries,
                                          converter: converter, legacyOpening: legacyOpening)
        let r = Reporting.reportable(transactions, accounts: accounts, converter: converter)
        reported = r.records
        skipped = r.skipped
    }

    /// Accounts to offer in pickers, in the user's order.
    var active: [Account] { accounts.filter { !$0.isArchived }.sorted { ($0.sortOrder, $0.createdAt) < ($1.sortOrder, $1.createdAt) } }
    var defaultAccount: Account? { AccountEngine.defaultAccount(accounts) }
    var hasSeveralAccounts: Bool { active.count > 1 }

    func account(_ id: UUID?) -> Account? {
        guard let id = id ?? defaultAccount?.id else { return nil }
        return accounts.first { $0.id == id }
    }

    func balance(of account: Account) -> Int { overview.balances[account.id] ?? 0 }

    /// Balance of `account` expressed in the reporting currency (nil when it has no exchange rate).
    func reportingBalance(of account: Account) -> Int? { converter.convert(balance(of: account), from: account.currency) }

    func needsRate(_ account: Account) -> Bool { !converter.hasRate(for: account.currency) }

    /// What is saved across all goals, in the reporting currency. A goal in a currency with no exchange rate is left out and named.
    func savedTotal(goals: [SavingsGoal], entries: [GoalEntry]) -> (total: Int, unconverted: [String]) {
        var total = 0, missing: [String] = []
        for g in goals {
            let balance = FinanceEngine.balance(of: g.id, entries: entries)
            if let c = converter.convert(balance, from: g.currency) { total += c } else { missing.append(g.name) }
        }
        return (total, missing)
    }

    /// Goal movements expressed in the reporting currency, for charts. Movements of a goal with no exchange rate are skipped.
    /// Detached copies, never stored.
    func reportableEntries(goals: [SavingsGoal], entries: [GoalEntry]) -> [GoalEntry] {
        let byID = Dictionary(uniqueKeysWithValues: goals.map { ($0.id, $0) })
        return entries.compactMap { e in
            guard let g = byID[e.goalID] else { return e }
            if g.currency.code == converter.reporting.code { return e }
            guard let cents = converter.convert(e.amountCents, from: g.currency) else { return nil }
            let copy = GoalEntry(goalID: e.goalID, amountCents: cents, date: e.date, note: e.note, affectsCash: e.affectsCash, id: e.id)
            return copy
        }
    }
}

/// Cheap lookups for drawing rows: which account a record belongs to, and whether account names are worth showing.
struct AccountDirectory {
    let byID: [UUID: Account]
    let defaultID: UUID?
    let showNames: Bool

    init(_ accounts: [Account]) {
        byID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        defaultID = AccountEngine.defaultAccount(accounts)?.id
        showNames = accounts.filter { !$0.isArchived }.count > 1
    }

    func account(_ id: UUID?) -> Account? { (id ?? defaultID).flatMap { byID[$0] } }
    func currency(of tx: TransactionRecord) -> Currency { account(tx.accountID)?.currency ?? Money.reporting }
}
