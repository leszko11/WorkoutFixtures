import Foundation

/// A launch-time selection of where workout data should come from.
///
/// Parsed from the process environment (preferred) or launch arguments, so UI
/// tests and Debug builds can swap HealthKit for fixtures without any change
/// at call sites:
///
/// - `WORKOUT_FIXTURES_MODE=live` — use the real HealthKit adapters.
/// - `WORKOUT_FIXTURES_MODE=presets` — use bundled preset fixtures.
/// - `WORKOUT_FIXTURES_MODE=json` + `WORKOUT_FIXTURES_PATH=/path/file.json`
///   — load a fixture or archive file.
/// - `WORKOUT_FIXTURES_MODE=resource` + `WORKOUT_FIXTURES_RESOURCE=name`
///   — load a bundled fixture or archive resource.
///
/// The launch argument `--workout-fixtures <mode>` is an alternative to the
/// `WORKOUT_FIXTURES_MODE` variable. The initializer returns `nil` when no
/// mode (or an unknown mode) is configured; callers treat that as `live`.
public struct FixtureLaunchConfiguration: Sendable, Equatable {
  public enum Mode: Sendable, Equatable {
    case live
    case presets
    case json(URL)
    case resource(name: String)
  }

  public let mode: Mode

  public init(mode: Mode) {
    self.mode = mode
  }

  public init?(processInfo: ProcessInfo = .processInfo) {
    self.init(arguments: processInfo.arguments, environment: processInfo.environment)
  }

  init?(arguments: [String], environment: [String: String]) {
    var rawMode = environment["WORKOUT_FIXTURES_MODE"]
    if rawMode == nil,
      let flagIndex = arguments.firstIndex(of: "--workout-fixtures"),
      arguments.indices.contains(flagIndex + 1)
    {
      rawMode = arguments[flagIndex + 1]
    }
    switch rawMode {
    case "live":
      mode = .live
    case "presets":
      mode = .presets
    case "json":
      guard let path = environment["WORKOUT_FIXTURES_PATH"], !path.isEmpty else { return nil }
      mode = .json(URL(fileURLWithPath: path))
    case "resource":
      guard let name = environment["WORKOUT_FIXTURES_RESOURCE"], !name.isEmpty else { return nil }
      mode = .resource(name: name)
    default:
      return nil
    }
  }
}
