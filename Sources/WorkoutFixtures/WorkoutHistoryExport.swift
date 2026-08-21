import Foundation

/// Conflict policy when merging multiple archives or fixture files by workout ID.
public enum FixtureMergePolicy: String, Codable, Sendable, CaseIterable {
  /// Keep the first fixture seen for each ID; discard later duplicates.
  case firstWins
  /// Keep the last fixture seen for each ID.
  case lastWins
  /// Throw when the same ID appears more than once.
  case rejectDuplicates
}

/// Failures raised while merging fixture collections.
public enum FixtureMergeError: Error, Equatable, Sendable, LocalizedError {
  case duplicateID(WorkoutID)

  public var errorDescription: String? {
    switch self {
    case .duplicateID(let id):
      "Duplicate workout ID '\(id.rawValue)' while merging fixtures."
    }
  }
}

/// Merges fixture collections under an explicit conflict policy.
public enum FixtureMerger {
  /// Returns the merged fixtures in stable encounter order (first appearance of each ID,
  /// except ``FixtureMergePolicy/lastWins`` which rewrites the slot in place).
  public static func merge(
    _ collections: [[WorkoutFixture]],
    policy: FixtureMergePolicy
  ) throws -> [WorkoutFixture] {
    var order: [WorkoutID] = []
    var byID: [WorkoutID: WorkoutFixture] = [:]
    for fixtures in collections {
      for fixture in fixtures {
        if byID[fixture.id] != nil {
          switch policy {
          case .firstWins:
            continue
          case .lastWins:
            byID[fixture.id] = fixture
          case .rejectDuplicates:
            throw FixtureMergeError.duplicateID(fixture.id)
          }
        } else {
          order.append(fixture.id)
          byID[fixture.id] = fixture
        }
      }
    }
    return order.compactMap { byID[$0] }
  }
}

/// A thin, app-decodable workout history document produced by `workout-fixture summarize`.
///
/// Apps that do not want a runtime dependency on WorkoutFixtures can commit this JSON and
/// decode it with their own `Codable` types. ``schemaVersion`` is validated by the codec.
public struct WorkoutHistoryDocument: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let createdAt: Date
  public let windowDays: Int?
  public let shiftWeeks: Int
  public let workouts: [WorkoutHistoryEntry]

  public static let currentSchemaVersion = 1

  public init(
    schemaVersion: Int = currentSchemaVersion,
    createdAt: Date,
    windowDays: Int? = nil,
    shiftWeeks: Int = 0,
    workouts: [WorkoutHistoryEntry]
  ) {
    self.schemaVersion = schemaVersion
    self.createdAt = createdAt
    self.windowDays = windowDays
    self.shiftWeeks = shiftWeeks
    self.workouts = workouts
  }
}

/// One workout row in a ``WorkoutHistoryDocument``.
public struct WorkoutHistoryEntry: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let activity: WorkoutActivity
  public let location: WorkoutLocation
  public let startDate: Date
  public let endDate: Date
  public let elapsedDuration: TimeInterval
  public let activeDuration: TimeInterval
  public let distanceMeters: Double?
  public let activeEnergyKilocalories: Double?
  public let averageHeartRate: Double?
  public let ascentMeters: Double?
  public let descentMeters: Double?
  public let hasRoute: Bool

  public init(summary: WorkoutSummary) {
    id = summary.id.rawValue
    activity = summary.activity
    location = summary.location
    startDate = summary.startDate
    endDate = summary.endDate
    elapsedDuration = summary.elapsedDuration
    activeDuration = summary.activeDuration
    distanceMeters = summary.distanceMeters
    activeEnergyKilocalories = summary.activeEnergyKilocalories
    averageHeartRate = summary.averageHeartRate
    ascentMeters = summary.ascentMeters
    descentMeters = summary.descentMeters
    hasRoute = summary.hasRoute
  }
}

/// Builds ``WorkoutHistoryDocument`` values from fixtures and archives.
public enum WorkoutHistoryExporter {
  /// Summarizes `fixtures` after optional windowing and a whole-week date shift.
  ///
  /// - Parameters:
  ///   - windowDays: When set, keep only workouts whose start falls in the last `windowDays`
  ///     ending at the UTC day after the newest workout.
  ///   - shiftWeeks: Shift every timestamp by this many whole weeks (weekday-preserving).
  ///   - createdAt: Document timestamp; tests should pass a fixed date.
  public static func summarize(
    fixtures: [WorkoutFixture],
    windowDays: Int? = nil,
    shiftWeeks: Int = 0,
    createdAt: Date = Date()
  ) throws -> WorkoutHistoryDocument {
    var selected = fixtures
    if let windowDays {
      selected = applyWindow(selected, days: windowDays)
    }
    if shiftWeeks != 0 {
      selected = try selected.map {
        try $0.shiftingDates(byDays: shiftWeeks * 7, shiftProvenanceCreatedAt: true)
      }
    }
    let entries =
      selected
      .map(WorkoutSummary.init(fixture:))
      .sorted { $0.startDate < $1.startDate }
      .map(WorkoutHistoryEntry.init(summary:))
    return WorkoutHistoryDocument(
      createdAt: createdAt,
      windowDays: windowDays,
      shiftWeeks: shiftWeeks,
      workouts: entries
    )
  }

  private static func applyWindow(_ fixtures: [WorkoutFixture], days: Int) -> [WorkoutFixture] {
    guard days > 0, let newest = fixtures.map(\.workout.startDate).max() else { return fixtures }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let endDay = calendar.startOfDay(for: newest).addingTimeInterval(24 * 60 * 60)
    let start = endDay.addingTimeInterval(TimeInterval(-days) * 24 * 60 * 60)
    return fixtures.filter { $0.workout.startDate >= start && $0.workout.startDate < endDay }
  }
}

extension WorkoutHistoryDocument {
  /// Encodes with the same ISO-8601 strategy as fixture codecs.
  public func encode() throws -> Data {
    try CanonicalFixtureJSON.encode(self, formatting: .canonical)
  }

  /// Decodes and rejects unknown ``schemaVersion`` values.
  public static func decode(_ data: Data) throws -> WorkoutHistoryDocument {
    let document = try CanonicalFixtureJSON.makeDecoder().decode(
      WorkoutHistoryDocument.self, from: data)
    guard document.schemaVersion == currentSchemaVersion else {
      throw FixtureCodingError.unsupportedSchemaVersion(
        SchemaVersion(rawValue: document.schemaVersion))
    }
    return document
  }
}
