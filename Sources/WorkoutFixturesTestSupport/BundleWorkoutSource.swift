import Foundation
import WorkoutFixtures

/// A fixture source that loads JSON from a bundle's resources, for tests and previews.
///
/// The resource may be a single fixture or an archive (see `JSONWorkoutSource`); it is decoded
/// once at initialization and served from memory.
public struct BundleWorkoutSource: WorkoutFixtureSource, Sendable {
  private let source: JSONWorkoutSource

  /// Loads `resource`.json from the test-support target's own resource bundle.
  /// - Throws: `CocoaError(.fileNoSuchFile)` when the resource is missing, plus any decoding
  ///   error.
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

  /// Loads `resource`.json from `bundle`, looking in `subdirectory` first and then among the
  /// bundle's top-level resources (some build systems flatten resource folders).
  /// - Throws: `CocoaError(.fileNoSuchFile)` when the resource is missing, plus any decoding
  ///   error.
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
