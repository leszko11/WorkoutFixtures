#if canImport(HealthKit)
  import Foundation
  import HealthKit
  import WorkoutFixtures

  /// Seeds HealthKit from portable fixtures so production HK pipelines (observers,
  /// anchors, background delivery) can be exercised without rewriting call sites.
  ///
  /// Prefer ``FixtureWorkoutStore`` when the app injects a workout facade and does not
  /// need the real HealthKit stack.
  public struct HealthKitFixtureSeeder: Sendable {
    private let sink: any WorkoutFixtureSink & WorkoutFixtureDeleting
    private let authorization: any HealthAuthorizing

    public init(
      healthStore: HKHealthStore = HKHealthStore(),
      authorization: (any HealthAuthorizing)? = nil
    ) {
      self.sink = HealthKitWorkoutSink(healthStore: healthStore)
      self.authorization =
        authorization ?? HealthKitAuthorizationController(healthStore: healthStore)
    }

    public init(
      sink: any WorkoutFixtureSink & WorkoutFixtureDeleting,
      authorization: any HealthAuthorizing
    ) {
      self.sink = sink
      self.authorization = authorization
    }

    /// Requests write access (by default) and stores every fixture.
    /// - Returns: Receipts for workouts that were stored successfully.
    /// - Throws: Authorization errors, or ``HealthKitFixtureSeederError/partialFailure`` when
    ///   some writes fail after others succeeded.
    public func seed(
      _ fixtures: [WorkoutFixture],
      access: HealthKitWorkoutAccess = .write
    ) async throws -> [StoredWorkout] {
      try await authorization.requestAuthorization(for: access)
      var stored: [StoredWorkout] = []
      var failures: [String] = []
      for fixture in fixtures {
        do {
          stored.append(try await sink.store(fixture))
        } catch {
          failures.append("\(fixture.id.rawValue): \(error.localizedDescription)")
        }
      }
      if !failures.isEmpty {
        throw HealthKitFixtureSeederError.partialFailure(
          written: stored.count, total: fixtures.count, reasons: failures)
      }
      return stored
    }

    /// Seeds from a single fixture or archive URL (plain or gzipped JSON).
    public func seed(
      contentsOf url: URL,
      access: HealthKitWorkoutAccess = .write
    ) async throws -> [StoredWorkout] {
      try await seed(JSONWorkoutSource(url: url).fixtures, access: access)
    }

    /// Deletes previously seeded workouts by the external IDs from their store receipts.
    public func remove(externalIDs: [String]) async throws {
      for externalID in externalIDs {
        try await sink.delete(externalID: externalID)
      }
    }

    /// Deletes every workout in `stored` that has an external ID.
    public func remove(_ stored: [StoredWorkout]) async throws {
      try await remove(externalIDs: stored.compactMap(\.externalID))
    }
  }

  public enum HealthKitFixtureSeederError: Error, Equatable, Sendable, LocalizedError {
    case partialFailure(written: Int, total: Int, reasons: [String])

    public var errorDescription: String? {
      switch self {
      case .partialFailure(let written, let total, let reasons):
        "Seeded \(written) of \(total) workouts. Failures: \(reasons.joined(separator: "; "))"
      }
    }
  }
#endif
