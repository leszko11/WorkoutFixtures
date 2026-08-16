import ArgumentParser
import Foundation
import WorkoutFixtures

@main
public struct WorkoutFixtureCommand: AsyncParsableCommand {
  public static let configuration = CommandConfiguration(
    commandName: "workout-fixture",
    abstract: "Inspect, validate, redact, migrate, and generate portable workout fixtures.",
    version: "1.0.0",
    subcommands: [Inspect.self, Validate.self, Redact.self, Generate.self, Migrate.self]
  )

  public init() {}
}

public enum DiagnosticsFormat: String, ExpressibleByArgument, Sendable {
  case text
  case json
}

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

private enum CLIIO {
  static let codec = FixtureJSONCodec()

  static func readFixture(at path: String) throws -> WorkoutFixture {
    try codec.decode(Data(contentsOf: URL(fileURLWithPath: path)))
  }

  static func write(_ data: Data, to path: String) throws {
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
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
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      if let data = try? encoder.encode(records), var line = String(data: data, encoding: .utf8) {
        line.append("\n")
        writeStandardError(line)
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
      abstract: "Print a fixture summary."
    )

    @Argument(help: "Path to a workout fixture JSON file.")
    var input: String

    @Flag(name: .long, help: "Emit the summary as JSON.")
    var json = false

    @OptionGroup var diagnostics: DiagnosticsOptions

    public init() {}

    public func run() async throws {
      do {
        let summary = try CLIIO.readFixture(at: input).summary
        if json {
          let encoder = JSONEncoder()
          encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
          encoder.dateEncodingStrategy = .iso8601
          print(String(decoding: try encoder.encode(summary), as: UTF8.self))
        } else {
          print("ID: \(summary.id.rawValue)")
          print("Activity: \(summary.activity.rawValue)")
          print("Start: \(summary.startDate.formatted(.iso8601))")
          print("Elapsed: \(Int(summary.elapsedDuration)) seconds")
          print("Distance: \(summary.distanceMeters.map { "\($0) m" } ?? "n/a")")
          print(
            "Average heart rate: \(summary.averageHeartRate.map { "\($0) count/min" } ?? "n/a")")
          print("Route: \(summary.hasRoute ? "yes" : "no")")
        }
      } catch {
        try CLIIO.fail(error, format: diagnostics.diagnosticsFormat)
      }
    }
  }

  public struct Validate: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
      abstract: "Validate a fixture and emit structured diagnostics."
    )

    @Argument(help: "Path to a workout fixture JSON file.")
    var input: String

    @OptionGroup var diagnostics: DiagnosticsOptions

    public init() {}

    public func run() async throws {
      do {
        let fixture = try CLIIO.readFixture(at: input)
        let issues = WorkoutValidator().validate(fixture)
        CLIIO.emit(issues.map(DiagnosticRecord.init(issue:)), format: diagnostics.diagnosticsFormat)
        if issues.contains(where: { $0.severity == .error }) {
          throw ExitCode.failure
        }
      } catch let exit as ExitCode {
        throw exit
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
        let fixture = try CLIIO.readFixture(at: input)
        let policy = RedactionPolicy(
          regenerateID: true,
          removeRoute: !preserveRoute,
          removeSourceMetadata: !preserveSource,
          shiftDates: true
        )
        let redacted = try WorkoutRedactor().redact(fixture, using: policy, seed: seed)
        try WorkoutValidator().requireValid(redacted)
        try CLIIO.write(try CLIIO.codec.encode(redacted), to: output)
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

    public func run() async throws {
      do {
        let fixture = try CLIIO.readFixture(at: template)
        let recipeData = try Data(contentsOf: URL(fileURLWithPath: recipe))
        let recipe = try JSONDecoder().decode(GenerationRecipe.self, from: recipeData)
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
            String(format: "%03d-%@.json", index + 1, output.id.rawValue)
          )
          try CLIIO.codec.encode(output).write(to: url, options: .atomic)
        }
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
        let data = try Data(contentsOf: URL(fileURLWithPath: input))
        try CLIIO.write(try CLIIO.codec.migrate(data), to: output)
      } catch {
        try CLIIO.fail(error, format: diagnostics.diagnosticsFormat)
      }
    }
  }
}

extension DiagnosticRecord {
  fileprivate init(issue: ValidationIssue) {
    self.init(
      severity: issue.severity.rawValue,
      code: issue.code,
      path: issue.path,
      message: issue.message
    )
  }
}
