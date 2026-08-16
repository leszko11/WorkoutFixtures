import ArgumentParser
import Foundation
import Testing
import WorkoutFixtures
import WorkoutFixturesTestSupport

@testable import WorkoutFixtureCLI

@Suite("CLI run behavior")
struct CommandRunTests {
  @Test("Validate exits with failure status for an invalid fixture")
  func validateFailsOnInvalidFixture() async throws {
    let workspace = try Workspace()
    let path = try workspace.writeInvalidFixture()

    await #expect(throws: ExitCode.failure) {
      try await runCommand(["validate", path])
    }
    #expect(WorkoutFixtureCommand.exitCode(for: ExitCode.failure).rawValue == 1)
  }

  @Test("Validate accepts a valid archive and reports errors with fixtures[i] paths")
  func validateHandlesArchives() async throws {
    let workspace = try Workspace()
    let valid = try workspace.writeArchive(fixtures: WorkoutFixturePreset.allFixtures())
    try await runCommand(["validate", valid])

    let invalid = try workspace.writeArchive(fixtures: [Workspace.invalidFixture()])
    await #expect(throws: ExitCode.failure) {
      try await runCommand(["validate", invalid])
    }
  }

  @Test("Usage errors exit with status 64")
  func usageErrorsUseExitCode64() throws {
    let candidates: [[String]] = [
      ["generate"],
      [
        "generate", "template.json", "--recipe", "recipe.json", "--count", "0",
        "--seed", "42", "--output-directory", "out",
      ],
      ["split", "archive.json", "--output-directory", "out", "--redact"],
    ]
    for arguments in candidates {
      do {
        _ = try WorkoutFixtureCommand.parseAsRoot(arguments)
        Issue.record("Expected a usage error for \(arguments)")
      } catch {
        #expect(WorkoutFixtureCommand.exitCode(for: error).rawValue == 64)
      }
    }
  }

  @Test("Redact writes deterministic output and refuses archives")
  func redactIsDeterministic() async throws {
    let workspace = try Workspace()
    let input = try workspace.writeFixture(WorkoutFixturePreset.outdoorRun.fixture())
    let firstOutput = workspace.path("first.json")
    let secondOutput = workspace.path("second.json")

    try await runCommand(["redact", input, "--output", firstOutput, "--seed", "42"])
    try await runCommand(["redact", input, "--output", secondOutput, "--seed", "42"])

    let first = try Data(contentsOf: URL(fileURLWithPath: firstOutput))
    let second = try Data(contentsOf: URL(fileURLWithPath: secondOutput))
    #expect(first == second)
    #expect(try FixtureJSONCodec().decode(first).provenance.kind == .redacted)

    let archive = try workspace.writeArchive(fixtures: WorkoutFixturePreset.allFixtures())
    await #expect(throws: ExitCode.failure) {
      try await runCommand(["redact", archive, "--output", workspace.path("x.json"), "--seed", "1"])
    }
  }

  @Test("Migrate validates before writing")
  func migrateValidates() async throws {
    let workspace = try Workspace()
    let valid = try workspace.writeFixture(WorkoutFixturePreset.outdoorRun.fixture())
    let output = workspace.path("migrated.json")
    try await runCommand(["migrate", valid, "--output", output])
    #expect(FileManager.default.fileExists(atPath: output))

    let invalid = try workspace.writeInvalidFixture()
    await #expect(throws: ExitCode.failure) {
      try await runCommand(["migrate", invalid, "--output", workspace.path("bad.json")])
    }
  }

  @Test("Generate uses the strict recipe codec and the example recipe file")
  func generateUsesExampleRecipe() async throws {
    let workspace = try Workspace()
    let template = try workspace.writeFixture(WorkoutFixturePreset.outdoorRun.fixture())
    let outputDirectory = workspace.path("generated")

    try await runCommand([
      "generate", template, "--recipe", Self.exampleRecipePath, "--count", "2",
      "--seed", "42", "--output-directory", outputDirectory,
    ])

    let files = try FileManager.default.contentsOfDirectory(atPath: outputDirectory).sorted()
    #expect(files.count == 2)
    for file in files {
      let data = try Data(contentsOf: URL(fileURLWithPath: outputDirectory + "/" + file))
      let fixture = try FixtureJSONCodec().decode(data)
      #expect(WorkoutValidator().validate(fixture).contains { $0.severity == .error } == false)
    }
  }

  @Test("Generate rejects recipes with unknown fields")
  func generateRejectsUnknownRecipeFields() async throws {
    let workspace = try Workspace()
    let template = try workspace.writeFixture(WorkoutFixturePreset.outdoorRun.fixture())
    let recipePath = workspace.path("recipe.json")
    let recipeJSON = """
      {"transforms": [{"kind": "addNoise", "metric": "heartRate", "stdDev": 3}]}
      """
    try Data(recipeJSON.utf8).write(to: URL(fileURLWithPath: recipePath))

    await #expect(throws: ExitCode.failure) {
      try await runCommand([
        "generate", template, "--recipe", recipePath, "--count", "1",
        "--seed", "42", "--output-directory", workspace.path("out"),
      ])
    }
  }

  @Test("Generated filenames cannot escape the output directory")
  func generateSanitizesFilenames() async throws {
    let workspace = try Workspace()
    let template = try WorkoutFixturePreset.outdoorRun.fixture()
    let hostile = WorkoutFixture(
      id: WorkoutID(rawValue: "../evil"),
      workout: template.workout,
      series: template.series,
      events: template.events,
      route: template.route,
      provenance: template.provenance
    )
    let templatePath = try workspace.writeFixture(hostile)
    let outputDirectory = workspace.path("generated")
    let recipePath = workspace.path("recipe.json")
    try Data(#"{"transforms": []}"#.utf8).write(to: URL(fileURLWithPath: recipePath))

    try await runCommand([
      "generate", templatePath, "--recipe", recipePath, "--count", "1",
      "--seed", "42", "--output-directory", outputDirectory,
    ])

    let inside = try FileManager.default.contentsOfDirectory(atPath: outputDirectory)
    #expect(inside.count == 1)
    let escaped = try FileManager.default.contentsOfDirectory(atPath: workspace.root.path)
      .filter { $0.hasPrefix("001-") }
    #expect(escaped.isEmpty)
  }

  @Test("Split fans an archive out into validated fixture files")
  func splitWritesFixtureFiles() async throws {
    let workspace = try Workspace()
    let fixtures = try WorkoutFixturePreset.allFixtures()
    let archive = try workspace.writeArchive(fixtures: fixtures)
    let outputDirectory = workspace.path("split")

    try await runCommand(["split", archive, "--output-directory", outputDirectory])

    let files = try FileManager.default.contentsOfDirectory(atPath: outputDirectory).sorted()
    #expect(files.count == fixtures.count)
    for file in files {
      let data = try Data(contentsOf: URL(fileURLWithPath: outputDirectory + "/" + file))
      _ = try FixtureJSONCodec().decode(data)
    }
  }

  @Test("Split with --redact writes redacted fixtures")
  func splitRedacts() async throws {
    let workspace = try Workspace()
    let archive = try workspace.writeArchive(fixtures: WorkoutFixturePreset.allFixtures())
    let outputDirectory = workspace.path("redacted")

    try await runCommand([
      "split", archive, "--output-directory", outputDirectory, "--redact", "--seed", "42",
    ])

    let files = try FileManager.default.contentsOfDirectory(atPath: outputDirectory)
    #expect(files.allSatisfy { $0.contains("redacted-") })
    for file in files {
      let data = try Data(contentsOf: URL(fileURLWithPath: outputDirectory + "/" + file))
      let fixture = try FixtureJSONCodec().decode(data)
      #expect(fixture.provenance.kind == .redacted)
      #expect(fixture.route == nil)
      #expect(fixture.provenance.seed == nil)
    }
  }

  @Test("Split refuses a single fixture input")
  func splitRefusesSingleFixture() async throws {
    let workspace = try Workspace()
    let fixture = try workspace.writeFixture(WorkoutFixturePreset.outdoorRun.fixture())
    await #expect(throws: ExitCode.failure) {
      try await runCommand(["split", fixture, "--output-directory", workspace.path("out")])
    }
  }

  @Test("Schema prints all bundled schemas", arguments: ["fixture", "archive", "recipe"])
  func schemaCommandRuns(_ kind: String) async throws {
    try await runCommand(["schema", kind])
  }

  @Test("Inspect handles fixtures and archives in both formats")
  func inspectRuns() async throws {
    let workspace = try Workspace()
    let fixture = try workspace.writeFixture(WorkoutFixturePreset.outdoorRun.fixture())
    let archive = try workspace.writeArchive(fixtures: WorkoutFixturePreset.allFixtures())

    try await runCommand(["inspect", fixture])
    try await runCommand(["inspect", fixture, "--json"])
    try await runCommand(["inspect", archive])
    try await runCommand(["inspect", archive, "--json"])
  }

  private static var exampleRecipePath: String {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Examples/focused-recipe.json")
      .path
  }
}

private func runCommand(_ arguments: [String]) async throws {
  let command = try WorkoutFixtureCommand.parseAsRoot(arguments)
  if var asyncCommand = command as? any AsyncParsableCommand {
    try await asyncCommand.run()
  } else {
    var syncCommand = command
    try syncCommand.run()
  }
}

private struct Workspace {
  let root: URL

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("workout-fixture-cli-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  func path(_ component: String) -> String {
    root.appendingPathComponent(component).path
  }

  func writeFixture(_ fixture: WorkoutFixture) throws -> String {
    let url = root.appendingPathComponent("\(UUID().uuidString).json")
    try FixtureJSONCodec().encode(fixture).write(to: url, options: .atomic)
    return url.path
  }

  func writeArchive(fixtures: [WorkoutFixture]) throws -> String {
    let archive = try WorkoutFixtureArchive(fixtures: fixtures)
    let url = root.appendingPathComponent("\(UUID().uuidString).json")
    try FixtureArchiveJSONCodec().encode(archive).write(to: url, options: .atomic)
    return url.path
  }

  func writeInvalidFixture() throws -> String {
    try writeFixture(Self.invalidFixture())
  }

  static func invalidFixture() throws -> WorkoutFixture {
    let template = try WorkoutFixturePreset.outdoorRun.fixture()
    return WorkoutFixture(
      id: template.id,
      workout: WorkoutDescriptor(
        activity: template.workout.activity,
        location: template.workout.location,
        startDate: template.workout.startDate,
        endDate: template.workout.startDate.addingTimeInterval(-60),
        timeZoneIdentifier: template.workout.timeZoneIdentifier
      ),
      series: template.series,
      events: template.events,
      route: template.route,
      provenance: template.provenance
    )
  }
}
