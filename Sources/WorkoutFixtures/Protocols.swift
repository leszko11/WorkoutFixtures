import Foundation

public protocol WorkoutFixtureSource: Sendable {
  func summaries(matching query: WorkoutQuery) async throws -> [WorkoutSummary]
  func fixture(for id: WorkoutID) async throws -> WorkoutFixture
}

public protocol WorkoutFixtureSink: Sendable {
  func store(_ fixture: WorkoutFixture) async throws -> StoredWorkout
}

public protocol WorkoutFixtureDeleting: Sendable {
  func delete(externalID: String) async throws
}

/// The full read/write/delete surface an app usually injects as one dependency.
public typealias WorkoutFixtureStore = WorkoutFixtureSource & WorkoutFixtureSink
  & WorkoutFixtureDeleting

public protocol WorkoutGenerating: Sendable {
  @concurrent
  func generate(
    from template: WorkoutFixture,
    recipe: GenerationRecipe,
    seed: UInt64
  ) async throws -> WorkoutFixture
}

public enum WorkoutSort: String, Codable, Sendable {
  case startDateAscending
  case startDateDescending
}

public struct WorkoutQuery: Codable, Equatable, Sendable {
  public let activities: Set<WorkoutActivity>
  public let startDate: Date?
  public let endDate: Date?
  public let sort: WorkoutSort
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

public enum StoredWorkoutStatus: String, Codable, Sendable {
  case available
  case savedUnavailable
}

public struct StoredWorkout: Codable, Equatable, Sendable {
  public let fixtureID: WorkoutID
  public let externalID: String?
  public let storedAt: Date
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

public enum WorkoutFixtureSourceError: Error, Equatable, Sendable, LocalizedError {
  case notFound(WorkoutID)

  public var errorDescription: String? {
    switch self {
    case .notFound(let id): "No workout fixture exists with ID '\(id.rawValue)'."
    }
  }
}
