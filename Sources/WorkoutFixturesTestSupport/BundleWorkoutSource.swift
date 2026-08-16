import Foundation
import WorkoutFixtures

public struct BundleWorkoutSource: WorkoutFixtureSource, Sendable {
  private let source: JSONWorkoutSource

  public init(
    resource: String,
    subdirectory: String? = nil,
    unknownFields: UnknownFieldPolicy = .reject
  ) throws {
    try self.init(
      bundle: .module,
      resource: resource,
      subdirectory: subdirectory,
      unknownFields: unknownFields
    )
  }

  public init(
    bundle: Bundle,
    resource: String,
    subdirectory: String? = nil,
    unknownFields: UnknownFieldPolicy = .reject
  ) throws {
    let nested = bundle.url(
      forResource: resource,
      withExtension: "json",
      subdirectory: subdirectory
    )
    let flattened = bundle.url(forResource: resource, withExtension: "json")
    guard let url = nested ?? flattened else {
      throw CocoaError(.fileNoSuchFile)
    }
    source = try JSONWorkoutSource(url: url, unknownFields: unknownFields)
  }

  public func summaries(matching query: WorkoutQuery) async throws -> [WorkoutSummary] {
    try await source.summaries(matching: query)
  }

  public func fixture(for id: WorkoutID) async throws -> WorkoutFixture {
    try await source.fixture(for: id)
  }
}
