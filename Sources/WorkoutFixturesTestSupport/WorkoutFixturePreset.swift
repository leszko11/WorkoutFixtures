import Foundation
import WorkoutFixtures

public enum WorkoutFixturePreset: String, CaseIterable, Sendable {
  case outdoorRun = "outdoor-run"
  case pausedWalk = "paused-walk"
  case indoorRide = "indoor-ride"

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

  public static func allFixtures() throws -> [WorkoutFixture] {
    try allCases.map { try $0.fixture() }
  }
}
