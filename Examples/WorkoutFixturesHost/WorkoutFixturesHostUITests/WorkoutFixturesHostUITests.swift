import XCTest

@MainActor
final class WorkoutFixturesHostUITests: XCTestCase {
  private func launchApp(arguments: [String] = []) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = arguments
    app.launch()
    XCTAssertTrue(app.navigationBars["Workout Fixtures"].waitForExistence(timeout: 5))
    return app
  }

  // The frame equality assertions guard the UILaunchScreen Info.plist key:
  // without it the app renders letterboxed instead of full screen.
  func testUsesFullScreenAndOffersFixtureImport() {
    let app = launchApp()

    let window = app.windows.firstMatch
    XCTAssertTrue(window.waitForExistence(timeout: 5))
    XCTAssertEqual(window.frame.width, app.frame.width, accuracy: 1)
    XCTAssertEqual(window.frame.height, app.frame.height, accuracy: 1)
    XCTAssertTrue(app.buttons["importFixtureFile"].exists)
  }

  func testBundledFixtureLaunchArgumentPreloadsFixture() {
    let app = launchApp(arguments: ["--bundled-fixture"])

    let fixtureID = app.descendants(matching: .any)["fixtureID"]
    XCTAssertTrue(fixtureID.waitForExistence(timeout: 5))

    let writeButton = app.buttons["writeFixture"]
    if !writeButton.waitForExistence(timeout: 2) {
      app.swipeUp()
    }
    XCTAssertTrue(writeButton.waitForExistence(timeout: 5))
    XCTAssertTrue(writeButton.isEnabled)
  }

  func testBundledFixtureLoadsFromButton() {
    let app = launchApp()

    let loadButton = app.buttons["loadBundledFixture"]
    XCTAssertTrue(loadButton.waitForExistence(timeout: 5))
    loadButton.tap()

    let fixtureID = app.descendants(matching: .any)["fixtureID"]
    XCTAssertTrue(fixtureID.waitForExistence(timeout: 5))
  }
}
