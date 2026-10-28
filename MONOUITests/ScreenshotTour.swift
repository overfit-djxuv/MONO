import XCTest

/// Walks through the main screens with sample data and saves PNGs to ~/MONO/screenshots.
/// Not a pass/fail test of behaviour; run on demand: -only-testing:MONOUITests/ScreenshotTour
final class ScreenshotTour: XCTestCase {
    let out = URL(fileURLWithPath: "/Users/you/MONO/screenshots", isDirectory: true)
    var app: XCUIApplication!
    var n = 0

    override func setUp() {
        continueAfterFailure = true
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }

    private func shot(_ name: String) {
        n += 1
        Thread.sleep(forTimeInterval: 0.7)
        try? app.screenshot().pngRepresentation.write(to: out.appendingPathComponent(String(format: "%02d-%@.png", n, name)))
    }

    private func tap(_ e: XCUIElement) { if e.waitForExistence(timeout: 4) { e.tap() } }

    func testTour() {
        app = XCUIApplication()
        app.launchArguments = ["-MONOReset", UUID().uuidString, "-MONODemo"]
        app.launch()
        sleep(2)

        shot("overview")
        app.swipeUp(); shot("overview-charts")
        app.swipeUp(); shot("overview-recent")

        tap(app.tabBars.buttons["Transactions"]); shot("transactions")
        sleep(1)
        tap(app.buttons["addTransaction"].firstMatch)
        _ = app.textFields["amountField"].firstMatch.waitForExistence(timeout: 5)
        shot("add-transaction")
        tap(app.buttons["Cancel"])

        tap(app.tabBars.buttons["Budget"]); shot("budget")
        app.swipeUp(); shot("budget-planned")

        tap(app.tabBars.buttons["Shopping"]); shot("shopping-groceries")
        tap(app.buttons["Wishlist"]); shot("shopping-wishlist")

        tap(app.tabBars.buttons["Goals"]); shot("goals")
        tap(app.staticTexts["Tokyo"].firstMatch); shot("trip-detail")
        app.swipeUp(); shot("trip-costs-history")
        app.swipeDown()
        tap(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Compare plans'")).firstMatch)
        _ = app.navigationBars["Compare plans"].waitForExistence(timeout: 5)
        shot("compare-plans")
        tap(app.buttons["Close"])
        app.navigationBars.buttons.firstMatch.tap()

        tap(app.tabBars.buttons["Overview"])
        tap(app.buttons["Analytics"].firstMatch)
        shot("analytics-1")
        for i in 2...5 { app.swipeUp(); shot("analytics-\(i)") }
        app.navigationBars.buttons.firstMatch.tap()

        tap(app.buttons["Settings"]); shot("settings")
    }
}
