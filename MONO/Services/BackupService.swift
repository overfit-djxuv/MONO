import Foundation
import SwiftData

struct BackupFile: Codable, Equatable {
    static let currentVersion = 1

    var app = "MONO"
    var version = BackupFile.currentVersion
    var exportedAt = Date()
    var openingBalanceCents = 0
    var currencySymbol = "RM"
    var categories: [CategoryDTO] = []
    var transactions: [TransactionDTO] = []
    var monthBudgets: [MonthBudgetDTO] = []
    var budgetLimits: [BudgetLimitDTO] = []
    var plannedExpenses: [PlannedDTO] = []
    var shoppingItems: [ShoppingDTO] = []
    var goals: [GoalDTO] = []
    var goalEntries: [GoalEntryDTO] = []
    var tripCosts: [TripCostDTO] = []
    /// Optional so backups made before recurring transactions existed still restore.
    var recurringRules: [RecurringDTO]? = nil

    struct RecurringDTO: Codable, Equatable {
        var id: UUID; var title: String; var amountCents: Int; var kind: String; var category: String
        var dayOfMonth: Int; var nextMonthKey: String; var isActive: Bool
    }
    struct CategoryDTO: Codable, Equatable { var name, symbol, kind: String; var isDefault: Bool; var sortOrder: Int }
    struct TransactionDTO: Codable, Equatable {
        var id: UUID; var amountCents: Int; var kind: String; var category: String
        var date: Date; var title: String; var notes: String; var sourceID: UUID?
    }
    struct MonthBudgetDTO: Codable, Equatable { var monthKey: String; var totalCents: Int }
    struct BudgetLimitDTO: Codable, Equatable { var monthKey, category: String; var limitCents: Int }
    struct PlannedDTO: Codable, Equatable {
        var id: UUID; var title: String; var amountCents: Int; var dueDate: Date
        var category: String; var isPaid: Bool; var paidTransactionID: UUID?
    }
    struct ShoppingDTO: Codable, Equatable {
        var id: UUID; var name: String; var quantity: Int; var estimatedCents: Int; var actualCents: Int?
        var category: String; var priority: Int; var isPurchased: Bool; var listKind: String
        var expenseID: UUID?; var createdAt: Date; var purchasedAt: Date?
    }
    struct GoalDTO: Codable, Equatable {
        var id: UUID; var name: String; var kind: String; var symbol: String; var targetCents: Int
        var deadline: Date?; var destination: String; var bufferCents: Int
        var plannedMonthlyCents: Int; var contributionDay: Int; var createdAt: Date
    }
    struct GoalEntryDTO: Codable, Equatable {
        var id: UUID; var goalID: UUID; var amountCents: Int; var date: Date; var note: String; var affectsCash: Bool
    }
    struct TripCostDTO: Codable, Equatable {
        var id: UUID; var goalID: UUID; var category: String; var label: String; var amountCents: Int
    }

    var recordCount: Int {
        transactions.count + monthBudgets.count + budgetLimits.count + plannedExpenses.count
            + shoppingItems.count + goals.count + goalEntries.count + tripCosts.count + (recurringRules?.count ?? 0)
    }
}

enum BackupError: LocalizedError, Equatable {
    case unreadable
    case notMONOBackup
    case newerVersion(Int)
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .unreadable: "The file could not be read as a MONO backup."
        case .notMONOBackup: "This file is not a MONO backup."
        case .newerVersion(let v): "This backup was made by a newer version of MONO (format \(v)). Update the app and try again."
        case .invalid(let why): "The backup is damaged: \(why)"
        }
    }
}

enum BackupService {
    // MARK: Export

    static func snapshot(context: ModelContext, openingBalanceCents: Int, currencySymbol: String) throws -> BackupFile {
        var f = BackupFile()
        f.openingBalanceCents = openingBalanceCents
        f.currencySymbol = currencySymbol
        f.categories = try context.fetch(FetchDescriptor<MoneyCategory>(sortBy: [SortDescriptor(\.sortOrder)]))
            .map { .init(name: $0.name, symbol: $0.symbol, kind: $0.kindRaw, isDefault: $0.isDefault, sortOrder: $0.sortOrder) }
        f.transactions = try context.fetch(FetchDescriptor<TransactionRecord>(sortBy: [SortDescriptor(\.date)]))
            .map { .init(id: $0.id, amountCents: $0.amountCents, kind: $0.kindRaw, category: $0.category,
                         date: $0.date, title: $0.title, notes: $0.notes, sourceID: $0.sourceID) }
        f.monthBudgets = try context.fetch(FetchDescriptor<MonthBudget>()).map { .init(monthKey: $0.monthKey, totalCents: $0.totalCents) }
        f.budgetLimits = try context.fetch(FetchDescriptor<BudgetLimit>())
            .map { .init(monthKey: $0.monthKey, category: $0.category, limitCents: $0.limitCents) }
        f.plannedExpenses = try context.fetch(FetchDescriptor<PlannedExpense>())
            .map { .init(id: $0.id, title: $0.title, amountCents: $0.amountCents, dueDate: $0.dueDate,
                         category: $0.category, isPaid: $0.isPaid, paidTransactionID: $0.paidTransactionID) }
        f.shoppingItems = try context.fetch(FetchDescriptor<ShoppingItem>())
            .map { .init(id: $0.id, name: $0.name, quantity: $0.quantity, estimatedCents: $0.estimatedCents,
                         actualCents: $0.actualCents, category: $0.category, priority: $0.priorityRaw,
                         isPurchased: $0.isPurchased, listKind: $0.listKindRaw, expenseID: $0.expenseID,
                         createdAt: $0.createdAt, purchasedAt: $0.purchasedAt) }
        f.goals = try context.fetch(FetchDescriptor<SavingsGoal>())
            .map { .init(id: $0.id, name: $0.name, kind: $0.kindRaw, symbol: $0.symbol, targetCents: $0.targetCents,
                         deadline: $0.deadline, destination: $0.destination, bufferCents: $0.bufferCents,
                         plannedMonthlyCents: $0.plannedMonthlyCents, contributionDay: $0.contributionDay,
                         createdAt: $0.createdAt) }
        f.goalEntries = try context.fetch(FetchDescriptor<GoalEntry>(sortBy: [SortDescriptor(\.date)]))
            .map { .init(id: $0.id, goalID: $0.goalID, amountCents: $0.amountCents, date: $0.date,
                         note: $0.note, affectsCash: $0.affectsCash) }
        f.tripCosts = try context.fetch(FetchDescriptor<TripCost>())
            .map { .init(id: $0.id, goalID: $0.goalID, category: $0.categoryRaw, label: $0.label, amountCents: $0.amountCents) }
        f.recurringRules = try context.fetch(FetchDescriptor<RecurringRule>())
            .map { .init(id: $0.id, title: $0.title, amountCents: $0.amountCents, kind: $0.kindRaw, category: $0.category,
                         dayOfMonth: $0.dayOfMonth, nextMonthKey: $0.nextMonthKey, isActive: $0.isActive) }
        return f
    }

    // ISO-8601 with fractional seconds so ordering by creation time survives a round trip.
    // Decoding also accepts whole-second timestamps.
    private static func makeFormatter(fractional: Bool) -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return f
    }

    static func encode(_ file: BackupFile) throws -> Data {
        let e = JSONEncoder()
        let withFraction = makeFormatter(fractional: true)
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(withFraction.string(from: date))
        }
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(file)
    }

    // MARK: Import (validate first, apply second)

    static func decode(_ data: Data) throws -> BackupFile {
        let d = JSONDecoder()
        let withFraction = makeFormatter(fractional: true), whole = makeFormatter(fractional: false)
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            if let date = withFraction.date(from: s) ?? whole.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "Invalid date \(s)"))
        }
        let file: BackupFile
        do { file = try d.decode(BackupFile.self, from: data) } catch { throw BackupError.unreadable }
        guard file.app == "MONO" else { throw BackupError.notMONOBackup }
        guard file.version <= BackupFile.currentVersion else { throw BackupError.newerVersion(file.version) }
        try validate(file)
        return file
    }

    static func validate(_ f: BackupFile) throws {
        func fail(_ s: String) -> BackupError { .invalid(s) }
        let cap = Money.maxCents
        guard f.version >= 1 else { throw fail("unknown format version") }
        guard (0...cap).contains(abs(f.openingBalanceCents)) else { throw fail("opening balance is out of range") }

        guard Set(f.transactions.map(\.id)).count == f.transactions.count else { throw fail("duplicate transaction ids") }
        for t in f.transactions {
            guard TxKind(rawValue: t.kind) != nil else { throw fail("transaction with unknown type “\(t.kind)”") }
            guard (1...cap).contains(t.amountCents) else { throw fail("transaction amount out of range") }
        }
        for b in f.monthBudgets {
            guard MonthKey(string: b.monthKey) != nil, (0...cap).contains(b.totalCents) else { throw fail("invalid monthly budget") }
        }
        for l in f.budgetLimits {
            guard MonthKey(string: l.monthKey) != nil, (0...cap).contains(l.limitCents) else { throw fail("invalid category limit") }
        }
        for p in f.plannedExpenses { guard (0...cap).contains(p.amountCents) else { throw fail("invalid planned expense") } }
        for s in f.shoppingItems {
            guard ListKind(rawValue: s.listKind) != nil, Priority(rawValue: s.priority) != nil,
                  (1...9999).contains(s.quantity), (0...cap).contains(s.estimatedCents),
                  (s.actualCents.map { (0...cap).contains($0) } ?? true) else { throw fail("invalid shopping item “\(s.name)”") }
        }
        let goalIDs = Set(f.goals.map(\.id))
        guard goalIDs.count == f.goals.count else { throw fail("duplicate goal ids") }
        for g in f.goals {
            guard GoalKind(rawValue: g.kind) != nil, (0...cap).contains(g.targetCents), (0...cap).contains(g.bufferCents),
                  (0...cap).contains(g.plannedMonthlyCents), (1...28).contains(g.contributionDay) else { throw fail("invalid goal “\(g.name)”") }
        }
        for e in f.goalEntries {
            guard goalIDs.contains(e.goalID) else { throw fail("a contribution refers to a goal that is not in the file") }
            guard abs(e.amountCents) <= cap else { throw fail("contribution out of range") }
        }
        for c in f.tripCosts {
            guard goalIDs.contains(c.goalID), TripCostCategory(rawValue: c.category) != nil,
                  (0...cap).contains(c.amountCents) else { throw fail("invalid trip cost") }
        }
        let ruleIDs = (f.recurringRules ?? []).map(\.id)
        guard Set(ruleIDs).count == ruleIDs.count else { throw fail("duplicate recurring ids") }
        for r in f.recurringRules ?? [] {
            guard TxKind(rawValue: r.kind) != nil, (1...cap).contains(r.amountCents), (1...28).contains(r.dayOfMonth),
                  MonthKey(string: r.nextMonthKey) != nil else { throw fail("invalid recurring transaction “\(r.title)”") }
        }
        // Every goal's balance must be non-negative, otherwise the file would invent debt.
        var balances: [UUID: Int] = [:]
        for e in f.goalEntries { balances[e.goalID, default: 0] += e.amountCents }
        if balances.values.contains(where: { $0 < 0 }) { throw fail("a goal would have a negative balance") }
    }

    /// Replaces all existing records. Rolls back completely on failure.
    static func replaceAll(with f: BackupFile, in context: ModelContext) throws {
        do {
            try context.delete(model: TransactionRecord.self)
            try context.delete(model: MonthBudget.self)
            try context.delete(model: BudgetLimit.self)
            try context.delete(model: PlannedExpense.self)
            try context.delete(model: ShoppingItem.self)
            try context.delete(model: GoalEntry.self)
            try context.delete(model: TripCost.self)
            try context.delete(model: SavingsGoal.self)
            try context.delete(model: RecurringRule.self)
            try context.delete(model: MoneyCategory.self)

            for c in f.categories {
                context.insert(MoneyCategory(name: c.name, symbol: c.symbol, kind: TxKind(rawValue: c.kind) ?? .expense,
                                             isDefault: c.isDefault, sortOrder: c.sortOrder))
            }
            for t in f.transactions {
                context.insert(TransactionRecord(amountCents: t.amountCents, kind: TxKind(rawValue: t.kind) ?? .expense,
                                                 category: t.category, date: t.date, title: t.title, notes: t.notes,
                                                 sourceID: t.sourceID, id: t.id))
            }
            for b in f.monthBudgets { context.insert(MonthBudget(monthKey: b.monthKey, totalCents: b.totalCents)) }
            for l in f.budgetLimits { context.insert(BudgetLimit(monthKey: l.monthKey, category: l.category, limitCents: l.limitCents)) }
            for p in f.plannedExpenses {
                let m = PlannedExpense(title: p.title, amountCents: p.amountCents, dueDate: p.dueDate, category: p.category, id: p.id)
                m.isPaid = p.isPaid; m.paidTransactionID = p.paidTransactionID
                context.insert(m)
            }
            for s in f.shoppingItems {
                let m = ShoppingItem(name: s.name, quantity: s.quantity, estimatedCents: s.estimatedCents, category: s.category,
                                     priority: Priority(rawValue: s.priority) ?? .medium,
                                     listKind: ListKind(rawValue: s.listKind) ?? .grocery, id: s.id)
                m.actualCents = s.actualCents; m.isPurchased = s.isPurchased; m.expenseID = s.expenseID
                m.createdAt = s.createdAt; m.purchasedAt = s.purchasedAt
                context.insert(m)
            }
            for g in f.goals {
                let m = SavingsGoal(name: g.name, kind: GoalKind(rawValue: g.kind) ?? .general, symbol: g.symbol, id: g.id)
                m.targetCents = g.targetCents; m.deadline = g.deadline; m.destination = g.destination
                m.bufferCents = g.bufferCents; m.plannedMonthlyCents = g.plannedMonthlyCents
                m.contributionDay = g.contributionDay; m.createdAt = g.createdAt
                context.insert(m)
            }
            for e in f.goalEntries {
                context.insert(GoalEntry(goalID: e.goalID, amountCents: e.amountCents, date: e.date, note: e.note,
                                         affectsCash: e.affectsCash, id: e.id))
            }
            for c in f.tripCosts {
                context.insert(TripCost(goalID: c.goalID, category: TripCostCategory(rawValue: c.category) ?? .other,
                                        label: c.label, amountCents: c.amountCents, id: c.id))
            }
            for r in f.recurringRules ?? [] {
                context.insert(RecurringRule(title: r.title, amountCents: r.amountCents, kind: TxKind(rawValue: r.kind) ?? .expense,
                                             category: r.category, dayOfMonth: r.dayOfMonth, nextMonthKey: r.nextMonthKey,
                                             isActive: r.isActive, id: r.id))
            }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        UserDefaults.standard.set(f.openingBalanceCents, forKey: "openingBalanceCents")
        UserDefaults.standard.set(f.currencySymbol, forKey: "currencySymbol")
        UserDefaults.standard.set(true, forKey: DefaultCategories.seededKey)
    }

    // MARK: Backup freshness

    static let staleAfterDays = 7

    /// True when there is data worth protecting and no backup in the last `staleAfterDays` days.
    static func isBackupStale(lastBackup: Date?, hasData: Bool, now: Date = .now, calendar: Calendar = .current) -> Bool {
        guard hasData else { return false }
        guard let last = lastBackup else { return true }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: last), to: calendar.startOfDay(for: now)).day ?? 0
        return days >= staleAfterDays
    }

    // MARK: CSV

    static func csv(transactions: [TransactionRecord]) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        var lines = ["date,type,category,description,amount,notes"]
        for t in transactions.sorted(by: { $0.date < $1.date }) {
            let amount = String(format: "%d.%02d", t.amountCents / 100, t.amountCents % 100)
            lines.append([df.string(from: t.date), t.kindRaw, cell(t.category), cell(t.title), amount, cell(t.notes)].joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// RFC 4180 quoting, plus a leading apostrophe on formula-like text so spreadsheets don't execute it.
    static func cell(_ s: String) -> String {
        var v = s
        if let c = v.first, "=+-@\t\r".contains(c) { v = "'" + v }
        if v.contains(where: { ",\"\r\n".contains($0) }) { v = "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        return v
    }
}
