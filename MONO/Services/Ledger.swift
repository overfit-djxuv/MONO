import Foundation
import SwiftData

/// Mutations that touch more than one record. Keeping them here means the duplicate-prevention and
/// "goal money is not income or expense" rules live in one tested place.
enum Ledger {
    enum LedgerError: LocalizedError, Equatable {
        case alreadyRecorded
        case invalidAmount
        case insufficientGoalBalance
        case sameAccount
        case archivedAccount
        case transferAmountMismatch

        var errorDescription: String? {
            switch self {
            case .alreadyRecorded: "This has already been recorded as an expense."
            case .invalidAmount: "Enter an amount greater than zero."
            case .insufficientGoalBalance: "That is more than the goal currently holds."
            case .sameAccount: "Choose two different accounts."
            case .archivedAccount: "That account is archived. Choose another one."
            case .transferAmountMismatch: "Both accounts use the same currency, so the amount received must equal the amount sent."
            }
        }
    }

    // MARK: Shopping → expense

    static func canRecord(_ item: ShoppingItem, existing: [TransactionRecord]) -> Bool {
        item.expenseID == nil && !existing.contains { $0.sourceID == item.id }
    }

    /// Records a purchased item as one expense. Refuses if it was already recorded.
    @discardableResult
    static func recordPurchase(_ item: ShoppingItem, existing: [TransactionRecord],
                               in context: ModelContext, now: Date = .now) throws -> TransactionRecord {
        guard canRecord(item, existing: existing) else { throw LedgerError.alreadyRecorded }
        guard item.effectiveTotal > 0 else { throw LedgerError.invalidAmount }
        let title = item.quantity > 1 ? "\(item.name) ×\(item.quantity)" : item.name
        let tx = TransactionRecord(amountCents: item.effectiveTotal, kind: .expense, category: item.category,
                                   date: item.purchasedAt ?? now, title: title, sourceID: item.id)
        context.insert(tx)
        item.isPurchased = true
        item.purchasedAt = item.purchasedAt ?? now
        item.expenseID = tx.id
        try context.save()
        return tx
    }

    // MARK: Planned expense → expense

    @discardableResult
    static func markPaid(_ planned: PlannedExpense, existing: [TransactionRecord],
                         in context: ModelContext, now: Date = .now) throws -> TransactionRecord {
        guard !planned.isPaid, planned.paidTransactionID == nil,
              !existing.contains(where: { $0.sourceID == planned.id }) else { throw LedgerError.alreadyRecorded }
        guard planned.amountCents > 0 else { throw LedgerError.invalidAmount }
        let tx = TransactionRecord(amountCents: planned.amountCents, kind: .expense, category: planned.category,
                                   date: now, title: planned.title, sourceID: planned.id)
        context.insert(tx)
        planned.isPaid = true
        planned.paidTransactionID = tx.id
        try context.save()
        return tx
    }

    // MARK: Deletion with link hygiene

    /// Deleting a generated expense unlinks its source so it can be recorded again deliberately.
    static func delete(_ tx: TransactionRecord, items: [ShoppingItem], planned: [PlannedExpense],
                       in context: ModelContext) throws {
        for i in items where i.expenseID == tx.id { i.expenseID = nil }
        for p in planned where p.paidTransactionID == tx.id { p.paidTransactionID = nil; p.isPaid = false }
        context.delete(tx)
        try context.save()
    }

    // MARK: Transfers

    /// Moves money between two of your accounts. Recorded as ONE transfer, so it can never be counted as income or spending,
    /// and the two balances always change by matching amounts. For different currencies the amount received is explicit,
    /// which fixes the exchange rate used for that transfer.
    static func validateTransfer(from: Account, to: Account, sentCents: Int, receivedCents: Int, allowArchived: Bool = false) throws {
        guard from.id != to.id else { throw LedgerError.sameAccount }
        if !allowArchived, from.isArchived || to.isArchived { throw LedgerError.archivedAccount }
        guard (1...Money.maxCents).contains(sentCents), (1...Money.maxCents).contains(receivedCents) else { throw LedgerError.invalidAmount }
        if from.currencyCode == to.currencyCode, sentCents != receivedCents { throw LedgerError.transferAmountMismatch }
    }

    @discardableResult
    static func createTransfer(from: Account, to: Account, sentCents: Int, receivedCents: Int, date: Date,
                               title: String = "", notes: String = "", in context: ModelContext) throws -> TransactionRecord {
        try validateTransfer(from: from, to: to, sentCents: sentCents, receivedCents: receivedCents)
        let tx = TransactionRecord(amountCents: sentCents, kind: .transfer, category: "", date: date, title: title,
                                   notes: notes, accountID: from.id)
        tx.toAccountID = to.id
        tx.toAmountCents = receivedCents
        context.insert(tx)
        try context.save()
        return tx
    }

    // MARK: Duplicates

    /// An existing record that looks like the one about to be added: same day, type, amount, account and description.
    /// Used to warn (never to block), because buying two identical coffees in a day is legitimate.
    static func possibleDuplicate(kind: TxKind, cents: Int, date: Date, title: String, merchant: String = "", accountID: UUID?,
                                  defaultAccountID: UUID?, excluding id: UUID? = nil, in existing: [TransactionRecord],
                                  calendar: Calendar = .current) -> TransactionRecord? {
        let day = calendar.startOfDay(for: date)
        let label = (merchant.isEmpty ? title : merchant).trimmingCharacters(in: .whitespaces).lowercased()
        return existing.first { t in
            t.id != id && t.kind == kind && t.amountCents == cents && calendar.startOfDay(for: t.date) == day
                && (t.accountID ?? defaultAccountID) == (accountID ?? defaultAccountID)
                && (t.merchant.isEmpty ? t.title : t.merchant).trimmingCharacters(in: .whitespaces).lowercased() == label
        }
    }

    // MARK: Repeat

    /// Copies a transaction to today. The copy is a plain transaction: it doesn't inherit a shopping or planned-expense link.
    @discardableResult
    static func repeatTransaction(_ tx: TransactionRecord, in context: ModelContext, now: Date = .now) throws -> TransactionRecord {
        let copy = TransactionRecord(amountCents: tx.amountCents, kind: tx.kind, category: tx.category, date: now,
                                     title: tx.title, notes: tx.notes, accountID: tx.accountID, merchant: tx.merchant, tags: tx.tags)
        copy.toAccountID = tx.toAccountID
        copy.toAmountCents = tx.toAmountCents
        context.insert(copy)
        try context.save()
        return copy
    }

    // MARK: Recurring

    static let maxRecurringCatchUpMonths = 36

    /// The first month a new rule should post in: this month if its day hasn't passed, otherwise next month.
    /// A new rule never back-dates, so adding one can't silently change past balances.
    static func firstDueMonth(day: Int, now: Date = .now, calendar: Calendar = .current) -> MonthKey {
        let today = calendar.component(.day, from: now)
        let cur = MonthKey(now, calendar: calendar)
        return day >= today ? cur : cur.adding(1)
    }

    static func occurrence(of rule: RecurringRule, in month: MonthKey, calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(year: month.year, month: month.month, day: rule.dayOfMonth)) ?? month.start(calendar: calendar)
    }

    /// Posts every occurrence that has come due since the last run (the app may not have opened for weeks).
    /// Each rule advances in the same save as its transactions, so running twice never duplicates.
    @discardableResult
    static func postDueRecurring(_ rules: [RecurringRule], in context: ModelContext,
                                 now: Date = .now, calendar: Calendar = .current) throws -> Int {
        var posted = 0
        for rule in rules where rule.isActive && rule.amountCents > 0 {
            guard var month = MonthKey(string: rule.nextMonthKey) else { continue }
            var guardCount = 0
            while guardCount < maxRecurringCatchUpMonths {
                let when = occurrence(of: rule, in: month, calendar: calendar)
                guard when <= now else { break }
                context.insert(TransactionRecord(amountCents: rule.amountCents, kind: rule.kind, category: rule.category,
                                                 date: when, title: rule.title, notes: "Recurring"))
                month = month.adding(1)
                guardCount += 1
                posted += 1
            }
            rule.nextMonthKey = month.string
        }
        if context.hasChanges { try context.save() }
        return posted
    }

    // MARK: Goals

    /// Moves money between available cash and a goal. Never touches transactions.
    @discardableResult
    static func moveMoney(goal: SavingsGoal, cents: Int, withdraw: Bool, date: Date, note: String,
                          entries: [GoalEntry], affectsCash: Bool = true, accountID: UUID? = nil, accountAmountCents: Int = 0,
                          in context: ModelContext) throws -> GoalEntry {
        guard cents > 0, cents <= Money.maxCents else { throw LedgerError.invalidAmount }
        if withdraw, cents > FinanceEngine.balance(of: goal.id, entries: entries) {
            throw LedgerError.insufficientGoalBalance
        }
        let e = GoalEntry(goalID: goal.id, amountCents: withdraw ? -cents : cents, date: date,
                          note: note, affectsCash: affectsCash)
        e.accountID = accountID
        e.accountAmountCents = accountAmountCents
        context.insert(e)
        try context.save()
        return e
    }

    static func delete(_ goal: SavingsGoal, entries: [GoalEntry], costs: [TripCost], in context: ModelContext) throws {
        for e in entries where e.goalID == goal.id { context.delete(e) }
        for c in costs where c.goalID == goal.id { context.delete(c) }
        context.delete(goal)
        try context.save()
    }

    static func eraseEverything(in context: ModelContext) throws {
        try context.delete(model: TransactionRecord.self)
        try context.delete(model: MonthBudget.self)
        try context.delete(model: BudgetLimit.self)
        try context.delete(model: PlannedExpense.self)
        try context.delete(model: ShoppingItem.self)
        try context.delete(model: GoalEntry.self)
        try context.delete(model: TripCost.self)
        try context.delete(model: SavingsGoal.self)
        try context.delete(model: RecurringRule.self)
        try context.delete(model: Account.self)
        try context.delete(model: ExchangeRate.self)
        try context.delete(model: ReservedFund.self)
        try context.delete(model: MoneyCategory.self)
        try context.save()
        UserDefaults.standard.removeObject(forKey: "openingBalanceCents")
        UserDefaults.standard.removeObject(forKey: DefaultCategories.seededKey)
        DefaultCategories.seedIfNeeded(context)
        _ = try? AccountMigration.run(in: context, snapshotFirst: false)
    }
}
