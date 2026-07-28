import XCTest

final class GithuluUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testEmptyRepositoryStateIsAccessible() {
        let app = XCUIApplication()
        app.launchArguments.append("-ui-testing")
        app.launch()

        XCTAssertTrue(app.navigationBars["Githulu"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Add repository"].exists)
    }

    func testAccountControlHasAccessibleLabel() {
        let app = XCUIApplication()
        app.launchArguments.append("-ui-testing")
        app.launch()

        XCTAssertTrue(app.buttons["Sign in to GitHub"].waitForExistence(timeout: 5))
    }
}
