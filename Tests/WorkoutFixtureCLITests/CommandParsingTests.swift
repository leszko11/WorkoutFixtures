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
