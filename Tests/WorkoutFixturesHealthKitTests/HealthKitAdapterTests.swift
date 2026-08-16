#if canImport(HealthKit)
  import Foundation
  import HealthKit
  import Testing
  import WorkoutFixtures
  import WorkoutFixturesTestSupport

  @testable import WorkoutFixturesHealthKit

  @Test("HealthKit adapters satisfy Sendable public boundaries")
  func adaptersAreSendable() {
    assertSendable(HealthKitWorkoutSource.self)
    assertSendable(HealthKitWorkoutSink.self)
    assertSendable(HealthKitAuthorizationController.self)
  }

  @Suite("Workout store factory")
  struct WorkoutStoreFactoryTests {
    @Test("Live and unconfigured launches return the HealthKit adapters")
    func liveReturnsHealthKitAdapters() throws {
      for configuration in [nil, FixtureLaunchConfiguration(mode: .live)] {
        let stores = try WorkoutStoreFactory.make(
          healthStore: HKHealthStore(),
          configuration: configuration
        )
        #expect(stores.source is HealthKitWorkoutSource)
        #expect(stores.sink is HealthKitWorkoutSink)
      }
    }

    @Test("Preset mode returns a fixture-backed store without touching HealthKit")
    func presetModeUsesFixtures() async throws {
      let stores = try WorkoutStoreFactory.make(
        configuration: FixtureLaunchConfiguration(mode: .presets),
        presetFixtures: WorkoutFixturePreset.allFixtures
      )
      let summaries = try await stores.source.summaries(matching: WorkoutQuery())
      #expect(summaries.count == WorkoutFixturePreset.allCases.count)

      let fixture = try WorkoutFixturePreset.outdoorRun.fixture()
      let stored = try await stores.sink.store(fixture)
      #expect(stored.status == .available)
      try await stores.sink.delete(externalID: fixture.id.rawValue)
    }

    @Test("Preset mode without a provider is a typed error")
    func presetModeWithoutProviderThrows() {
      #expect(throws: WorkoutStoreFactoryError.presetFixturesUnavailable) {
        _ = try WorkoutStoreFactory.make(
          configuration: FixtureLaunchConfiguration(mode: .presets)
        )
      }
    }

    @Test("JSON mode loads a fixture file from disk")
    func jsonModeLoadsFile() async throws {
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("factory-\(UUID().uuidString).json")
      defer { try? FileManager.default.removeItem(at: url) }
      let fixture = try WorkoutFixturePreset.outdoorRun.fixture()
      try FixtureJSONCodec().encode(fixture).write(to: url, options: .atomic)

      let stores = try WorkoutStoreFactory.make(
        configuration: FixtureLaunchConfiguration(mode: .json(url))
      )
      #expect(try await stores.source.fixture(for: fixture.id) == fixture)
    }
  }

  @Test("HealthKit adapters initialize without requesting authorization")
  func adaptersInitialize() {
    let store = HKHealthStore()
    _ = HealthKitWorkoutSource(healthStore: store)
    _ = HealthKitWorkoutSink(healthStore: store)
    _ = HealthKitAuthorizationController(healthStore: store)
  }

  @Test("Sample chunking preserves order and covers remainders")
  func chunkingCoversAllElements() {
    #expect([Int]().chunked(into: 3).isEmpty)
    #expect([1, 2, 3, 4, 5, 6].chunked(into: 3) == [[1, 2, 3], [4, 5, 6]])
    #expect([1, 2, 3, 4, 5].chunked(into: 2) == [[1, 2], [3, 4], [5]])
    #expect([1, 2].chunked(into: 1) == [[1], [2]])
  }

  @Test("Captured fixtures are normalized to strict fixture invariants")
  func capturedFixturesAreNormalized() {
    let startDate = Date(timeIntervalSinceReferenceDate: 1_000)
    let endDate = startDate.addingTimeInterval(60)
    let fixture = WorkoutFixture(
      id: "captured",
      workout: WorkoutDescriptor(
        activity: .running,
        location: .outdoor,
        startDate: startDate,
        endDate: endDate,
        timeZoneIdentifier: "UTC"
      ),
      series: [
        MetricSeries(
          metric: .distance,
          samples: [
            MetricSample(
              startDate: startDate.addingTimeInterval(20),
              endDate: startDate.addingTimeInterval(40),
              value: 2
            ),
            MetricSample(
              startDate: startDate.addingTimeInterval(-5),
              endDate: startDate.addingTimeInterval(25),
              value: 1
            ),
            MetricSample(
              startDate: endDate.addingTimeInterval(5),
              endDate: endDate.addingTimeInterval(10),
              value: 3
            ),
          ]
        )
      ],
      events: [
        WorkoutEvent(kind: .pause, startDate: startDate.addingTimeInterval(10)),
        WorkoutEvent(kind: .pause, startDate: startDate.addingTimeInterval(11)),
        WorkoutEvent(kind: .resume, startDate: startDate.addingTimeInterval(20)),
        WorkoutEvent(kind: .resume, startDate: startDate.addingTimeInterval(21)),
      ],
      route: WorkoutRoute(points: [
        RoutePoint(
          date: endDate.addingTimeInterval(5), latitude: 52.2, longitude: 21.0),
        RoutePoint(
          date: startDate.addingTimeInterval(-5), latitude: 52.1, longitude: 20.9),
      ]),
      provenance: FixtureProvenance(kind: .captured, createdAt: startDate)
    )

    let normalized = HealthKitFixtureNormalizer.normalize(fixture)
    let errors = WorkoutValidator().validate(normalized).filter { $0.severity == .error }

    #expect(errors.isEmpty)
    #expect(normalized.series[0].samples.count == 3)
    #expect(normalized.series[0].samples.first?.startDate == startDate)
    #expect(normalized.series[0].samples.last?.endDate == endDate)
    #expect(normalized.events.map(\.kind) == [.pause, .resume])
    #expect(normalized.route?.points.map(\.date) == [startDate, endDate])
  }
#endif
