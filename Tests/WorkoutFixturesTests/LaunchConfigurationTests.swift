import Foundation
import Testing

@testable import WorkoutFixtures

@Suite("Fixture launch configuration")
struct LaunchConfigurationTests {
  @Test("Environment variable selects the mode")
  func environmentSelectsMode() {
    #expect(
      FixtureLaunchConfiguration(arguments: [], environment: ["WORKOUT_FIXTURES_MODE": "live"])?
        .mode == .live)
    #expect(
      FixtureLaunchConfiguration(arguments: [], environment: ["WORKOUT_FIXTURES_MODE": "presets"])?
        .mode == .presets)
  }

  @Test("JSON mode requires a path")
  func jsonModeRequiresPath() {
    let configured = FixtureLaunchConfiguration(
      arguments: [],
      environment: [
        "WORKOUT_FIXTURES_MODE": "json",
        "WORKOUT_FIXTURES_PATH": "/tmp/archive.json",
      ]
    )
    #expect(configured?.mode == .json(URL(fileURLWithPath: "/tmp/archive.json")))
    #expect(
      FixtureLaunchConfiguration(arguments: [], environment: ["WORKOUT_FIXTURES_MODE": "json"])
        == nil)
  }

  @Test("Resource mode requires a resource name")
  func resourceModeRequiresName() {
    let configured = FixtureLaunchConfiguration(
      arguments: [],
      environment: [
        "WORKOUT_FIXTURES_MODE": "resource",
        "WORKOUT_FIXTURES_RESOURCE": "workout-fixtures-archive",
      ]
    )
    #expect(configured?.mode == .resource(name: "workout-fixtures-archive"))
    #expect(
      FixtureLaunchConfiguration(arguments: [], environment: ["WORKOUT_FIXTURES_MODE": "resource"])
        == nil)
  }

  @Test("Launch argument is a fallback for the mode variable")
  func launchArgumentFallback() {
    let configured = FixtureLaunchConfiguration(
      arguments: ["host-app", "--workout-fixtures", "presets"],
      environment: [:]
    )
    #expect(configured?.mode == .presets)

    let environmentWins = FixtureLaunchConfiguration(
      arguments: ["host-app", "--workout-fixtures", "presets"],
      environment: ["WORKOUT_FIXTURES_MODE": "live"]
    )
    #expect(environmentWins?.mode == .live)
  }

  @Test("Unconfigured or unknown modes return nil")
  func unknownModesReturnNil() {
    #expect(FixtureLaunchConfiguration(arguments: [], environment: [:]) == nil)
    #expect(
      FixtureLaunchConfiguration(arguments: [], environment: ["WORKOUT_FIXTURES_MODE": "wat"])
        == nil)
    #expect(FixtureLaunchConfiguration(arguments: ["--workout-fixtures"], environment: [:]) == nil)
  }
}
