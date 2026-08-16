import Foundation

/// Read access to workout fixtures: list summaries and load complete fixtures by ID.
public protocol WorkoutFixtureSource: Sendable {
  /// Returns summaries of the fixtures matching `query`, filtered, sorted, and limited exactly
  /// as the query specifies. Conformers can delegate to ``WorkoutQuery/apply(to:)`` so every
  /// source answers a given query identically.
  func summaries(matching query: WorkoutQuery) async throws -> [WorkoutSummary]

  /// Returns the complete fixture for `id`.
  /// - Throws: ``WorkoutFixtureSourceError/notFound(_:)`` when no fixture has that ID.
  func fixture(for id: WorkoutID) async throws -> WorkoutFixture
}

/// Write access to a workout store (HealthKit, in-memory, ...).
public protocol WorkoutFixtureSink: Sendable {
  /// Persists `fixture` and returns a receipt describing how the store recorded it, including
  /// the store-assigned external identifier needed to delete it later.
  func store(_ fixture: WorkoutFixture) async throws -> StoredWorkout
}

/// Delete access to a workout store, keyed by the store-assigned identifier.
public protocol WorkoutFixtureDeleting: Sendable {
  /// Removes the workout previously stored under `externalID` (see
  /// ``StoredWorkout/externalID``). Throws when no stored workout matches.
  func delete(externalID: String) async throws
}

/// The full read/write/delete surface an app usually injects as one dependency.
public typealias WorkoutFixtureStore = WorkoutFixtureSource & WorkoutFixtureSink
  & WorkoutFixtureDeleting

/// Derives new workout fixtures from a template by applying a generation recipe.
public protocol WorkoutGenerating: Sendable {
  /// Applies `recipe` to `template` and returns the derived fixture.
  ///
  /// Generation is deterministic: the same template, recipe, and seed must always yield the
  /// same fixture, so tests can rely on stable outputs.
  @concurrent
  func generate(
    from template: WorkoutFixture,
    recipe: GenerationRecipe,
    seed: UInt64
  ) async throws -> WorkoutFixture
}

/// Ordering of query results by workout start date.
public enum WorkoutSort: String, Codable, Sendable {
  case startDateAscending
  case startDateDescending
}

/// Filter, sort, and limit criteria for listing workout summaries.
///
/// Date filters match by overlap: a workout matches when its interval intersects the queried
/// window, not only when it lies entirely inside it.
public struct WorkoutQuery: Codable, Equatable, Sendable {
  /// Activities to include; an empty set matches every activity.
  public let activities: Set<WorkoutActivity>
  /// Matches workouts ending on or after this date; `nil` leaves the window open.
  public let startDate: Date?
  /// Matches workouts starting on or before this date; `nil` leaves the window open.
  public let endDate: Date?
  /// Ordering of the returned summaries.
  public let sort: WorkoutSort
  /// Maximum number of summaries to return, applied after sorting; `nil` returns all matches.
  public let limit: Int?

  public init(
    activities: Set<WorkoutActivity> = [],
    startDate: Date? = nil,
    endDate: Date? = nil,
    sort: WorkoutSort = .startDateDescending,
    limit: Int? = nil
  ) {
    self.activities = activities
    self.startDate = startDate
    self.endDate = endDate
    self.sort = sort
    self.limit = limit
  }
}

/// Whether a stored workout could be handed back by the store right after saving.
public enum StoredWorkoutStatus: String, Codable, Sendable {
  /// The store returned the saved workout, so `externalID` is populated.
  case available
  /// The save succeeded but the store could not return the saved workout yet, so no
  /// `externalID` is available for later deletion.
  case savedUnavailable
}

/// A receipt returned by ``WorkoutFixtureSink/store(_:)`` describing the persisted workout.
public struct StoredWorkout: Codable, Equatable, Sendable {
  /// The ID of the fixture that was stored.
  public let fixtureID: WorkoutID
  /// The store-assigned identifier to pass to ``WorkoutFixtureDeleting/delete(externalID:)``;
  /// `nil` when ``status`` is ``StoredWorkoutStatus/savedUnavailable``.
  public let externalID: String?
  /// When the store recorded the workout as stored.
  public let storedAt: Date
  /// Whether the stored workout was immediately readable after saving.
  public let status: StoredWorkoutStatus

  public init(
    fixtureID: WorkoutID,
    externalID: String?,
    storedAt: Date,
    status: StoredWorkoutStatus
  ) {
    self.fixtureID = fixtureID
    self.externalID = externalID
    self.storedAt = storedAt
    self.status = status
  }
}

/// Errors shared by fixture sources and stores.
public enum WorkoutFixtureSourceError: Error, Equatable, Sendable, LocalizedError {
  /// No fixture (or stored workout) exists with the given ID.
  case notFound(WorkoutID)

  public var errorDescription: String? {
    switch self {
    case .notFound(let id): "No workout fixture exists with ID '\(id.rawValue)'."
    }
  }
}
