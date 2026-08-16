#if canImport(HealthKit)
  import Foundation
  import HealthKit
  import WorkoutFixtures

  public enum WorkoutStoreFactoryError: Error, Equatable, Sendable, LocalizedError {
    case presetFixturesUnavailable

    public var errorDescription: String? {
      switch self {
      case .presetFixturesUnavailable:
        "The launch environment selected preset fixtures, but no presetFixtures provider was "
          + "given. Pass presetFixtures: WorkoutFixturePreset.allFixtures from a target that "
          + "links WorkoutFixturesTestSupport."
      }
    }
  }

  /// Builds the app's workout source and sink from the launch environment.
  ///
  /// By default the factory returns the real HealthKit adapters. When the
  /// process was launched with a fixture mode (see
  /// ``WorkoutFixtures/FixtureLaunchConfiguration``), it returns fixture-backed
  /// stores instead, so UI tests and Debug builds can inject mock workouts
  /// without changing any call sites:
  ///
  /// ```swift
  /// let (source, sink) = try WorkoutStoreFactory.make(
  ///   presetFixtures: WorkoutFixturePreset.allFixtures
  /// )
  /// ```
  public enum WorkoutStoreFactory {
    public typealias Stores = (
      source: any WorkoutFixtureSource,
      sink: any WorkoutFixtureSink & WorkoutFixtureDeleting
    )

    public static func make(
      healthStore: @autoclosure () -> HKHealthStore = HKHealthStore(),
      configuration: FixtureLaunchConfiguration? = FixtureLaunchConfiguration(),
      presetFixtures: () throws -> [WorkoutFixture] = {
        throw WorkoutStoreFactoryError.presetFixturesUnavailable
      }
    ) throws -> Stores {
      switch configuration?.mode {
      case nil, .live:
        let store = healthStore()
        return (
          HealthKitWorkoutSource(healthStore: store),
          HealthKitWorkoutSink(healthStore: store)
        )
      case .presets:
        return fixtureStores(try presetFixtures())
      case .json(let url):
        return fixtureStores(try JSONWorkoutSource(url: url).fixtures)
      case .resource(let name):
        return fixtureStores(try JSONWorkoutSource(bundle: .main, resource: name).fixtures)
      }
    }

    private static func fixtureStores(_ fixtures: [WorkoutFixture]) -> Stores {
      let store = FixtureBackedStore(fixtures: fixtures)
      return (store, store)
    }
  }

  /// An in-memory store used when the launch environment selects fixtures:
  /// reads share `WorkoutQuery.apply(to:)` with the portable sources, stores
  /// insert, deletes remove by external ID (which equals the fixture ID).
  actor FixtureBackedStore: WorkoutFixtureSource, WorkoutFixtureSink, WorkoutFixtureDeleting {
    private var fixturesByID: [WorkoutID: WorkoutFixture]

    init(fixtures: [WorkoutFixture]) {
      fixturesByID = Dictionary(
        fixtures.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
    }

    func summaries(matching query: WorkoutQuery) async throws -> [WorkoutSummary] {
      query.apply(to: fixturesByID.values)
    }

    func fixture(for id: WorkoutID) async throws -> WorkoutFixture {
      guard let fixture = fixturesByID[id] else {
        throw WorkoutFixtureSourceError.notFound(id)
      }
      return fixture
    }

    func store(_ fixture: WorkoutFixture) async throws -> StoredWorkout {
      fixturesByID[fixture.id] = fixture
      return StoredWorkout(
        fixtureID: fixture.id,
        externalID: fixture.id.rawValue,
        storedAt: fixture.workout.endDate,
        status: .available
      )
    }

    func delete(externalID: String) async throws {
      let id = WorkoutID(rawValue: externalID)
      guard fixturesByID.removeValue(forKey: id) != nil else {
        throw WorkoutFixtureSourceError.notFound(id)
      }
    }
  }
#endif
