import ArgumentParser
import Testing

@testable import WorkoutFixtureCLI

@Suite("CLI parsing")
struct CommandParsingTests {
  @Test(
    "Every public command parses",
    arguments: [
      ["inspect", "fixture.json"],
      ["validate", "fixture.json", "--diagnostics-format", "json"],
      ["redact", "fixture.json", "--output", "redacted.json", "--seed", "42"],
      [
        "generate", "fixture.json", "--recipe", "recipe.json", "--count", "3", "--seed", "42",
        "--output-directory", "output",
      ],
      ["migrate", "fixture.json", "--output", "migrated.json"],
      ["split", "archive.json", "--output-directory", "output"],
      ["split", "archive.json", "--output-directory", "output", "--redact", "--seed", "42"],
      ["schema", "fixture"],
      ["schema", "archive"],
      ["schema", "recipe"],
      ["import-gpx", "track.gpx", "--output", "fixture.json"],
      [
        "import-gpx", "track.gpx", "--output", "fixture.json", "--activity", "cycling",
        "--location", "outdoor", "--time-zone", "Europe/Warsaw", "--no-distance-series",
      ],
    ])
  func parses(_ arguments: [String]) throws {
    _ = try WorkoutFixtureCommand.parseAsRoot(arguments)
  }

  @Test("Missing required arguments are usage errors")
  func missingArgumentsFail() {
    #expect(throws: (any Error).self) {
      _ = try WorkoutFixtureCommand.parseAsRoot(["generate"])
    }
  }
}
