import Foundation
import SwiftData

// MARK: - Enums

enum TxKind: String, Codable, CaseIterable, Identifiable {
    case income, expense
    /// Money moving between two of your own accounts. It is neither income nor expense and never appears in either total.
    case transfer
    var id: String { rawValue }
    var label: String {
        switch self { case .income: "Income"; case .expense: "Expense"; case .transfer: "Transfer" }
    }
    /// Kinds that belong to a category (transfers have none).
    static let categoryKinds: [TxKind] = [.income, .expense]
}

enum AccountKind: String, Codable, CaseIterable, Identifiable {
    case cash, bank, ewallet, other
    var id: String { rawValue }
    var label: String {
        switch self { case .cash: "Cash"; case .bank: "Bank"; case .ewallet: "E-wallet"; case .other: "Other" }
    }
    var symbol: String {
        switch self { case .cash: "banknote"; case .bank: "building.columns"; case .ewallet: "iphone"; case .other: "square.stack" }
    }
}

enum Priority: Int, Codable, CaseIterable, Identifiable {
    case low = 0, medium = 1, high = 2
    var id: Int { rawValue }
    var label: String { ["Low", "Medium", "High"][rawValue] }
}

enum ListKind: String, Codable, CaseIterable, Identifiable {
    case grocery, wishlist
    var id: String { rawValue }
    var label: String { self == .grocery ? "Groceries" : "Wishlist" }
}

/// How often a goal's planned contribution is made.
enum ContributionFrequency: String, Codable, CaseIterable, Identifiable {
    case weekly, biweekly, monthly
    var id: String { rawValue }
    var label: String {
        switch self { case .weekly: "Every week"; case .biweekly: "Every 2 weeks"; case .monthly: "Every month" }
    }
    var noun: String {
        switch self { case .weekly: "week"; case .biweekly: "fortnight"; case .monthly: "month" }
    }
    /// Days between contributions for the day-based frequencies.
    var stepDays: Int? { switch self { case .weekly: 7; case .biweekly: 14; case .monthly: nil } }
}

/// The unit a recurring payment repeats in. "Every 3 months" is unit `.month`, interval 3.
enum RecurrenceUnit: String, Codable, CaseIterable, Identifiable {
    case week, month, year
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum PaymentStatus: String, CaseIterable, Identifiable {
    case active, paused, cancelled
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum GoalKind: String, Codable, CaseIterable, Identifiable {
    case trip, general
    var id: String { rawValue }
}

enum TripCostCategory: String, Codable, CaseIterable, Identifiable {
    case flights, accommodation, food, transportation, activities, other
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .flights: "airplane"
        case .accommodation: "bed.double"
        case .food: "fork.knife"
        case .transportation: "tram"
        case .activities: "ticket"
        case .other: "ellipsis"
        }
    }
}

// MARK: - Models
// Relationships are held by UUID rather than SwiftData relationships so that backup, restore and
// deletion rules stay explicit and easy to test.

@Model final class MoneyCategory {
    var name: String = ""
    var symbol: String = "tag"
    var kindRaw: String = TxKind.expense.rawValue
    var isDefault: Bool = false
    var sortOrder: Int = 0
    /// Essential spending (rent, groceries, transport…): its remaining budget is held back by Safe to spend.
    var isEssential: Bool = false

    init(name: String, symbol: String, kind: TxKind, isDefault: Bool = false, sortOrder: Int = 0) {
        self.name = name
        self.symbol = symbol
        self.kindRaw = kind.rawValue
        self.isDefault = isDefault
        self.sortOrder = sortOrder
    }

    var kind: TxKind { TxKind(rawValue: kindRaw) ?? .expense }
}

@Model final class TransactionRecord {
    var id: UUID = UUID()
    var amountCents: Int = 0
    var kindRaw: String = TxKind.expense.rawValue
    var category: String = ""
    var date: Date = Date()
    var title: String = ""
    var notes: String = ""
    /// The shopping item or planned expense this transaction was generated from (duplicate guard).
    var sourceID: UUID? = nil
    /// The account this belongs to; for a transfer, the account the money left. nil means the default account (older records).
    var accountID: UUID? = nil
    /// Transfers only: the account the money arrived in, and how much arrived in that account's own currency.
    var toAccountID: UUID? = nil
    var toAmountCents: Int = 0
    var merchant: String = ""
    /// Comma-separated, lower-case tags.
    var tags: String = ""
    /// Set when this transaction records a scheduled payment: "<rule id>|<due date>". One key can exist only once,
    /// which is how confirming the same payment twice is prevented. Empty for ordinary transactions.
    var occurrenceKey: String = ""

    init(amountCents: Int, kind: TxKind, category: String, date: Date, title: String,
         notes: String = "", sourceID: UUID? = nil, id: UUID = UUID(),
         accountID: UUID? = nil, merchant: String = "", tags: String = "") {
        self.id = id
        self.amountCents = amountCents
        self.kindRaw = kind.rawValue
        self.category = category
        self.date = date
        self.title = title
        self.notes = notes
        self.sourceID = sourceID
        self.accountID = accountID
        self.merchant = merchant
        self.tags = tags
    }

    var kind: TxKind {
        get { TxKind(rawValue: kindRaw) ?? .expense }
        set { kindRaw = newValue.rawValue }
    }
}

@Model final class MonthBudget {
    var monthKey: String = ""
    var totalCents: Int = 0
    init(monthKey: String, totalCents: Int) {
        self.monthKey = monthKey
        self.totalCents = totalCents
    }
}

@Model final class BudgetLimit {
    var monthKey: String = ""
    var category: String = ""
    var limitCents: Int = 0
    init(monthKey: String, category: String, limitCents: Int) {
        self.monthKey = monthKey
        self.category = category
        self.limitCents = limitCents
    }
}

@Model final class PlannedExpense {
    var id: UUID = UUID()
    var title: String = ""
    var amountCents: Int = 0
    var dueDate: Date = Date()
    var category: String = ""
    var isPaid: Bool = false
    var paidTransactionID: UUID? = nil

    init(title: String, amountCents: Int, dueDate: Date, category: String, id: UUID = UUID()) {
        self.id = id
        self.title = title
        self.amountCents = amountCents
        self.dueDate = dueDate
        self.category = category
    }
}

@Model final class ShoppingItem {
    var id: UUID = UUID()
    var name: String = ""
    var quantity: Int = 1
    /// Prices are per unit.
    var estimatedCents: Int = 0
    var actualCents: Int? = nil
    var category: String = "Groceries"
    var priorityRaw: Int = Priority.medium.rawValue
    var isPurchased: Bool = false
    var listKindRaw: String = ListKind.grocery.rawValue
    var expenseID: UUID? = nil
    var createdAt: Date = Date()
    var purchasedAt: Date? = nil

    init(name: String, quantity: Int, estimatedCents: Int, category: String,
         priority: Priority, listKind: ListKind, id: UUID = UUID()) {
        self.id = id
        self.name = name
        self.quantity = quantity
        self.estimatedCents = estimatedCents
        self.category = category
        self.priorityRaw = priority.rawValue
        self.listKindRaw = listKind.rawValue
    }

    var priority: Priority {
        get { Priority(rawValue: priorityRaw) ?? .medium }
        set { priorityRaw = newValue.rawValue }
    }
    var listKind: ListKind { ListKind(rawValue: listKindRaw) ?? .grocery }
    var estimatedTotal: Int { quantity * estimatedCents }
    /// Actual price if known, otherwise the estimate.
    var effectiveTotal: Int { quantity * (actualCents ?? estimatedCents) }
}

@Model final class SavingsGoal {
    var id: UUID = UUID()
    var name: String = ""
    var kindRaw: String = GoalKind.general.rawValue
    var symbol: String = "target"
    /// Target for general goals. Trips derive their target from costs + buffer.
    var targetCents: Int = 0
    var deadline: Date? = nil
    var destination: String = ""
    var bufferCents: Int = 0
    var plannedMonthlyCents: Int = 0
    /// Day of month on which planned contributions are made (1–28).
    var contributionDay: Int = 1
    var createdAt: Date = Date()
    /// Optional description, e.g. why this goal matters.
    var details: String = ""
    var priorityRaw: Int = Priority.medium.rawValue
    /// Empty means "the reporting currency", so goals made before currencies existed keep following it.
    var currencyCode: String = ""
    var frequencyRaw: String = ContributionFrequency.monthly.rawValue
    /// Where the contribution schedule starts counting from (weekly and fortnightly schedules align to it). nil = created date.
    var startDate: Date? = nil

    init(name: String, kind: GoalKind, symbol: String, id: UUID = UUID()) {
        self.id = id
        self.name = name
        self.kindRaw = kind.rawValue
        self.symbol = symbol
    }

    var kind: GoalKind { GoalKind(rawValue: kindRaw) ?? .general }
    var priority: Priority {
        get { Priority(rawValue: priorityRaw) ?? .medium }
        set { priorityRaw = newValue.rawValue }
    }
    var frequency: ContributionFrequency {
        get { ContributionFrequency(rawValue: frequencyRaw) ?? .monthly }
        set { frequencyRaw = newValue.rawValue }
    }
    var currency: Currency { currencyCode.isEmpty ? Money.reporting : Currency.find(currencyCode) }
    var scheduleStart: Date { startDate ?? createdAt }

    /// An amount in this goal's own currency, e.g. "¥ 120,000".
    func money(_ cents: Int, signed: Bool = false) -> String { Money.format(cents, signed: signed, currency: currencyCode.isEmpty ? nil : currency) }
}

/// A signed movement into (+) or out of (−) a goal.
@Model final class GoalEntry {
    var id: UUID = UUID()
    var goalID: UUID = UUID()
    var amountCents: Int = 0
    var date: Date = Date()
    var note: String = ""
    /// False for money that was already saved before using MONO (does not reduce available cash).
    var affectsCash: Bool = true
    /// The account the money came from (or returned to). nil means the default account.
    var accountID: UUID? = nil
    /// When the account's currency differs from the goal's, how much the account paid, in the account's own currency.
    /// 0 means the account amount equals `amountCents`.
    var accountAmountCents: Int = 0
    /// What leaves (or returns to) the account.
    var accountDelta: Int { accountAmountCents != 0 ? (amountCents < 0 ? -abs(accountAmountCents) : abs(accountAmountCents)) : amountCents }

    init(goalID: UUID, amountCents: Int, date: Date, note: String = "",
         affectsCash: Bool = true, id: UUID = UUID()) {
        self.id = id
        self.goalID = goalID
        self.amountCents = amountCents
        self.date = date
        self.note = note
        self.affectsCash = affectsCash
    }
}

@Model final class TripCost {
    var id: UUID = UUID()
    var goalID: UUID = UUID()
    var categoryRaw: String = TripCostCategory.other.rawValue
    var label: String = ""
    var amountCents: Int = 0

    init(goalID: UUID, category: TripCostCategory, label: String, amountCents: Int, id: UUID = UUID()) {
        self.id = id
        self.goalID = goalID
        self.categoryRaw = category.rawValue
        self.label = label
        self.amountCents = amountCents
    }

    var category: TripCostCategory { TripCostCategory(rawValue: categoryRaw) ?? .other }
}

/// A monthly income or expense that posts itself as a normal transaction on its day.
/// Deleting a posted transaction never re-posts it: progress is tracked by `nextMonthKey`, not by looking for records.
/// A subscription, bill or other repeating payment (or income). It is a SCHEDULE, not a transaction: nothing is recorded or deducted
/// until you confirm a payment, and each confirmed occurrence becomes an ordinary transaction.
@Model final class RecurringRule {
    var id: UUID = UUID()
    var title: String = ""
    var amountCents: Int = 0
    var kindRaw: String = TxKind.expense.rawValue
    var category: String = ""
    /// The day of the month the payment falls on (1–31, clamped to the month's length). Anchors monthly and yearly schedules.
    var dayOfMonth: Int = 1
    /// Kept in step with `nextDueDate` for older code paths.
    var nextMonthKey: String = ""
    /// False while paused or cancelled.
    var isActive: Bool = true
    var unitRaw: String = RecurrenceUnit.month.rawValue
    var interval: Int = 1
    /// The next payment that has not been confirmed. nil only on rules made before this field existed (filled in at launch).
    var nextDueDate: Date? = nil
    var isCancelled: Bool = false
    var notes: String = ""
    /// The account that pays (or receives). Amounts are in that account's currency. nil means the default account.
    var accountID: UUID? = nil
    /// How many days before the due date to remind (0 = on the day).
    var remindDaysBefore: Int = 1

    init(title: String, amountCents: Int, kind: TxKind, category: String, dayOfMonth: Int,
         nextMonthKey: String, isActive: Bool = true, id: UUID = UUID()) {
        self.id = id
        self.title = title
        self.amountCents = amountCents
        self.kindRaw = kind.rawValue
        self.category = category
        self.dayOfMonth = dayOfMonth
        self.nextMonthKey = nextMonthKey
        self.isActive = isActive
    }

    var kind: TxKind {
        get { TxKind(rawValue: kindRaw) ?? .expense }
        set { kindRaw = newValue.rawValue }
    }
    var unit: RecurrenceUnit {
        get { RecurrenceUnit(rawValue: unitRaw) ?? .month }
        set { unitRaw = newValue.rawValue }
    }
    var status: PaymentStatus { isCancelled ? .cancelled : (isActive ? .active : .paused) }

    /// When the next unconfirmed payment falls due.
    var dueDate: Date {
        if let d = nextDueDate { return d }
        guard let m = MonthKey(string: nextMonthKey) else { return .now }
        return Calendar.current.date(from: DateComponents(year: m.year, month: m.month, day: min(max(dayOfMonth, 1), m.daysInMonth()))) ?? .now
    }
}

/// Where money lives: a wallet, a bank account, an e-wallet. Balances are always in the account's own currency.
@Model final class Account {
    var id: UUID = UUID()
    var name: String = ""
    var kindRaw: String = AccountKind.bank.rawValue
    var currencyCode: String = "MYR"
    var openingCents: Int = 0
    var sortOrder: Int = 0
    /// Archived accounts are hidden from pickers but their balance still counts, so money never disappears.
    var isArchived: Bool = false
    var createdAt: Date = Date()

    init(name: String, kind: AccountKind, currencyCode: String, openingCents: Int = 0, sortOrder: Int = 0, id: UUID = UUID()) {
        self.id = id
        self.name = name
        self.kindRaw = kind.rawValue
        self.currencyCode = currencyCode
        self.openingCents = openingCents
        self.sortOrder = sortOrder
    }

    var kind: AccountKind { AccountKind(rawValue: kindRaw) ?? .other }
    var currency: Currency { Currency.find(currencyCode) }
}

/// A rate the user entered: 1 `fromCode` = `rateMicros / 1,000,000` `toCode`. The app never fetches rates.
@Model final class ExchangeRate {
    var fromCode: String = ""
    var toCode: String = ""
    var rateMicros: Int = 0
    var updatedAt: Date = Date()

    init(fromCode: String, toCode: String, rateMicros: Int, updatedAt: Date = .now) {
        self.fromCode = fromCode
        self.toCode = toCode
        self.rateMicros = rateMicros
        self.updatedAt = updatedAt
    }
}

/// Money you want kept out of Safe to spend even though it sits in an account (an emergency buffer, rent for next month…).
/// Amounts are in the reporting currency.
@Model final class ReservedFund {
    var id: UUID = UUID()
    var name: String = ""
    var amountCents: Int = 0
    var isActive: Bool = true
    var createdAt: Date = Date()

    init(name: String, amountCents: Int, isActive: Bool = true, id: UUID = UUID()) {
        self.id = id
        self.name = name
        self.amountCents = amountCents
        self.isActive = isActive
    }
}

enum AppSchema {
    static let models: [any PersistentModel.Type] = [
        MoneyCategory.self, TransactionRecord.self, MonthBudget.self, BudgetLimit.self,
        PlannedExpense.self, ShoppingItem.self, SavingsGoal.self, GoalEntry.self, TripCost.self, RecurringRule.self,
        Account.self, ExchangeRate.self, ReservedFund.self, Receipt.self,
    ]
}

// MARK: - Defaults

enum DefaultCategories {
    static let expense: [(String, String)] = [
        ("Food", "fork.knife"), ("Groceries", "cart"), ("Transportation", "car"),
        ("Education", "book"), ("Shopping", "bag"), ("Entertainment", "film"),
        ("Subscriptions", "arrow.triangle.2.circlepath"), ("Travel", "airplane"),
        ("Health", "cross.case"), ("Bills", "doc.text"), ("Other", "ellipsis"),
    ]
    static let income: [(String, String)] = [
        ("Salary", "banknote"), ("Freelance", "laptopcomputer"), ("Gift", "gift"), ("Other Income", "plus.circle"),
    ]

    static let seededKey = "didSeedCategories"
    static let essentialSeededKey = "didSeedEssentialCategories.v1"
    /// Spending most people cannot skip. Only a starting point: every category's switch is yours to change.
    static let essentialDefaults: Set<String> = ["Groceries", "Transportation", "Bills", "Health"]

    /// One-time: mark the usual essentials on categories made before the Essential switch existed. Never touches custom categories.
    static func seedEssentialsIfNeeded(_ context: ModelContext, defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: essentialSeededKey) else { return }
        let all = (try? context.fetch(FetchDescriptor<MoneyCategory>())) ?? []
        guard !all.isEmpty else { return }   // nothing to mark yet; fresh categories are created with the flag
        for c in all where c.isDefault && c.kind == .expense && essentialDefaults.contains(c.name) { c.isEssential = true }
        try? context.save()
        defaults.set(true, forKey: essentialSeededKey)
    }

    static func seedIfNeeded(_ context: ModelContext) {
        guard !UserDefaults.standard.bool(forKey: seededKey) else { return }
        let existing = (try? context.fetchCount(FetchDescriptor<MoneyCategory>())) ?? 0
        if existing == 0 {
            for (i, c) in expense.enumerated() {
                let m = MoneyCategory(name: c.0, symbol: c.1, kind: .expense, isDefault: true, sortOrder: i)
                m.isEssential = essentialDefaults.contains(c.0)
                context.insert(m)
            }
            for (i, c) in income.enumerated() {
                context.insert(MoneyCategory(name: c.0, symbol: c.1, kind: .income, isDefault: true, sortOrder: 100 + i))
            }
            try? context.save()
        }
        UserDefaults.standard.set(true, forKey: seededKey)
        UserDefaults.standard.set(true, forKey: essentialSeededKey)
    }
}

// MARK: - Receipts

/// A captured receipt. The photo lives in a file (see ReceiptStore); everything here is text you can search and edit.
@Model final class Receipt {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var merchant: String = ""
    var date: Date = Date()
    var totalCents: Int = 0
    var taxCents: Int = 0
    var currencyCode: String = ""
    /// The scan language the user chose: auto, en, es, ms or my (Burmese: photo only, entered by hand).
    var languageRaw: String = "auto"
    var imageFile: String = ""
    var imageHash: String = ""
    var ocrText: String = ""
    /// JSON `[ReceiptItem]`: possible line items found by the scan. Informational only.
    var itemsJSON: String = ""
    var notes: String = ""
    var category: String = ""
    /// The transaction this receipt belongs to, if any.
    var transactionID: UUID? = nil
    var needsReview: Bool = false

    init(id: UUID = UUID()) { self.id = id }
}
