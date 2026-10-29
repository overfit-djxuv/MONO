import XCTest
@testable import MONO

final class ShoppingQuickAddTests: XCTestCase {
    func testNameOnly() { XCTAssertEqual(ShoppingQuickAdd.parse("Eggs"), .init(name: "Eggs", quantity: 1, priceCents: 0)) }
    func testOneNumberIsAPrice() { XCTAssertEqual(ShoppingQuickAdd.parse("Milk 4.50"), .init(name: "Milk", quantity: 1, priceCents: 450)) }
    func testTwoNumbersAreQuantityThenPrice() { XCTAssertEqual(ShoppingQuickAdd.parse("Milk 1L 2 4.50"), .init(name: "Milk 1L", quantity: 2, priceCents: 450)) }
    func testNumbersInsideTheNameStay() { XCTAssertEqual(ShoppingQuickAdd.parse("Rice 5kg 25")?.name, "Rice 5kg") }
    func testDecimalCommaWorks() { XCTAssertEqual(ShoppingQuickAdd.parse("Pan 1,20")?.priceCents, 120) }
    func testEmptyOrNumberOnlyIsRejected() { XCTAssertNil(ShoppingQuickAdd.parse("   ")); XCTAssertNil(ShoppingQuickAdd.parse("4.50")) }
    func testAbsurdQuantityIsRejected() { XCTAssertNil(ShoppingQuickAdd.parse("Milk 5000 4.50")) }
}
