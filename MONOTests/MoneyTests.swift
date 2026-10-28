import XCTest
@testable import MONO

final class MoneyTests: XCTestCase {
    override func setUp() { UserDefaults.standard.removeObject(forKey: "currencySymbol") }

    func testParseAcceptsCommonInput() {
        XCTAssertEqual(Money.parse("12"), 1200)
        XCTAssertEqual(Money.parse("12.5"), 1250)
        XCTAssertEqual(Money.parse("12.05"), 1205)
        XCTAssertEqual(Money.parse("1,200.00"), 120000)
        XCTAssertEqual(Money.parse("RM 40"), 4000)
        XCTAssertEqual(Money.parse(".5"), 50)
        XCTAssertEqual(Money.parse("5."), 500)
        XCTAssertEqual(Money.parse("0"), 0)
    }

    func testParseRejectsAmbiguousInput() {
        XCTAssertNil(Money.parse(""))
        XCTAssertNil(Money.parse("."))
        XCTAssertNil(Money.parse("abc"))
        XCTAssertNil(Money.parse("1.234"))     // never silently rounds
        XCTAssertNil(Money.parse("1.2.3"))
        XCTAssertNil(Money.parse("-5"))
        XCTAssertNil(Money.parse("1e5"))
        XCTAssertNil(Money.parse("999999999999")) // over the cap
    }

    func testFormat() {
        XCTAssertEqual(Money.format(0), "RM 0.00")
        XCTAssertEqual(Money.format(123456), "RM 1,234.56")
        XCTAssertEqual(Money.format(-5), "−RM 0.05")
        XCTAssertEqual(Money.format(5000, signed: true), "+RM 50.00")
        XCTAssertEqual(Money.formatWhole(123456), "RM 1,235")
    }

    func testCustomSymbol() {
        UserDefaults.standard.set("SGD", forKey: "currencySymbol")
        XCTAssertEqual(Money.format(100), "SGD 1.00")
        XCTAssertEqual(Money.parse("SGD 3"), 300)
    }

    func testEditableRoundTrip() {
        for c in [1, 99, 100, 12345, 99_999_999_99] {
            XCTAssertEqual(Money.parse(Money.editable(c)), c)
        }
        XCTAssertEqual(Money.editable(0), "")
    }

    func testAmountFieldSanitize() {
        XCTAssertEqual(AmountField.sanitize("12.345"), "12.34")
        XCTAssertEqual(AmountField.sanitize("1a2b"), "12")
        XCTAssertEqual(AmountField.sanitize("1,5"), "1.5")
        XCTAssertEqual(AmountField.sanitize("1..2"), "1.2")
    }

    func testMonthKey() {
        XCTAssertEqual(MonthKey(year: 2026, month: 12).adding(1), MonthKey(year: 2027, month: 1))
        XCTAssertEqual(MonthKey(year: 2026, month: 1).adding(-1), MonthKey(year: 2025, month: 12))
        XCTAssertEqual(MonthKey(string: "2026-03"), MonthKey(year: 2026, month: 3))
        XCTAssertNil(MonthKey(string: "2026-13"))
        XCTAssertEqual(MonthKey(year: 2026, month: 10).months(through: MonthKey(year: 2027, month: 1)).count, 4)
        XCTAssertTrue(MonthKey(year: 2026, month: 10).months(through: MonthKey(year: 2026, month: 9)).isEmpty)
        XCTAssertEqual(MonthKey(year: 2028, month: 2).daysInMonth(calendar: utc), 29)
    }
}
