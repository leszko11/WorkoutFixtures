import Foundation

public struct RedactionPolicy: Codable, Equatable, Sendable {
  public let regenerateID: Bool
  public let removeRoute: Bool
  public let removeSourceMetadata: Bool
  public let shiftDates: Bool

  public init(
    regenerateID: Bool,
    removeRoute: Bool,
    removeSourceMetadata: Bool,
    shiftDates: Bool
  ) {
    self.regenerateID = regenerateID
    self.removeRoute = removeRoute
    self.removeSourceMetadata = removeSourceMetadata
    self.shiftDates = shiftDates
  }

  public static let sharing = Self(
    regenerateID: true,
    removeRoute: true,
    removeSourceMetadata: true,
    shiftDates: true
  )
}

public struct WorkoutRedactor: Sendable {
  public init() {}

  public func redact(
    _ fixture: WorkoutFixture,
    using policy: RedactionPolicy = .sharing,
    seed: UInt64
  ) throws -> WorkoutFixture {
    let shifted: WorkoutFixture
    if policy.shiftDates {
      let magnitude = Int(seed % 336) + 30
      let direction = seed & 1 == 0 ? 1 : -1
      shifted = try TemplateWorkoutGenerator().generateSynchronouslyForRedaction(
        fixture,
        days: magnitude * direction
      )
    } else {
      shifted = fixture
    }
    return WorkoutFixture(
      id: policy.regenerateID
        ? WorkoutID(rawValue: "redacted-\(String(seed, radix: 16))")
        : shifted.id,
      workout: shifted.workout,
      series: shifted.series,
      events: shifted.events,
      route: policy.removeRoute ? nil : shifted.route,
      provenance: FixtureProvenance(
        kind: .redacted,
        createdAt: shifted.workout.startDate,
        sourceFixtureID: nil,
        generatorVersion: TemplateWorkoutGenerator.generatorVersion,
        seed: seed,
        source: policy.removeSourceMetadata ? nil : shifted.provenance.source
      )
    )
  }
}

extension TemplateWorkoutGenerator {
  fileprivate func generateSynchronouslyForRedaction(_ fixture: WorkoutFixture, days: Int) throws
    -> WorkoutFixture
  {
    try fixture.shiftingDatesForRedaction(byDays: days)
  }
}

extension WorkoutFixture {
  fileprivate func shiftingDatesForRedaction(byDays days: Int) throws -> Self {
    guard let timeZone = TimeZone(identifier: workout.timeZoneIdentifier) else {
      throw GenerationError.dateCalculationFailed
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    func shift(_ date: Date) throws -> Date {
      guard let result = calendar.date(byAdding: .day, value: days, to: date) else {
        throw GenerationError.dateCalculationFailed
      }
      return result
    }
    return WorkoutFixture(
      id: id,
      workout: WorkoutDescriptor(
        activity: workout.activity,
        location: workout.location,
        startDate: try shift(workout.startDate),
        endDate: try shift(workout.endDate),
        timeZoneIdentifier: workout.timeZoneIdentifier
      ),
      series: try series.map { item in
        MetricSeries(
          metric: item.metric, unit: item.unit,
          samples: try item.samples.map {
            MetricSample(
              startDate: try shift($0.startDate), endDate: try shift($0.endDate), value: $0.value)
          })
      },
      events: try events.map {
        WorkoutEvent(
          kind: $0.kind, startDate: try shift($0.startDate), endDate: try shift($0.endDate))
      },
      route: try route.map { route in
        WorkoutRoute(
          points: try route.points.map { point in
            RoutePoint(
              date: try shift(point.date),
              latitude: point.latitude,
              longitude: point.longitude,
              altitude: point.altitude,
              horizontalAccuracy: point.horizontalAccuracy,
              verticalAccuracy: point.verticalAccuracy,
              speed: point.speed,
              course: point.course
            )
          })
      },
      provenance: provenance
    )
  }
}
