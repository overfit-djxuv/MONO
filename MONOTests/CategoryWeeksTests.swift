import XCTest
@testable import MONO

final class CategoryWeeksTests: XCTestCase {
    private func tx(_ day: Int, _ cents: Int, cat: String = "Food", month: Int = 10, kind: TxKind = .expense) -> TransactionRecord {
        TransactionRecord(amountCents: cents, kind: kind, category: cat, date: Calendar.current.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!, title: "")
    }
    private let oct = MonthKey(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 15))!)

    func testWeeksSplitOnTheSeventhFourteenthTwentyFirstAndTwentyEighth() {
        let r = CategoryWeeks.spend([tx(1, 100), tx(7, 10), tx(8, 200), tx(14, 20), tx(15, 300), tx(21, 30), tx(22, 400), tx(28, 40), tx(29, 500), tx(31, 50)], category: "Food", month: oct)
        XCTAssertEqual(r, [110, 220, 330, 440, 550])
    }
    func testOtherCategoriesMonthsAndNonExpensesAreIgnored() {
        let r = CategoryWeeks.spend([tx(3, 100), tx(3, 999, cat: "Fun"), tx(3, 999, month: 9), tx(3, 999, kind: .income), tx(3, 999, kind: .transfer)], category: "Food", month: oct)
        XCTAssertEqual(r, [100, 0, 0, 0, 0])
    }
    func testWeeksNotYetStartedAreMarked() {
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 10))!
        XCTAssertTrue(CategoryWeeks.started(1, month: oct, now: now))
        XCTAssertFalse(CategoryWeeks.started(2, month: oct, now: now))
        XCTAssertTrue(CategoryWeeks.started(4, month: oct.adding(-1), now: now))
    }
}
