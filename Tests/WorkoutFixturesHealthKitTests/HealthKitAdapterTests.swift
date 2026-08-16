#if canImport(HealthKit)
  import HealthKit
  import Testing
  import WorkoutFixtures
  @testable import WorkoutFixturesHealthKit

  @Test("HealthKit adapters satisfy Sendable public boundaries")
  func adaptersAreSendable() {
    func assertSendable<T: Sendable>(_: T.Type) {}
    assertSendable(HealthKitWorkoutSource.self)
    assertSendable(HealthKitWorkoutSink.self)
    assertSendable(HealthKitAuthorizationController.self)
  }

  @Test("HealthKit adapters initialize without requesting authorization")
  func adaptersInitialize() {
    let store = HKHealthStore()
    _ = HealthKitWorkoutSource(healthStore: store)
    _ = HealthKitWorkoutSink(healthStore: store)
    _ = HealthKitAuthorizationController(healthStore: store)
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
