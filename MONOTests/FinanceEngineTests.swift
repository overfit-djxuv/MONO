import XCTest
@testable import MONO

final class FinanceEngineTests: XCTestCase {
    let oct = MonthKey(year: 2026, month: 10)

    // MARK: Balances

    func testAvailableCashFromOpeningIncomeAndExpenses() {
        let txs = [income(500_000, date(2026, 10, 1)), expense(12_000, date(2026, 10, 3)), expense(3_050, date(2026, 10, 4))]
        XCTAssertEqual(FinanceEngine.availableCash(opening: 100_000, transactions: txs, entries: []), 100_000 + 500_000 - 12_000 - 3_050)
    }

    func testGoalContributionMovesMoneyWithoutCreatingIncomeOrExpense() {
        let txs = [income(500_000, date(2026, 10, 1)), expense(100_000, date(2026, 10, 2))]
        let goal = UUID()
        let entries = [GoalEntry(goalID: goal, amountCents: 150_000, date: date(2026, 10, 5))]

        let before = FinanceEngine.availableCash(opening: 0, transactions: txs, entries: [])
        let after = FinanceEngine.availableCash(opening: 0, transactions: txs, entries: entries)
        XCTAssertEqual(before - after, 150_000, "cash falls by exactly the amount moved")

        let t = FinanceEngine.totals(txs, in: oct, calendar: utc)
        XCTAssertEqual(t.income, 500_000, "income unchanged")
        XCTAssertEqual(t.expense, 100_000, "expenses unchanged")

        XCTAssertEqual(after + FinanceEngine.savedTotal(entries: entries), before, "cash + saved is conserved")
    }

    func testWithdrawalReturnsCash() {
        let goal = UUID()
        let entries = [GoalEntry(goalID: goal, amountCents: 100_000, date: date(2026, 10, 5)),
                       GoalEntry(goalID: goal, amountCents: -30_000, date: date(2026, 10, 9))]
        XCTAssertEqual(FinanceEngine.availableCash(opening: 200_000, transactions: [], entries: entries), 130_000)
        XCTAssertEqual(FinanceEngine.balance(of: goal, entries: entries), 70_000)
    }

    func testExistingSavingsDoNotReduceCash() {
        let goal = UUID()
        let entries = [GoalEntry(goalID: goal, amountCents: 80_000, date: date(2026, 10, 5), affectsCash: false)]
        XCTAssertEqual(FinanceEngine.availableCash(opening: 200_000, transactions: [], entries: entries), 200_000)
        XCTAssertEqual(FinanceEngine.savedTotal(entries: entries), 80_000)
    }

    func testBalancePerGoalIsIsolated() {
        let a = UUID(), b = UUID()
        let entries = [GoalEntry(goalID: a, amountCents: 100, date: .now), GoalEntry(goalID: b, amountCents: 250, date: .now)]
        XCTAssertEqual(FinanceEngine.balance(of: a, entries: entries), 100)
        XCTAssertEqual(FinanceEngine.balance(of: b, entries: entries), 250)
    }

    // MARK: Monthly figures

    func testTotalsOnlyCountTheRequestedMonth() {
        let txs = [income(100, date(2026, 9, 30)), income(200, date(2026, 10, 1)), expense(50, date(2026, 10, 31)), expense(70, date(2026, 11, 1))]
        let t = FinanceEngine.totals(txs, in: oct, calendar: utc)
        XCTAssertEqual(t.income, 200)
        XCTAssertEqual(t.expense, 50)
    }

    func testSavingsRate() {
        XCTAssertEqual(FinanceEngine.savingsRate(income: 1000, expense: 750)!, 0.25, accuracy: 1e-9)
        XCTAssertEqual(FinanceEngine.savingsRate(income: 1000, expense: 1500)!, -0.5, accuracy: 1e-9)
        XCTAssertNil(FinanceEngine.savingsRate(income: 0, expense: 500), "no income → no rate, not 0%")
    }

    func testMonthlySummariesReportEmptyMonthsHonestly() {
        let txs = [income(1000, date(2026, 8, 2)), expense(400, date(2026, 10, 2))]
        let range = MonthKey(year: 2026, month: 8).months(through: oct)
        let s = FinanceEngine.monthlySummaries(txs, range: range, calendar: utc)
        XCTAssertEqual(s.map(\.recordCount), [1, 0, 1])
        XCTAssertEqual(s[1].income, 0)
        XCTAssertNil(s[1].savingsRate)
        XCTAssertEqual(s[0].savingsRate!, 1.0, accuracy: 1e-9)
    }

    func testFirstRecordMonthIsNilWithoutData() {
        XCTAssertNil(FinanceEngine.firstRecordMonth(transactions: [], calendar: utc))
        XCTAssertEqual(FinanceEngine.firstRecordMonth(transactions: [expense(1, date(2026, 3, 9)), expense(1, date(2026, 5, 1))], calendar: utc),
                       MonthKey(year: 2026, month: 3))
    }

    func testSavingsGrowthStartsAtFirstEntryAndNeverInventsHistory() {
        let g = UUID()
        let e = [GoalEntry(goalID: g, amountCents: 1000, date: date(2026, 8, 10)),
                 GoalEntry(goalID: g, amountCents: 500, date: date(2026, 10, 3)),
                 GoalEntry(goalID: g, amountCents: -200, date: date(2026, 10, 20))]
        let pts = FinanceEngine.savingsGrowth(entries: e, through: oct, calendar: utc)
        XCTAssertEqual(pts.map(\.cents), [1000, 1000, 1300])
        XCTAssertEqual(pts.first?.month, MonthKey(year: 2026, month: 8))
        XCTAssertTrue(FinanceEngine.savingsGrowth(entries: [], through: oct, calendar: utc).isEmpty)
    }

    func testExpensesByCategorySortedAndExcludesIncome() {
        let txs = [expense(300, date(2026, 10, 1), cat: "Food"), expense(900, date(2026, 10, 2), cat: "Shopping"),
                   expense(200, date(2026, 10, 3), cat: "Food"), income(5000, date(2026, 10, 1))]
        let r = FinanceEngine.expensesByCategory(txs, in: oct...oct, calendar: utc)
        XCTAssertEqual(r.map(\.category), ["Shopping", "Food"])
        XCTAssertEqual(r.map(\.cents), [900, 500])
    }

    // MARK: Budget

    func limit(_ cat: String, _ cents: Int) -> BudgetLimit { BudgetLimit(monthKey: "2026-10", category: cat, limitCents: cents) }

    func testBudgetSummaryFigures() {
        let txs = [expense(30_000, date(2026, 10, 2), cat: "Food"), expense(10_000, date(2026, 10, 9), cat: "Food"),
                   expense(5_000, date(2026, 10, 9), cat: "Other"), expense(99_999, date(2026, 9, 30), cat: "Food")]
        let s = FinanceEngine.budgetSummary(month: oct, totalLimit: 100_000, limits: [limit("Food", 50_000)],
                                            transactions: txs, today: date(2026, 10, 15), calendar: utc)
        XCTAssertEqual(s.spent, 45_000)
        XCTAssertEqual(s.remaining, 55_000)
        XCTAssertEqual(s.fraction!, 0.45, accuracy: 1e-9)
        XCTAssertEqual(s.overBy, 0)
        XCTAssertEqual(s.unbudgetedSpent, 5_000)
        XCTAssertEqual(s.daysLeft, 17, "Oct 15 through Oct 31 inclusive")
        XCTAssertEqual(s.dailyAllowance, 55_000 / 17)
        XCTAssertEqual(s.lines.count, 1)
        XCTAssertEqual(s.lines[0].spent, 40_000)
        XCTAssertEqual(s.lines[0].remaining, 10_000)
        XCTAssertEqual(s.lines[0].fraction, 0.8, accuracy: 1e-9)
        XCTAssertEqual(s.lines[0].state, .warning, "80% used is a warning")
        XCTAssertEqual(s.state, .ok)
    }

    func testOverBudgetState() {
        let txs = [expense(60_000, date(2026, 10, 2), cat: "Food")]
        let s = FinanceEngine.budgetSummary(month: oct, totalLimit: 50_000, limits: [limit("Food", 40_000)],
                                            transactions: txs, today: date(2026, 10, 10), calendar: utc)
        XCTAssertEqual(s.state, .over)
        XCTAssertEqual(s.overBy, 10_000)
        XCTAssertEqual(s.remaining, -10_000)
        XCTAssertEqual(s.dailyAllowance, 0, "no negative allowance")
        XCTAssertEqual(s.lines[0].state, .over)
        XCTAssertEqual(s.lines[0].overBy, 20_000)
    }

    func testExactlyAtLimitIsNotOver() {
        let l = BudgetLine(category: "Food", limit: 1000, spent: 1000)
        XCTAssertEqual(l.state, .warning)
        XCTAssertEqual(l.overBy, 0)
        XCTAssertEqual(BudgetLine(category: "Food", limit: 1000, spent: 1001).state, .over)
        XCTAssertEqual(BudgetLine(category: "Food", limit: 1000, spent: 799).state, .ok)
    }

    func testTotalFallsBackToSumOfLimitsThenNil() {
        let withLimits = FinanceEngine.budgetSummary(month: oct, totalLimit: nil, limits: [limit("Food", 300), limit("Other", 200)],
                                                     transactions: [], today: date(2026, 10, 1), calendar: utc)
        XCTAssertEqual(withLimits.total, 500)
        let none = FinanceEngine.budgetSummary(month: oct, totalLimit: nil, limits: [], transactions: [expense(10, date(2026, 10, 1))],
                                               today: date(2026, 10, 1), calendar: utc)
        XCTAssertNil(none.total)
        XCTAssertNil(none.remaining)
        XCTAssertNil(none.dailyAllowance)
    }

    func testPastAndFutureMonthDays() {
        let past = FinanceEngine.budgetSummary(month: MonthKey(year: 2026, month: 9), totalLimit: 1000, limits: [], transactions: [],
                                               today: date(2026, 10, 15), calendar: utc)
        XCTAssertEqual(past.daysLeft, 0)
        XCTAssertNil(past.dailyAllowance)
        let future = FinanceEngine.budgetSummary(month: MonthKey(year: 2026, month: 11), totalLimit: 3000, limits: [], transactions: [],
                                                 today: date(2026, 10, 15), calendar: utc)
        XCTAssertEqual(future.daysLeft, 30)
        XCTAssertEqual(future.dailyAllowance, 100)
    }

    func testLimitsFromOtherMonthsAreIgnored() {
        let other = BudgetLimit(monthKey: "2026-09", category: "Food", limitCents: 999)
        let s = FinanceEngine.budgetSummary(month: oct, totalLimit: nil, limits: [other], transactions: [], today: date(2026, 10, 1), calendar: utc)
        XCTAssertTrue(s.lines.isEmpty)
    }

    // MARK: Shopping

    func testShoppingTotals() {
        let a = ShoppingItem(name: "Eggs", quantity: 2, estimatedCents: 1200, category: "Groceries", priority: .high, listKind: .grocery)
        let b = ShoppingItem(name: "Rice", quantity: 1, estimatedCents: 2600, category: "Groceries", priority: .low, listKind: .grocery)
        let c = ShoppingItem(name: "Milk", quantity: 3, estimatedCents: 800, category: "Groceries", priority: .low, listKind: .grocery)
        c.isPurchased = true; c.actualCents = 900
        let d = ShoppingItem(name: "Bread", quantity: 1, estimatedCents: 500, category: "Groceries", priority: .low, listKind: .grocery)
        d.isPurchased = true // no actual price → falls back to the estimate
        let s = FinanceEngine.shoppingSummary([a, b, c, d])
        XCTAssertEqual(s.toBuy, 2 * 1200 + 2600)
        XCTAssertEqual(s.purchased, 3 * 900 + 500)
        XCTAssertEqual(s.toBuyCount, 2)
        XCTAssertEqual(s.purchasedCount, 2)
    }

    func testUpcomingExcludesPaidAndSortsByDate() {
        let p1 = PlannedExpense(title: "B", amountCents: 1, dueDate: date(2026, 11, 2), category: "Bills")
        let p2 = PlannedExpense(title: "A", amountCents: 1, dueDate: date(2026, 10, 30), category: "Bills")
        let p3 = PlannedExpense(title: "C", amountCents: 1, dueDate: date(2026, 10, 1), category: "Bills"); p3.isPaid = true
        XCTAssertEqual(FinanceEngine.upcoming([p1, p2, p3]).map(\.title), ["A", "B"])
    }
}
