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
        case cancelledPayment

        var errorDescription: String? {
            switch self {
            case .alreadyRecorded: "This has already been recorded."
            case .invalidAmount: "Enter an amount greater than zero."
            case .insufficientGoalBalance: "That is more than the goal currently holds."
            case .sameAccount: "Choose two different accounts."
            case .archivedAccount: "That account is archived. Choose another one."
            case .transferAmountMismatch: "Both accounts use the same currency, so the amount received must equal the amount sent."
            case .cancelledPayment: "This payment is cancelled. Restart it first."
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

    // MARK: Subscriptions and recurring payments

    /// Records one due payment as a real transaction. This is the ONLY way a schedule creates money movement: nothing is
    /// deducted until you confirm. The occurrence key makes confirming the same payment twice impossible, and the schedule moves
    /// to the next payment only if the save succeeds.
    @discardableResult
    static func recordPayment(of rule: RecurringRule, paidOn: Date = .now, amountCents: Int? = nil, accountID: UUID? = nil,
                              existing: [TransactionRecord], in context: ModelContext, calendar: Calendar = .current) throws -> TransactionRecord {
        guard !rule.isCancelled else { throw LedgerError.cancelledPayment }
        let due = rule.dueDate
        let key = rule.occurrenceKey(for: due, calendar: calendar)
        guard !existing.contains(where: { $0.occurrenceKey == key }) else { throw LedgerError.alreadyRecorded }
        let cents = amountCents ?? rule.amountCents
        guard (1...Money.maxCents).contains(cents) else { throw LedgerError.invalidAmount }
        let tx = TransactionRecord(amountCents: cents, kind: rule.kind, category: rule.category, date: paidOn, title: rule.title,
                                   notes: rule.notes, accountID: accountID ?? rule.accountID)
        tx.occurrenceKey = key
        context.insert(tx)
        advance(rule, calendar: calendar)
        do { try context.save() } catch { context.rollback(); throw error }
        return tx
    }

    /// Skips one payment (you didn't pay it, or it was waived): the schedule moves on and no transaction is created.
    static func skipPayment(of rule: RecurringRule, in context: ModelContext, calendar: Calendar = .current) throws {
        guard !rule.isCancelled else { throw LedgerError.cancelledPayment }
        advance(rule, calendar: calendar)
        try context.save()
    }

    static func pause(_ rule: RecurringRule, in context: ModelContext) throws {
        rule.isActive = false
        try context.save()
    }

    /// Resumes a paused or cancelled payment from its next occurrence on or after today. Nothing missed in between is owed or recorded.
    static func resume(_ rule: RecurringRule, today: Date = .now, in context: ModelContext, calendar: Calendar = .current) throws {
        rule.isCancelled = false
        rule.isActive = true
        rule.nextDueDate = SubscriptionSchedule.firstOnOrAfter(today, from: rule.dueDate, unit: rule.unit, interval: rule.interval,
                                                                anchorDay: rule.anchorDay, calendar: calendar)
        syncLegacyFields(rule, calendar: calendar)
        try context.save()
    }

    /// Cancels a payment. It stays in your list for history, but never comes due again and isn't counted in forecasts.
    static func cancel(_ rule: RecurringRule, in context: ModelContext) throws {
        rule.isCancelled = true
        rule.isActive = false
        try context.save()
    }

    private static func advance(_ rule: RecurringRule, calendar: Calendar) {
        rule.nextDueDate = rule.following(rule.dueDate, calendar: calendar)
        syncLegacyFields(rule, calendar: calendar)
    }

    /// Keeps `nextMonthKey` and `dayOfMonth` aligned with the real next date so older code paths still agree.
    static func syncLegacyFields(_ rule: RecurringRule, calendar: Calendar = .current) {
        let d = rule.dueDate
        rule.nextMonthKey = MonthKey(d, calendar: calendar).string
    }

    /// Fills `nextDueDate` for rules saved before schedules had real dates, and gives them an account. Changes nothing else.
    @discardableResult
    static func upgradeLegacyRules(_ rules: [RecurringRule], defaultAccountID: UUID?, in context: ModelContext) throws -> Bool {
        var changed = false
        for r in rules {
            if r.nextDueDate == nil { r.nextDueDate = r.dueDate; changed = true }
            if r.accountID == nil, let id = defaultAccountID { r.accountID = id; changed = true }
        }
        if changed { try context.save() }
        return changed
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
        try context.delete(model: Receipt.self)
        try context.save()
        ReceiptStore.pruneOrphans(context: context)
        UserDefaults.standard.removeObject(forKey: "openingBalanceCents")
        UserDefaults.standard.removeObject(forKey: DefaultCategories.seededKey)
        DefaultCategories.seedIfNeeded(context)
        _ = try? AccountMigration.run(in: context, snapshotFirst: false)
    }
}
