import Foundation
import WorkoutFixtures

/// Compile-time assertion helper shared by the package's test targets.
public func assertSendable<T: Sendable>(_: T.Type) {}

/// A sink that records every store and delete so tests can assert what an
/// app would have written. Errors can be injected to exercise failure paths.
public actor RecordingWorkoutSink: WorkoutFixtureSink, WorkoutFixtureDeleting {
  public private(set) var storedFixtures: [WorkoutFixture] = []
  public private(set) var deletedExternalIDs: [String] = []

  private let externalID: @Sendable (WorkoutFixture) -> String?
  private var storeError: (any Error)?
  private var deleteError: (any Error)?

  public init(externalID: @escaping @Sendable (WorkoutFixture) -> String? = { $0.id.rawValue }) {
    self.externalID = externalID
  }

  public func setStoreError(_ error: (any Error)?) {
    storeError = error
  }

  public func setDeleteError(_ error: (any Error)?) {
    deleteError = error
  }

  public func store(_ fixture: WorkoutFixture) async throws -> StoredWorkout {
    if let storeError { throw storeError }
    storedFixtures.append(fixture)
    let externalID = externalID(fixture)
    return StoredWorkout(
      fixtureID: fixture.id,
      externalID: externalID,
      storedAt: fixture.workout.endDate,
      status: externalID == nil ? .savedUnavailable : .available
    )
  }

  public func delete(externalID: String) async throws {
    if let deleteError { throw deleteError }
    deletedExternalIDs.append(externalID)
  }
}

/// A source that always throws, for exercising error paths.
public struct FailingWorkoutSource: WorkoutFixtureSource {
  private let error: any Error

  public init(error: any Error = WorkoutFixtureSourceError.notFound("failing")) {
    self.error = error
  }

  public func summaries(matching query: WorkoutQuery) async throws -> [WorkoutSummary] {
    throw error
  }

  public func fixture(for id: WorkoutID) async throws -> WorkoutFixture {
    throw error
  }
}

/// A full in-memory `WorkoutFixtureStore`: reads mirror `InMemoryWorkoutSource`
/// exactly (both use `WorkoutQuery.apply(to:)`), stores insert, and deletes
/// remove by external ID (which equals the fixture ID).
public actor InMemoryWorkoutStore: WorkoutFixtureSource, WorkoutFixtureSink,
  WorkoutFixtureDeleting
{
  private var fixturesByID: [WorkoutID: WorkoutFixture]

  public init(fixtures: [WorkoutFixture] = []) {
    fixturesByID = Dictionary(
      fixtures.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
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

extension WorkoutFixturePreset {
  /// An in-memory store seeded with every bundled preset, for launch-time
  /// injection (`WORKOUT_FIXTURES_MODE=presets`).
  public static func launchStore() throws -> InMemoryWorkoutStore {
    InMemoryWorkoutStore(fixtures: try allFixtures())
  }
}
