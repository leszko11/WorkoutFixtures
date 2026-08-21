#if canImport(HealthKit)
  import Foundation
  import HealthKit
  import WorkoutFixtures

  /// Failures raised by ``WorkoutStoreFactory/make(healthStore:configuration:presetFixtures:)``.
  public enum WorkoutStoreFactoryError: Error, Equatable, Sendable, LocalizedError {
    /// The launch environment selected preset fixtures but no `presetFixtures` provider was
    /// passed to the factory.
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
  /// ``WorkoutFixtures/FixtureLaunchConfiguration``), it returns a
  /// ``FixtureWorkoutStore`` instead, so UI tests and Debug builds can inject
  /// mock workouts without changing any call sites:
  ///
  /// ```swift
  /// let (source, sink) = try WorkoutStoreFactory.make(
  ///   presetFixtures: WorkoutFixturePreset.allFixtures
  /// )
  /// ```
  public enum WorkoutStoreFactory {
    /// The source/sink pair the factory returns; in fixture modes both are the same
    /// ``FixtureWorkoutStore``, so writes are visible to subsequent reads.
    public typealias Stores = (
      source: any WorkoutFixtureSource,
      sink: any WorkoutFixtureSink & WorkoutFixtureDeleting
    )

    /// Returns the stores selected by the launch configuration.
    ///
    /// `healthStore` is evaluated only in live mode, so fixture-backed runs never touch
    /// HealthKit; `presetFixtures` is invoked only in `.presets` mode.
    /// - Throws: ``WorkoutStoreFactoryError/presetFixturesUnavailable`` when `.presets` is
    ///   selected without a provider, or any error from loading and decoding the selected
    ///   fixture JSON (including validation failures from ``FixtureWorkoutStore``).
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
        return try fixtureStores(try presetFixtures())
      case .json(let url):
        return try fixtureStores(try JSONWorkoutSource(url: url).fixtures)
      case .resource(let name):
        return try fixtureStores(try JSONWorkoutSource(bundle: .main, resource: name).fixtures)
      }
    }

    private static func fixtureStores(_ fixtures: [WorkoutFixture]) throws -> Stores {
      let store = try FixtureWorkoutStore(fixtures: fixtures, validate: true)
      return (store, store)
    }
  }
#endif
