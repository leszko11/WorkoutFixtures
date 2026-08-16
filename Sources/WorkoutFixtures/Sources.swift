import Foundation

extension WorkoutQuery {
  /// Applies this query's filters, sort, and limit to in-memory fixtures.
  /// Custom `WorkoutFixtureSource` implementations can reuse this so every
  /// portable source answers queries identically.
  public func apply(to fixtures: some Collection<WorkoutFixture>) -> [WorkoutSummary] {
    let summaries = fixtures.lazy
      .filter { activities.isEmpty || activities.contains($0.workout.activity) }
      .filter { fixture in
        startDate.map { $0 <= fixture.workout.endDate } ?? true
      }
      .filter { fixture in
        endDate.map { $0 >= fixture.workout.startDate } ?? true
      }
      .map(\.summary)
      .sorted {
        switch sort {
        case .startDateAscending: $0.startDate < $1.startDate
        case .startDateDescending: $0.startDate > $1.startDate
        }
      }
    if let limit {
      return Array(summaries.prefix(max(0, limit)))
    }
    return summaries
  }
}

public struct InMemoryWorkoutSource: WorkoutFixtureSource, Sendable {
  private let fixturesByID: [WorkoutID: WorkoutFixture]

  public init(fixtures: [WorkoutFixture]) {
    fixturesByID = Dictionary(
      fixtures.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
  }

  /// All fixtures held by this source, ordered by start date.
  public var fixtures: [WorkoutFixture] {
    fixturesByID.values.sorted { $0.workout.startDate < $1.workout.startDate }
  }

  public func summaries(matching query: WorkoutQuery) async throws -> [WorkoutSummary] {
    query.apply(to: fixturesByID.values)
  }

  public func fixture(for id: WorkoutID) async throws -> WorkoutFixture {
    guard let fixture = fixturesByID[id] else {
      throw WorkoutFixtureSourceError.notFound(id)
    }
    return fixture
  }
}

public struct JSONWorkoutSource: WorkoutFixtureSource, Sendable {
  private let source: InMemoryWorkoutSource

  public init(
    data: Data,
    fixtureCodec: FixtureJSONCodec = FixtureJSONCodec(),
    archiveCodec: FixtureArchiveJSONCodec = FixtureArchiveJSONCodec(),
    unknownFields: UnknownFieldPolicy = .reject
  ) throws {
    let raw = try JSONSerialization.jsonObject(with: data)
    guard let object = raw as? [String: Any] else {
      throw FixtureCodingError.invalidTopLevel
    }
    let fixtures =
      try object["fixtures"] != nil
      ? archiveCodec.decode(data, rootObject: object, unknownFields: unknownFields).fixtures
      : [fixtureCodec.decode(data, rootObject: object, unknownFields: unknownFields)]
    source = InMemoryWorkoutSource(fixtures: fixtures)
  }

  public init(
    url: URL,
    fixtureCodec: FixtureJSONCodec = FixtureJSONCodec(),
    archiveCodec: FixtureArchiveJSONCodec = FixtureArchiveJSONCodec(),
    unknownFields: UnknownFieldPolicy = .reject
  ) throws {
    try self.init(
      data: Data(contentsOf: url),
      fixtureCodec: fixtureCodec,
      archiveCodec: archiveCodec,
      unknownFields: unknownFields
    )
  }

  public init(
    bundle: Bundle,
    resource: String,
    withExtension fileExtension: String = "json",
    subdirectory: String? = nil,
    fixtureCodec: FixtureJSONCodec = FixtureJSONCodec(),
    archiveCodec: FixtureArchiveJSONCodec = FixtureArchiveJSONCodec(),
    unknownFields: UnknownFieldPolicy = .reject
  ) throws {
    let nested = bundle.url(
      forResource: resource,
      withExtension: fileExtension,
      subdirectory: subdirectory
    )
    let flattened = bundle.url(forResource: resource, withExtension: fileExtension)
    guard let url = nested ?? flattened else {
      throw CocoaError(.fileNoSuchFile)
    }
    try self.init(
      url: url,
      fixtureCodec: fixtureCodec,
      archiveCodec: archiveCodec,
      unknownFields: unknownFields
    )
  }

  /// All fixtures decoded from the JSON input, ordered by start date.
  public var fixtures: [WorkoutFixture] {
    source.fixtures
  }

  public func summaries(matching query: WorkoutQuery) async throws -> [WorkoutSummary] {
    try await source.summaries(matching: query)
  }

  public func fixture(for id: WorkoutID) async throws -> WorkoutFixture {
    try await source.fixture(for: id)
  }
}
