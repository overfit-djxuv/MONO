import XCTest

final class MONOUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private var token = UUID().uuidString

    private func launch(reset: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        // Same token on a relaunch keeps the data; a new test gets a new token and a clean store.
        app.launchArguments = ["-MONOReset", token]
        _ = reset
        app.launch()
        return app
    }

    private func addExpense(_ app: XCUIApplication, amount: String, title: String) {
        app.tabBars.buttons["Transactions"].tap()
        let add = app.buttons["addTransaction"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        let amountField = app.textFields["amountField"].firstMatch
        XCTAssertTrue(amountField.waitForExistence(timeout: 5))
        amountField.tap()
        amountField.typeText(amount)
        let desc = app.textFields["descriptionField"].firstMatch
        desc.tap()
        desc.typeText(title)
        app.buttons["saveTransaction"].tap()
    }

    func testAddTransactionUpdatesBalanceAndSurvivesRestart() {
        var app = launch(reset: true)

        // Empty state on a fresh install
        app.tabBars.buttons["Transactions"].tap()
        XCTAssertTrue(app.staticTexts["No transactions yet"].waitForExistence(timeout: 5))

        addExpense(app, amount: "12.50", title: "Test lunch")
        XCTAssertTrue(app.staticTexts["Test lunch"].waitForExistence(timeout: 5), "new transaction is listed")

        // Dashboard recalculates immediately: opening balance 0 − 12.50
        app.tabBars.buttons["Overview"].tap()
        let cash = app.staticTexts["availableCash"]
        XCTAssertTrue(cash.waitForExistence(timeout: 5))
        XCTAssertEqual(cash.label, "−RM 12.50")

        // Persistence: kill the app and relaunch without resetting
        app.terminate()
        app = launch(reset: false)
        app.tabBars.buttons["Transactions"].tap()
        XCTAssertTrue(app.staticTexts["Test lunch"].waitForExistence(timeout: 5), "data persisted across restart")
        app.tabBars.buttons["Overview"].tap()
        XCTAssertEqual(app.staticTexts["availableCash"].label, "−RM 12.50")
    }

    func testDeleteRequiresConfirmation() {
        let app = launch(reset: true)
        addExpense(app, amount: "5", title: "Coffee")
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Coffee")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.swipeLeft(velocity: .slow)
        let swipeDelete = app.buttons["Delete"].firstMatch
        XCTAssertTrue(swipeDelete.waitForExistence(timeout: 3), "swipe reveals Delete")
        swipeDelete.tap()
        XCTAssertTrue(app.buttons["Delete"].waitForExistence(timeout: 3), "confirmation dialog appears")
        XCTAssertTrue(app.staticTexts["Coffee"].exists, "nothing deleted before confirming")
        app.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["No transactions yet"].waitForExistence(timeout: 5))
    }

    func testPlanTripAndAddMoneyMovesCashIntoGoal() {
        let app = launch(reset: true)
        app.tabBars.buttons["Goals"].tap()
        app.buttons["Plan a trip"].firstMatch.tap()
        let dest = app.textFields["goalName"].firstMatch
        XCTAssertTrue(dest.waitForExistence(timeout: 5))
        dest.tap(); dest.typeText("Kyoto")
        app.buttons["saveGoal"].tap()
        let row = app.staticTexts["Kyoto"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()

        app.buttons["addMoney"].tap()
        let amount = app.textFields["moveAmount"].firstMatch
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        amount.tap(); amount.typeText("100")
        app.buttons["saveMove"].tap()

        // Cash drops by 100 (opening balance is 0), and nothing shows up as an expense.
        app.tabBars.buttons["Overview"].tap()
        XCTAssertEqual(app.staticTexts["availableCash"].label, "−RM 100.00")
        app.tabBars.buttons["Transactions"].tap()
        XCTAssertTrue(app.staticTexts["No transactions yet"].waitForExistence(timeout: 5), "goal money is not an expense")
    }
}
