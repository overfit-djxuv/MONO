import XCTest
import SwiftData
@testable import MONO

@MainActor
final class LedgerTests: XCTestCase {
    var container: ModelContainer!
    var context: ModelContext!

    override func setUpWithError() throws {
        (container, context) = try makeContext()
    }

    private func txCount() throws -> Int { try context.fetchCount(FetchDescriptor<TransactionRecord>()) }
    private func allTx() throws -> [TransactionRecord] { try context.fetch(FetchDescriptor<TransactionRecord>()) }

    func item(_ price: Int = 1200, qty: Int = 2) -> ShoppingItem {
        let i = ShoppingItem(name: "Eggs", quantity: qty, estimatedCents: price, category: "Groceries", priority: .medium, listKind: .grocery)
        context.insert(i)
        return i
    }

    // MARK: Shopping → expense

    func testRecordingPurchaseCreatesExactlyOneExpense() throws {
        let i = item()
        i.actualCents = 1350
        let tx = try Ledger.recordPurchase(i, existing: try allTx(), in: context)
        XCTAssertEqual(tx.amountCents, 2 * 1350)
        XCTAssertEqual(tx.kind, .expense)
        XCTAssertEqual(tx.category, "Groceries")
        XCTAssertEqual(tx.sourceID, i.id)
        XCTAssertEqual(i.expenseID, tx.id)
        XCTAssertTrue(i.isPurchased)
        XCTAssertEqual(try txCount(), 1)
    }

    func testRecordingTwiceIsRefused() throws {
        let i = item()
        try Ledger.recordPurchase(i, existing: try allTx(), in: context)
        XCTAssertThrowsError(try Ledger.recordPurchase(i, existing: try allTx(), in: context)) {
            XCTAssertEqual($0 as? Ledger.LedgerError, .alreadyRecorded)
        }
        XCTAssertEqual(try txCount(), 1, "no duplicate expense")
    }

    func testDuplicateIsCaughtEvenIfItemLinkWasLost() throws {
        let i = item()
        try Ledger.recordPurchase(i, existing: try allTx(), in: context)
        i.expenseID = nil // simulate a restored/edited item that lost its link
        XCTAssertFalse(Ledger.canRecord(i, existing: try allTx()), "the transaction’s sourceID still blocks it")
        XCTAssertThrowsError(try Ledger.recordPurchase(i, existing: try allTx(), in: context))
        XCTAssertEqual(try txCount(), 1)
    }

    func testUnpurchasingAndRepurchasingDoesNotDuplicate() throws {
        let i = item()
        try Ledger.recordPurchase(i, existing: try allTx(), in: context)
        i.isPurchased = false
        i.isPurchased = true
        XCTAssertFalse(Ledger.canRecord(i, existing: try allTx()))
    }

    func testZeroPriceCannotBeRecorded() throws {
        let i = item(0)
        XCTAssertThrowsError(try Ledger.recordPurchase(i, existing: [], in: context)) {
            XCTAssertEqual($0 as? Ledger.LedgerError, .invalidAmount)
        }
        XCTAssertEqual(try txCount(), 0)
    }

    func testDeletingGeneratedExpenseUnlinksItem() throws {
        let i = item()
        let tx = try Ledger.recordPurchase(i, existing: [], in: context)
        try Ledger.delete(tx, items: [i], planned: [], in: context)
        XCTAssertNil(i.expenseID)
        XCTAssertEqual(try txCount(), 0)
        XCTAssertTrue(Ledger.canRecord(i, existing: try allTx()), "can be recorded again on purpose")
        try Ledger.recordPurchase(i, existing: try allTx(), in: context)
        XCTAssertEqual(try txCount(), 1)
    }

    // MARK: Planned expense

    func testMarkingPlannedPaidIsOneShot() throws {
        let p = PlannedExpense(title: "Insurance", amountCents: 98_000, dueDate: .now, category: "Bills")
        context.insert(p)
        let tx = try Ledger.markPaid(p, existing: [], in: context)
        XCTAssertTrue(p.isPaid)
        XCTAssertEqual(p.paidTransactionID, tx.id)
        XCTAssertThrowsError(try Ledger.markPaid(p, existing: try allTx(), in: context))
        XCTAssertEqual(try txCount(), 1)
    }

    func testDeletingPaidExpenseReopensPlanned() throws {
        let p = PlannedExpense(title: "Insurance", amountCents: 98_000, dueDate: .now, category: "Bills")
        context.insert(p)
        let tx = try Ledger.markPaid(p, existing: [], in: context)
        try Ledger.delete(tx, items: [], planned: [p], in: context)
        XCTAssertFalse(p.isPaid)
        XCTAssertNil(p.paidTransactionID)
    }

    // MARK: Goals

    func testMovingMoneyIntoAGoalNeverCreatesTransactions() throws {
        let g = SavingsGoal(name: "Trip", kind: .trip, symbol: "airplane"); context.insert(g)
        context.insert(income(500_000, date(2026, 10, 1)))
        try context.save()
        let before = FinanceEngine.availableCash(opening: 0, transactions: try allTx(), entries: [])

        let e = try Ledger.moveMoney(goal: g, cents: 120_000, withdraw: false, date: date(2026, 10, 2), note: "", entries: [], in: context)
        let entries = try context.fetch(FetchDescriptor<GoalEntry>())
        XCTAssertEqual(try txCount(), 1, "still only the salary")
        XCTAssertEqual(e.amountCents, 120_000)
        XCTAssertEqual(FinanceEngine.availableCash(opening: 0, transactions: try allTx(), entries: entries), before - 120_000)
        XCTAssertEqual(FinanceEngine.balance(of: g.id, entries: entries), 120_000)
    }

    func testWithdrawMoreThanBalanceIsRefused() throws {
        let g = SavingsGoal(name: "Trip", kind: .trip, symbol: "airplane"); context.insert(g)
        let e1 = try Ledger.moveMoney(goal: g, cents: 10_000, withdraw: false, date: .now, note: "", entries: [], in: context)
        XCTAssertThrowsError(try Ledger.moveMoney(goal: g, cents: 10_001, withdraw: true, date: .now, note: "", entries: [e1], in: context)) {
            XCTAssertEqual($0 as? Ledger.LedgerError, .insufficientGoalBalance)
        }
        let w = try Ledger.moveMoney(goal: g, cents: 4_000, withdraw: true, date: .now, note: "", entries: [e1], in: context)
        XCTAssertEqual(w.amountCents, -4_000)
    }

    func testInvalidAmountsRefused() throws {
        let g = SavingsGoal(name: "Trip", kind: .trip, symbol: "airplane"); context.insert(g)
        for bad in [0, -5, Money.maxCents + 1] {
            XCTAssertThrowsError(try Ledger.moveMoney(goal: g, cents: bad, withdraw: false, date: .now, note: "", entries: [], in: context))
        }
    }

    func testDeletingGoalRemovesItsEntriesAndCostsAndReturnsCash() throws {
        let g = SavingsGoal(name: "Trip", kind: .trip, symbol: "airplane"); context.insert(g)
        let other = SavingsGoal(name: "Other", kind: .general, symbol: "target"); context.insert(other)
        context.insert(TripCost(goalID: g.id, category: .flights, label: "", amountCents: 1000))
        try Ledger.moveMoney(goal: g, cents: 5_000, withdraw: false, date: .now, note: "", entries: [], in: context)
        try Ledger.moveMoney(goal: other, cents: 2_000, withdraw: false, date: .now, note: "", entries: [], in: context)
        let entries = try context.fetch(FetchDescriptor<GoalEntry>())
        let costs = try context.fetch(FetchDescriptor<TripCost>())
        try Ledger.delete(g, entries: entries, costs: costs, in: context)

        let left = try context.fetch(FetchDescriptor<GoalEntry>())
        XCTAssertEqual(left.count, 1)
        XCTAssertEqual(left[0].goalID, other.id)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TripCost>()), 0)
        XCTAssertEqual(FinanceEngine.availableCash(opening: 10_000, transactions: [], entries: left), 8_000,
                       "the 5,000 that was in the deleted goal is back in cash")
    }
}

@MainActor
final class BackupTests: XCTestCase {
    private func populated() throws -> (ModelContainer, ModelContext) {
        let (c, ctx) = try makeContext()
        ctx.insert(MoneyCategory(name: "Food", symbol: "fork.knife", kind: .expense, isDefault: true, sortOrder: 0))
        ctx.insert(income(520_000, date(2026, 10, 1)))
        let tx = expense(1850, date(2026, 10, 3), cat: "Food"); tx.title = "Lunch, \"team\""; tx.notes = "line1\nline2"
        ctx.insert(tx)
        ctx.insert(MonthBudget(monthKey: "2026-10", totalCents: 250_000))
        ctx.insert(BudgetLimit(monthKey: "2026-10", category: "Food", limitCents: 60_000))
        ctx.insert(PlannedExpense(title: "Insurance", amountCents: 98_000, dueDate: date(2026, 11, 10), category: "Bills"))
        let item = ShoppingItem(name: "Eggs", quantity: 2, estimatedCents: 1200, category: "Groceries", priority: .high, listKind: .grocery)
        item.actualCents = 1300; item.isPurchased = true
        ctx.insert(item)
        let trip = SavingsGoal(name: "Tokyo", kind: .trip, symbol: "airplane")
        trip.deadline = date(2027, 6, 30); trip.plannedMonthlyCents = 60_000; trip.bufferCents = 50_000; trip.destination = "Tokyo"
        ctx.insert(trip)
        ctx.insert(TripCost(goalID: trip.id, category: .flights, label: "JAL", amountCents: 220_000))
        ctx.insert(GoalEntry(goalID: trip.id, amountCents: 50_000, date: date(2026, 9, 5), note: "n"))
        ctx.insert(GoalEntry(goalID: trip.id, amountCents: 20_000, date: date(2026, 8, 5), affectsCash: false))
        try ctx.save()
        return (c, ctx)
    }

    func normalized(_ f: BackupFile) -> BackupFile {
        var n = f; n.exportedAt = Date(timeIntervalSince1970: 0)
        n.transactions.sort { $0.id.uuidString < $1.id.uuidString }
        return n
    }

    func testRoundTripPreservesEverything() throws {
        let (c1, ctx1) = try populated(); _ = c1
        let original = try BackupService.snapshot(context: ctx1, openingBalanceCents: 123_456, currencySymbol: "RM")
        let data = try BackupService.encode(original)
        let decoded = try BackupService.decode(data)

        let (c2, ctx2) = try makeContext(); _ = c2
        ctx2.insert(expense(999, .now)) // pre-existing record that must be replaced
        try ctx2.save()
        try BackupService.replaceAll(with: decoded, in: ctx2)

        let restored = try BackupService.snapshot(context: ctx2, openingBalanceCents: UserDefaults.standard.integer(forKey: "openingBalanceCents"), currencySymbol: "RM")
        XCTAssertEqual(normalized(restored).transactions, normalized(decoded).transactions)
        XCTAssertEqual(restored.goals, decoded.goals)
        XCTAssertEqual(restored.goalEntries.sorted { $0.amountCents < $1.amountCents }, decoded.goalEntries.sorted { $0.amountCents < $1.amountCents })
        XCTAssertEqual(restored.tripCosts, decoded.tripCosts)
        XCTAssertEqual(restored.shoppingItems, decoded.shoppingItems)
        XCTAssertEqual(restored.plannedExpenses, decoded.plannedExpenses)
        XCTAssertEqual(restored.monthBudgets, decoded.monthBudgets)
        XCTAssertEqual(restored.budgetLimits, decoded.budgetLimits)
        XCTAssertEqual(restored.categories, decoded.categories)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "openingBalanceCents"), 123_456)
        XCTAssertEqual(try ctx2.fetchCount(FetchDescriptor<TransactionRecord>()), 2, "the pre-existing record was replaced")
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try BackupService.decode(Data("not json".utf8))) { XCTAssertEqual($0 as? BackupError, .unreadable) }
        XCTAssertThrowsError(try BackupService.decode(Data("{}".utf8)))
    }

    private func mutated(_ change: (inout BackupFile) -> Void) throws -> Data {
        var f = BackupFile()
        let g = UUID()
        f.goals = [.init(id: g, name: "G", kind: "general", symbol: "target", targetCents: 100, deadline: nil, destination: "",
                         bufferCents: 0, plannedMonthlyCents: 0, contributionDay: 1, createdAt: .now)]
        f.goalEntries = [.init(id: UUID(), goalID: g, amountCents: 50, date: .now, note: "", affectsCash: true)]
        f.transactions = [.init(id: UUID(), amountCents: 100, kind: "expense", category: "Food", date: .now, title: "", notes: "", sourceID: nil)]
        change(&f)
        return try BackupService.encode(f)
    }

    func testValidFileThatIsMinimalPasses() throws {
        XCTAssertNoThrow(try BackupService.decode(try mutated { _ in }))
    }

    func testRejectsWrongApp() throws {
        XCTAssertThrowsError(try BackupService.decode(try mutated { $0.app = "Other" })) { XCTAssertEqual($0 as? BackupError, .notMONOBackup) }
    }

    func testRejectsNewerVersion() throws {
        XCTAssertThrowsError(try BackupService.decode(try mutated { $0.version = 99 })) { XCTAssertEqual($0 as? BackupError, .newerVersion(99)) }
    }

    func testRejectsInvalidRecords() throws {
        let cases: [(inout BackupFile) -> Void] = [
            { $0.transactions[0].amountCents = 0 },
            { $0.transactions[0].amountCents = -5 },
            { $0.transactions[0].kind = "transfer" },
            { $0.transactions.append($0.transactions[0]) },                       // duplicate id
            { $0.goalEntries[0].goalID = UUID() },                                 // orphan entry
            { $0.goalEntries[0].amountCents = -500 },                              // negative goal balance
            { $0.goals[0].contributionDay = 31 },
            { $0.goals[0].kind = "vacation" },
            { $0.monthBudgets = [.init(monthKey: "oops", totalCents: 1)] },
            { $0.budgetLimits = [.init(monthKey: "2026-10", category: "Food", limitCents: -1)] },
            { $0.shoppingItems = [.init(id: UUID(), name: "x", quantity: 0, estimatedCents: 1, actualCents: nil, category: "c", priority: 1, isPurchased: false, listKind: "grocery", expenseID: nil, createdAt: .now, purchasedAt: nil)] },
            { $0.tripCosts = [.init(id: UUID(), goalID: UUID(), category: "flights", label: "", amountCents: 1)] },
        ]
        for (i, change) in cases.enumerated() {
            XCTAssertThrowsError(try BackupService.decode(try mutated(change)), "case \(i) should be rejected")
        }
    }

    // MARK: CSV

    func testCSVEscapesAndNeutralisesFormulas() {
        let t = expense(123_45, date(2026, 10, 3), cat: "Food"); t.title = "Lunch, \"team\""; t.notes = "=HYPERLINK(\"x\")"
        let csv = BackupService.csv(transactions: [t])
        let lines = csv.components(separatedBy: "\r\n")
        XCTAssertEqual(lines[0], "date,type,category,description,amount,notes")
        XCTAssertTrue(lines[1].hasPrefix("2026-10-03,expense,Food,\"Lunch, \"\"team\"\"\",123.45,"), lines[1])
        XCTAssertTrue(lines[1].contains("'=HYPERLINK"), "formula text is prefixed so spreadsheets don’t run it")
    }

    func testCSVAmountsAreExact() {
        let csv = BackupService.csv(transactions: [expense(5, date(2026, 1, 1)), income(100, date(2026, 1, 2)), expense(Money.maxCents, date(2026, 1, 3))])
        XCTAssertTrue(csv.contains(",0.05,"))
        XCTAssertTrue(csv.contains(",1.00,"))
        XCTAssertTrue(csv.contains(",999999999.99,"))
    }

    func testCSVOrdersByDate() {
        let csv = BackupService.csv(transactions: [expense(1, date(2026, 3, 1)), expense(2, date(2026, 1, 1))])
        let rows = csv.components(separatedBy: "\r\n").dropFirst()
        XCTAssertTrue(rows.first!.hasPrefix("2026-01-01"))
    }
}
