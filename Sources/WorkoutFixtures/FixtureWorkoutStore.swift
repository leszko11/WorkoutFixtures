import Foundation

/// Failures raised when constructing a ``FixtureWorkoutStore`` from JSON.
public enum FixtureWorkoutStoreError: Error, Equatable, Sendable, LocalizedError {
  /// The archive or fixture failed validation.
  case validationFailed([ValidationIssue])
  /// No fixtures were present after decoding.
  case empty

  public var errorDescription: String? {
    switch self {
    case .validationFailed(let issues):
      let sample = issues.prefix(3).map(\.message).joined(separator: "; ")
      return "Fixture store validation failed (\(issues.count) issue(s)): \(sample)"
    case .empty:
      return "Fixture store has no workouts."
    }
  }
}

/// A production in-memory ``WorkoutFixtureStore`` backed by portable fixtures.
///
/// Use this when an app injects mocked workouts without writing to HealthKit.
/// Prefer ``HealthKitFixtureSeeder`` (in WorkoutFixturesHealthKit) when the real
/// HealthKit pipeline — observers, anchors, background delivery — must run.
public actor FixtureWorkoutStore: WorkoutFixtureSource, WorkoutFixtureSink,
  WorkoutFixtureDeleting
{
  private var fixturesByID: [WorkoutID: WorkoutFixture]

  /// Creates a store seeded with `fixtures`; when IDs collide, the last fixture wins.
  /// - Parameter validate: When `true` (the default), every fixture is validated up front
  ///   so a bad archive fails at enable time instead of during a later session start.
  public init(fixtures: [WorkoutFixture], validate: Bool = true) throws {
    if validate {
      let validator = WorkoutValidator()
      var issues: [ValidationIssue] = []
      for fixture in fixtures {
        issues.append(contentsOf: validator.validate(fixture))
      }
      if issues.contains(where: { $0.severity == .error }) {
        throw FixtureWorkoutStoreError.validationFailed(issues)
      }
    }
    fixturesByID = Dictionary(
      fixtures.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
  }

  /// Loads a single fixture or an archive from `url`, optionally gzipped.
  public static func load(
    contentsOf url: URL,
    validate: Bool = true
  ) throws -> FixtureWorkoutStore {
    try FixtureWorkoutStore(fixtures: JSONWorkoutSource(url: url).fixtures, validate: validate)
  }

  /// Loads fixtures already decoded by ``JSONWorkoutSource``.
  public static func load(
    from source: JSONWorkoutSource,
    validate: Bool = true
  ) throws -> FixtureWorkoutStore {
    try FixtureWorkoutStore(fixtures: source.fixtures, validate: validate)
  }

  /// Every fixture currently in the store, unordered.
  public var fixtures: [WorkoutFixture] {
    Array(fixturesByID.values)
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

  public func store(_ fixture: WorkoutFixture) async throws -> StoredWorkout {
    fixturesByID[fixture.id] = fixture
    return StoredWorkout(
      fixtureID: fixture.id,
      externalID: fixture.id.rawValue,
      storedAt: fixture.workout.endDate,
      status: .available
    )
  }

  public func delete(externalID: String) async throws {
    let id = WorkoutID(rawValue: externalID)
    guard fixturesByID.removeValue(forKey: id) != nil else {
      throw WorkoutFixtureSourceError.notFound(id)
    }
  }
}
