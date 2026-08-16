import Foundation
import WorkoutFixtures

/// The ready-made workout fixtures bundled with the test-support target.
public enum WorkoutFixturePreset: String, CaseIterable, Sendable {
  /// An outdoor run with a GPS route, a lap event, and heart-rate, distance, and energy series.
  case outdoorRun = "outdoor-run"
  /// An outdoor walk containing a pause/resume pair, so active duration differs from elapsed.
  case pausedWalk = "paused-walk"
  /// An indoor cycling workout without a route.
  case indoorRide = "indoor-ride"

  /// Decodes this preset's bundled JSON with the strict fixture codec.
  /// - Throws: `CocoaError(.fileNoSuchFile)` when the resource is missing, plus any decoding
  ///   error.
  public func fixture() throws -> WorkoutFixture {
    let nested = Bundle.module.url(
      forResource: rawValue,
      withExtension: "json",
      subdirectory: "Fixtures"
    )
    let flattened = Bundle.module.url(forResource: rawValue, withExtension: "json")
    guard let url = nested ?? flattened else {
      throw CocoaError(.fileNoSuchFile)
    }
    return try FixtureJSONCodec().decode(Data(contentsOf: url))
  }

  /// Decodes every preset, in declaration order.
  public static func allFixtures() throws -> [WorkoutFixture] {
    try allCases.map { try $0.fixture() }
  }
}
