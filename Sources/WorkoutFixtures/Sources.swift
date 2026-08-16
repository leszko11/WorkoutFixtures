import Foundation

public struct InMemoryWorkoutSource: WorkoutFixtureSource, Sendable {
  private let fixturesByID: [WorkoutID: WorkoutFixture]

  public init(fixtures: [WorkoutFixture]) {
    fixturesByID = Dictionary(
      fixtures.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
  }

  public func summaries(matching query: WorkoutQuery) async throws -> [WorkoutSummary] {
    let summaries = fixturesByID.values.lazy
      .filter { query.activities.isEmpty || query.activities.contains($0.workout.activity) }
      .filter { fixture in
        query.startDate.map { $0 <= fixture.workout.endDate } ?? true
      }
      .filter { fixture in
        query.endDate.map { $0 >= fixture.workout.startDate } ?? true
      }
      .map(\.summary)
      .sorted {
        switch query.sort {
        case .startDateAscending: $0.startDate < $1.startDate
        case .startDateDescending: $0.startDate > $1.startDate
        }
      }
    if let limit = query.limit {
      return Array(summaries.prefix(max(0, limit)))
    }
    return summaries
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
    archiveCodec: FixtureArchiveJSONCodec = FixtureArchiveJSONCodec()
  ) throws {
    let raw = try JSONSerialization.jsonObject(with: data)
    guard let object = raw as? [String: Any] else {
      throw FixtureCodingError.invalidTopLevel
    }
    let fixtures =
      try object["fixtures"] != nil
      ? archiveCodec.decode(data, rootObject: object, unknownFields: .reject).fixtures
      : [fixtureCodec.decode(data, rootObject: object, unknownFields: .reject)]
    source = InMemoryWorkoutSource(fixtures: fixtures)
  }

  public init(
    url: URL,
    fixtureCodec: FixtureJSONCodec = FixtureJSONCodec(),
    archiveCodec: FixtureArchiveJSONCodec = FixtureArchiveJSONCodec()
  ) throws {
    try self.init(
      data: Data(contentsOf: url),
      fixtureCodec: fixtureCodec,
      archiveCodec: archiveCodec
    )
  }

  public init(
    bundle: Bundle,
    resource: String,
    withExtension fileExtension: String = "json",
    subdirectory: String? = nil,
    fixtureCodec: FixtureJSONCodec = FixtureJSONCodec(),
    archiveCodec: FixtureArchiveJSONCodec = FixtureArchiveJSONCodec()
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
    try self.init(url: url, fixtureCodec: fixtureCodec, archiveCodec: archiveCodec)
  }

  public func summaries(matching query: WorkoutQuery) async throws -> [WorkoutSummary] {
    try await source.summaries(matching: query)
  }

  public func fixture(for id: WorkoutID) async throws -> WorkoutFixture {
    try await source.fixture(for: id)
  }
}
