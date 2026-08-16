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

  @Suite("HealthKit query plan")
  struct HealthKitQueryPlanTests {
    @Test("Empty query omits the predicate and limit and sorts descending")
    func emptyQueryOmitsPredicateAndLimit() {
      let plan = HealthKitQueryPlan(query: WorkoutQuery())
      #expect(plan.predicate == nil)
      #expect(plan.limit == nil)
      #expect(plan.sortDescriptors.map(\.order) == [.reverse])
    }

    @Test("Date bounds produce a predicate")
    func dateBoundsProducePredicate() {
      let startDate = Date(timeIntervalSinceReferenceDate: 0)
      let endDate = startDate.addingTimeInterval(3_600)
      let queries = [
        WorkoutQuery(startDate: startDate),
        WorkoutQuery(endDate: endDate),
        WorkoutQuery(startDate: startDate, endDate: endDate),
      ]
      for query in queries {
        #expect(HealthKitQueryPlan(query: query).predicate != nil)
      }
    }

    @Test("Activities produce a predicate")
    func activitiesProducePredicate() {
      let plan = HealthKitQueryPlan(query: WorkoutQuery(activities: [.running, .cycling]))
      #expect(plan.predicate != nil)
    }

    @Test("Dates combined with activities still produce a predicate")
    func combinedFiltersProducePredicate() {
      let query = WorkoutQuery(
        activities: [.walking],
        startDate: Date(timeIntervalSinceReferenceDate: 0)
      )
      #expect(HealthKitQueryPlan(query: query).predicate != nil)
    }

    @Test("Limit and ascending sort map into the plan")
    func limitAndSortMapIntoPlan() {
      let plan = HealthKitQueryPlan(
        query: WorkoutQuery(sort: .startDateAscending, limit: 5)
      )
      #expect(plan.limit == 5)
      #expect(plan.sortDescriptors.map(\.order) == [.forward])
    }

    @Test("Negative limits clamp to zero")
    func negativeLimitClampsToZero() {
      #expect(HealthKitQueryPlan(query: WorkoutQuery(limit: -3)).limit == 0)
    }
  }

  @Suite("Resolved time zone identifier")
  struct ResolvedTimeZoneIdentifierTests {
    private let fallback = TimeZone(identifier: "UTC")!

    @Test("Valid metadata identifier wins over the fallback")
    func validMetadataWins() {
      let identifier = HealthKitWorkoutSource.resolvedTimeZoneIdentifier(
        metadata: [HKMetadataKeyTimeZone: "Europe/Warsaw"],
        fallback: fallback
      )
      #expect(identifier == "Europe/Warsaw")
    }

    @Test("Invalid metadata identifier falls back")
    func invalidIdentifierFallsBack() {
      let identifier = HealthKitWorkoutSource.resolvedTimeZoneIdentifier(
        metadata: [HKMetadataKeyTimeZone: "Not/AZone"],
        fallback: fallback
      )
      #expect(identifier == fallback.identifier)
    }

    @Test("Missing metadata falls back")
    func missingMetadataFallsBack() {
      let fromNil = HealthKitWorkoutSource.resolvedTimeZoneIdentifier(
        metadata: nil,
        fallback: fallback
      )
      let fromEmpty = HealthKitWorkoutSource.resolvedTimeZoneIdentifier(
        metadata: [:],
        fallback: fallback
      )
      #expect(fromNil == fallback.identifier)
      #expect(fromEmpty == fallback.identifier)
    }
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
