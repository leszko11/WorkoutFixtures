import XCTest

@MainActor
final class WorkoutFixturesHostUITests: XCTestCase {
  func testUsesFullScreenAndOffersFixtureImport() {
    let app = XCUIApplication()
    app.launch()

    XCTAssertTrue(app.navigationBars["Workout Fixtures"].waitForExistence(timeout: 5))
    let window = app.windows.firstMatch
    XCTAssertTrue(window.waitForExistence(timeout: 5))
    XCTAssertEqual(window.frame.width, app.frame.width, accuracy: 1)
    XCTAssertEqual(window.frame.height, app.frame.height, accuracy: 1)
    XCTAssertTrue(app.buttons["importFixtureFile"].exists)
  }

  func testBundledFixturePreview() {
    let app = XCUIApplication()
    app.launch()

    XCTAssertTrue(app.navigationBars["Workout Fixtures"].waitForExistence(timeout: 5))
    app.buttons["loadBundledFixture"].tap()
    let fixtureID = app.descendants(matching: .any)["fixtureID"]
    XCTAssertTrue(fixtureID.waitForExistence(timeout: 5))
    app.swipeUp()
    let writeButton = app.buttons["writeFixture"]
    XCTAssertTrue(writeButton.waitForExistence(timeout: 5))
    XCTAssertTrue(writeButton.isEnabled)
  }
}
