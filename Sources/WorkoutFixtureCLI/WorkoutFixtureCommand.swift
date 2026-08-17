import ArgumentParser
import Foundation
import WorkoutFixtures

@main
public struct WorkoutFixtureCommand: AsyncParsableCommand {
  public static let configuration = CommandConfiguration(
    commandName: "workout-fixture",
    abstract: "Inspect, validate, redact, migrate, split, and generate portable workout fixtures.",
    version: "1.0.0",
    subcommands: [
      Inspect.self, Validate.self, Split.self, Redact.self, Generate.self, Migrate.self,
      ImportGPX.self, Schema.self,
    ]
  )

  public init() {}
}

public enum DiagnosticsFormat: String, ExpressibleByArgument, Sendable {
  case text
  case json
}

extension WorkoutActivity: ExpressibleByArgument {}
extension WorkoutLocation: ExpressibleByArgument {}

struct DiagnosticsOptions: ParsableArguments {
  @Option(name: .long, help: "Diagnostic output format: text or json.")
  var diagnosticsFormat: DiagnosticsFormat = .text
}

private struct DiagnosticRecord: Codable, Sendable {
  let severity: String
  let code: String
  let path: String?
  let message: String
}

private enum FixtureInput {
  case fixture(WorkoutFixture)
  case archive(WorkoutFixtureArchive)

  static func load(path: String) throws -> Self {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw FixtureCodingError.invalidTopLevel
    }
    if object["fixtures"] != nil {
      return .archive(try FixtureArchiveJSONCodec().decode(data))
    }
    return .fixture(try FixtureJSONCodec().decode(data))
  }
}

private struct ArchiveInputNotSupportedError: Error, LocalizedError {
  let command: String

  var errorDescription: String? {
    "'\(command)' accepts a single fixture, but this file is a fixture archive. "
      + "Run 'workout-fixture split' to fan the archive out into fixture files first."
  }
}

private struct SingleFixtureInputError: Error, LocalizedError {
  var errorDescription: String? {
    "'split' requires a fixture archive, but this file contains a single fixture."
  }
}

private enum CLIIO {
  static let codec = FixtureJSONCodec()

  static func requireFixture(at path: String, command: String) throws -> WorkoutFixture {
    switch try FixtureInput.load(path: path) {
    case .fixture(let fixture):
      return fixture
    case .archive:
      throw ArchiveInputNotSupportedError(command: command)
    }
  }

  static func write(_ data: Data, to path: String) throws {
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
  }

  static func outputFilename(index: Int, id: WorkoutID) -> String {
    String(format: "%03d-%@.json", index + 1, sanitizedFilenameComponent(id.rawValue))
  }

  // Fixture identifiers feed into filenames; strip path separators and any
  // other character that could escape the destination directory.
  static func sanitizedFilenameComponent(_ raw: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
    let mapped = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
    let cleaned = String(mapped)
    return cleaned.isEmpty ? "fixture" : cleaned
  }

  static func emit(_ records: [DiagnosticRecord], format: DiagnosticsFormat) {
    switch format {
    case .text:
      for record in records {
        let location = record.path.map { " [\($0)]" } ?? ""
        writeStandardError(
          "\(record.severity.uppercased()) \(record.code)\(location): \(record.message)\n")
      }
    case .json:
      // NDJSON: one diagnostic object per line so consumers can stream and grep.
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      for record in records {
        if let data = try? encoder.encode(record), let line = String(data: data, encoding: .utf8) {
          writeStandardError(line + "\n")
        }
      }
    }
  }

  static func fail(_ error: Error, format: DiagnosticsFormat) throws -> Never {
    emit(
      [
        DiagnosticRecord(
          severity: "error",
          code: "operation.failed",
          path: nil,
          message: error.localizedDescription
        )
      ],
      format: format
    )
    throw ExitCode.failure
  }

  private static func writeStandardError(_ value: String) {
    FileHandle.standardError.write(Data(value.utf8))
  }
}

extension WorkoutFixtureCommand {
  public struct Inspect: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
      abstract: "Print a fixture or archive summary."
    )

    @Argument(help: "Path to a workout fixture or fixture archive JSON file.")
    var input: String

    @Flag(name: .long, help: "Emit the summary as JSON.")
    var json = false

    @OptionGroup var diagnostics: DiagnosticsOptions

    public init() {}

    public func run() async throws {
      do {
        switch try FixtureInput.load(path: input) {
        case .fixture(let fixture):
          if json {
            print(try Self.encodePayload(FixturePayload(summary: fixture.summary)))
          } else {
            Self.printSummary(fixture.summary)
          }
        case .archive(let archive):
          let summaries = archive.fixtures.map(\.summary)
          if json {
            print(
              try Self.encodePayload(
                ArchivePayload(createdAt: archive.createdAt, fixtures: summaries)
              ))
          } else {
            print("Archive created: \(archive.createdAt.formatted(.iso8601))")
            print("Fixtures: \(summaries.count)")
            for summary in summaries {
              print(
                "- \(summary.id.rawValue): \(summary.activity.rawValue), "
                  + "\(summary.startDate.formatted(.iso8601)), "
                  + "\(Int(summary.elapsedDuration)) s")
            }
          }
        }
      } catch {
        try CLIIO.fail(error, format: diagnostics.diagnosticsFormat)
      }
    }

    private struct FixturePayload: Codable {
      var kind = "fixture"
      let summary: WorkoutSummary
    }

    private struct ArchivePayload: Codable {
      var kind = "archive"
      let createdAt: Date
      let fixtures: [WorkoutSummary]
    }

    private static func encodePayload<Payload: Encodable>(_ payload: Payload) throws -> String {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      encoder.dateEncodingStrategy = .iso8601
      return String(decoding: try encoder.encode(payload), as: UTF8.self)
    }

    private static func printSummary(_ summary: WorkoutSummary) {
      print("ID: \(summary.id.rawValue)")
      print("Activity: \(summary.activity.rawValue)")
      print("Start: \(summary.startDate.formatted(.iso8601))")
      print("Elapsed: \(Int(summary.elapsedDuration)) seconds")
      print("Distance: \(summary.distanceMeters.map { "\($0) m" } ?? "n/a")")
      print("Average heart rate: \(summary.averageHeartRate.map { "\($0) count/min" } ?? "n/a")")
      print("Route: \(summary.hasRoute ? "yes" : "no")")
    }
  }

  public struct Validate: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
      abstract: "Validate a fixture or archive and emit structured diagnostics."
    )

    @Argument(help: "Path to a workout fixture or fixture archive JSON file.")
    var input: String

    @OptionGroup var diagnostics: DiagnosticsOptions

    public init() {}

    public func run() async throws {
      do {
        let issues: [DiagnosticRecord]
        switch try FixtureInput.load(path: input) {
        case .fixture(let fixture):
          issues = WorkoutValidator().validate(fixture).map { DiagnosticRecord(issue: $0) }
        case .archive(let archive):
          issues = archive.fixtures.enumerated().flatMap { index, fixture in
            WorkoutValidator().validate(fixture).map {
              DiagnosticRecord(issue: $0, pathPrefix: "fixtures[\(index)].")
            }
          }
        }
        CLIIO.emit(issues, format: diagnostics.diagnosticsFormat)
        if issues.contains(where: { $0.severity == ValidationSeverity.error.rawValue }) {
          throw ExitCode.failure
        }
      } catch let exit as ExitCode {
        throw exit
      } catch {
        try CLIIO.fail(error, format: diagnostics.diagnosticsFormat)
      }
    }
  }

  public struct Split: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
      abstract: "Split a fixture archive into individual fixture files."
    )

    @Argument(help: "Path to a fixture archive JSON file.")
    var input: String

    @Option(name: .long, help: "Destination directory.")
    var outputDirectory: String

    @Flag(name: .long, help: "Redact each fixture with the sharing policy before writing.")
    var redact = false

    @Option(name: .long, help: "Deterministic redaction seed (required with --redact).")
    var seed: UInt64?

    @OptionGroup var diagnostics: DiagnosticsOptions

    public init() {}

    public func validate() throws {
      if redact, seed == nil {
        throw ValidationError("--seed is required when --redact is set.")
      }
    }

    public func run() async throws {
      do {
        guard case .archive(let archive) = try FixtureInput.load(path: input) else {
          throw SingleFixtureInputError()
        }
        let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (index, fixture) in archive.fixtures.enumerated() {
          var output = fixture
          if redact, let seed {
            output = try WorkoutRedactor().redact(fixture, seed: seed)
          }
          try WorkoutValidator().requireValid(output)
          let url = directory.appendingPathComponent(
            CLIIO.outputFilename(index: index, id: output.id)
          )
          try CLIIO.codec.encode(output).write(to: url, options: .atomic)
        }
        print("Wrote \(archive.fixtures.count) fixture(s) to \(outputDirectory)")
      } catch {
        try CLIIO.fail(error, format: diagnostics.diagnosticsFormat)
      }
    }
  }

  public struct Redact: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
      abstract: "Apply deterministic privacy redaction to a fixture."
    )

    @Argument(help: "Path to the input fixture.")
    var input: String

    @Option(name: .long, help: "Destination JSON path.")
    var output: String

    @Option(name: .long, help: "Deterministic redaction seed.")
    var seed: UInt64

    @Flag(name: .long, help: "Keep GPS route points.")
    var preserveRoute = false

    @Flag(name: .long, help: "Keep source application and device metadata.")
    var preserveSource = false

    @OptionGroup var diagnostics: DiagnosticsOptions

    public init() {}

    public func run() async throws {
      do {
        let fixture = try CLIIO.requireFixture(at: input, command: "redact")
        let policy = RedactionPolicy(
          regenerateID: true,
          removeRoute: !preserveRoute,
          removeSourceMetadata: !preserveSource,
          shiftDates: true
        )
        let redacted = try WorkoutRedactor().redact(fixture, using: policy, seed: seed)
        try WorkoutValidator().requireValid(redacted)
        try CLIIO.write(try CLIIO.codec.encode(redacted), to: output)
        print("Wrote redacted fixture to \(output)")
      } catch {
        try CLIIO.fail(error, format: diagnostics.diagnosticsFormat)
      }
    }
  }

  public struct Generate: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
      abstract: "Generate deterministic fixtures from a template and recipe."
    )

    @Argument(help: "Path to the template fixture.")
    var template: String

    @Option(name: .long, help: "Path to a generation recipe JSON file.")
    var recipe: String

    @Option(name: .long, help: "Number of fixtures to generate.")
    var count: Int

    @Option(name: .long, help: "Root generation seed.")
    var seed: UInt64

    @Option(name: .long, help: "Destination directory.")
    var outputDirectory: String

    @OptionGroup var diagnostics: DiagnosticsOptions

    public init() {}

    public func validate() throws {
      if count < 1 {
        throw ValidationError("--count must be at least 1.")
      }
    }

    public func run() async throws {
      do {
        let fixture = try CLIIO.requireFixture(at: template, command: "generate")
        let recipeData = try Data(contentsOf: URL(fileURLWithPath: recipe))
        let recipe = try GenerationRecipeCodec().decode(recipeData)
        let generated = try await TemplateWorkoutGenerator().generate(
          count: count,
          from: fixture,
          recipe: recipe,
          seed: seed
        )
        let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (index, output) in generated.enumerated() {
          let url = directory.appendingPathComponent(
            CLIIO.outputFilename(index: index, id: output.id)
          )
          try CLIIO.codec.encode(output).write(to: url, options: .atomic)
        }
        print("Wrote \(generated.count) fixture(s) to \(outputDirectory)")
      } catch {
        try CLIIO.fail(error, format: diagnostics.diagnosticsFormat)
      }
    }
  }

  public struct Migrate: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
      abstract: "Validate and canonicalize a fixture to the current schema."
    )

    @Argument(help: "Path to the input fixture.")
    var input: String

    @Option(name: .long, help: "Destination JSON path.")
    var output: String

    @OptionGroup var diagnostics: DiagnosticsOptions

    public init() {}

    public func run() async throws {
      do {
        let fixture = try CLIIO.requireFixture(at: input, command: "migrate")
        try WorkoutValidator().requireValid(fixture)
        try CLIIO.write(try CLIIO.codec.encode(fixture), to: output)
        print("Wrote canonical fixture to \(output)")
      } catch {
        try CLIIO.fail(error, format: diagnostics.diagnosticsFormat)
      }
    }
  }

  public struct ImportGPX: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
      commandName: "import-gpx",
      abstract: "Create a validated workout fixture from a GPX track."
    )

    @Argument(help: "Path to the input GPX file.")
    var input: String

    @Option(name: .long, help: "Destination fixture JSON path.")
    var output: String

    @Option(name: .long, help: "Workout activity, e.g. running, cycling, hiking, or swimming.")
    var activity: WorkoutActivity = .running

    @Option(name: .long, help: "Workout location: indoor, outdoor, or unknown.")
    var location: WorkoutLocation = .outdoor

    @Option(name: .long, help: "Fixture identifier (defaults to one derived from the track).")
    var id: String?

    @Option(name: .customLong("time-zone"), help: "IANA time-zone identifier for the workout.")
    var timeZoneIdentifier: String = "UTC"

    @Flag(name: .customLong("no-distance-series"), help: "Skip the derived distance series.")
    var noDistanceSeries = false

    @OptionGroup var diagnostics: DiagnosticsOptions

    public init() {}

    public func run() async throws {
      do {
        var options = GPXImportOptions()
        options.activity = activity
        options.location = location
        options.id = id.map(WorkoutID.init(rawValue:))
        options.timeZoneIdentifier = timeZoneIdentifier
        options.deriveDistanceSeries = !noDistanceSeries
        let fixture = try GPXWorkoutImporter().fixture(
          contentsOf: URL(fileURLWithPath: input),
          options: options
        )
        try CLIIO.write(try CLIIO.codec.encode(fixture), to: output)
        print("Wrote fixture '\(fixture.id.rawValue)' to \(output)")
      } catch {
        try CLIIO.fail(error, format: diagnostics.diagnosticsFormat)
      }
    }
  }

  public struct Schema: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
      abstract: "Print a bundled JSON Schema to stdout."
    )

    public enum Kind: String, ExpressibleByArgument, CaseIterable, Sendable {
      case fixture
      case archive
      case recipe
    }

    @Argument(help: "Schema to print: fixture, archive, or recipe.")
    var kind: Kind

    @OptionGroup var diagnostics: DiagnosticsOptions

    public init() {}

    public func run() async throws {
      do {
        let data: Data =
          switch kind {
          case .fixture: try FixtureJSONCodec.schemaData
          case .archive: try FixtureArchiveJSONCodec.schemaData
          case .recipe: try GenerationRecipeCodec.schemaData
          }
        print(String(decoding: data, as: UTF8.self), terminator: "")
      } catch {
        try CLIIO.fail(error, format: diagnostics.diagnosticsFormat)
      }
    }
  }
}

extension DiagnosticRecord {
  fileprivate init(issue: ValidationIssue, pathPrefix: String = "") {
    self.init(
      severity: issue.severity.rawValue,
      code: issue.code,
      path: pathPrefix + issue.path,
      message: issue.message
    )
  }
}
