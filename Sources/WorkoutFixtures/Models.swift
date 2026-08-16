import Foundation

public struct SchemaVersion: RawRepresentable, Codable, Hashable, Sendable, Comparable {
  public static let current = SchemaVersion(rawValue: 1)

  public let rawValue: Int

  public init(rawValue: Int) {
    self.rawValue = rawValue
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

public struct WorkoutID: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral,
  CustomStringConvertible
{
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(stringLiteral value: String) {
    self.init(rawValue: value)
  }

  public var description: String { rawValue }
}

public enum WorkoutActivity: String, Codable, CaseIterable, Sendable {
  case running
  case walking
  case cycling
}

public enum WorkoutLocation: String, Codable, CaseIterable, Sendable {
  case indoor
  case outdoor
  case unknown
}

public struct WorkoutDescriptor: Codable, Equatable, Sendable {
  public let activity: WorkoutActivity
  public let location: WorkoutLocation
  public let startDate: Date
  public let endDate: Date
  public let timeZoneIdentifier: String

  public init(
    activity: WorkoutActivity,
    location: WorkoutLocation,
    startDate: Date,
    endDate: Date,
    timeZoneIdentifier: String
  ) {
    self.activity = activity
    self.location = location
    self.startDate = startDate
    self.endDate = endDate
    self.timeZoneIdentifier = timeZoneIdentifier
  }
}

public enum MetricIdentifier: String, Codable, CaseIterable, Sendable {
  case heartRate
  case distance
  case activeEnergy

  public var canonicalUnit: UnitIdentifier {
    switch self {
    case .heartRate: .countPerMinute
    case .distance: .meter
    case .activeEnergy: .kilocalorie
    }
  }
}

public enum UnitIdentifier: String, Codable, CaseIterable, Sendable {
  case countPerMinute = "count/min"
  case meter = "m"
  case kilocalorie = "kcal"
}

public struct MetricSample: Codable, Equatable, Sendable {
  public let startDate: Date
  public let endDate: Date
  public let value: Double

  public init(startDate: Date, endDate: Date, value: Double) {
    self.startDate = startDate
    self.endDate = endDate
    self.value = value
  }
}

public struct MetricSeries: Codable, Equatable, Sendable, Identifiable {
  public var id: MetricIdentifier { metric }

  public let metric: MetricIdentifier
  public let unit: UnitIdentifier
  public let samples: [MetricSample]

  public init(metric: MetricIdentifier, unit: UnitIdentifier? = nil, samples: [MetricSample]) {
    self.metric = metric
    self.unit = unit ?? metric.canonicalUnit
    self.samples = samples
  }
}

public enum WorkoutEventKind: String, Codable, CaseIterable, Sendable {
  case pause
  case resume
  case lap
  case segment
  case marker
}

public struct WorkoutEvent: Codable, Equatable, Sendable {
  public let kind: WorkoutEventKind
  public let startDate: Date
  public let endDate: Date

  public init(kind: WorkoutEventKind, startDate: Date, endDate: Date? = nil) {
    self.kind = kind
    self.startDate = startDate
    self.endDate = endDate ?? startDate
  }
}

public struct RoutePoint: Codable, Equatable, Sendable {
  public let date: Date
  public let latitude: Double
  public let longitude: Double
  public let altitude: Double?
  public let horizontalAccuracy: Double?
  public let verticalAccuracy: Double?
  public let speed: Double?
  public let course: Double?

  public init(
    date: Date,
    latitude: Double,
    longitude: Double,
    altitude: Double? = nil,
    horizontalAccuracy: Double? = nil,
    verticalAccuracy: Double? = nil,
    speed: Double? = nil,
    course: Double? = nil
  ) {
    self.date = date
    self.latitude = latitude
    self.longitude = longitude
    self.altitude = altitude
    self.horizontalAccuracy = horizontalAccuracy
    self.verticalAccuracy = verticalAccuracy
    self.speed = speed
    self.course = course
  }
}

public struct WorkoutRoute: Codable, Equatable, Sendable {
  public let points: [RoutePoint]

  public init(points: [RoutePoint]) {
    self.points = points
  }
}

public struct SourceProvenance: Codable, Equatable, Sendable {
  public let name: String?
  public let bundleIdentifier: String?
  public let version: String?
  public let deviceModel: String?

  public init(
    name: String? = nil,
    bundleIdentifier: String? = nil,
    version: String? = nil,
    deviceModel: String? = nil
  ) {
    self.name = name
    self.bundleIdentifier = bundleIdentifier
    self.version = version
    self.deviceModel = deviceModel
  }
}

public enum ProvenanceKind: String, Codable, Sendable {
  case captured
  case generated
  case authored
  case redacted
}

public struct FixtureProvenance: Codable, Equatable, Sendable {
  public let kind: ProvenanceKind
  public let createdAt: Date
  public let sourceFixtureID: WorkoutID?
  public let generatorVersion: String?
  public let seed: UInt64?
  public let source: SourceProvenance?

  public init(
    kind: ProvenanceKind,
    createdAt: Date,
    sourceFixtureID: WorkoutID? = nil,
    generatorVersion: String? = nil,
    seed: UInt64? = nil,
    source: SourceProvenance? = nil
  ) {
    self.kind = kind
    self.createdAt = createdAt
    self.sourceFixtureID = sourceFixtureID
    self.generatorVersion = generatorVersion
    self.seed = seed
    self.source = source
  }
}

public struct WorkoutFixture: Codable, Equatable, Sendable, Identifiable {
  public let schemaVersion: SchemaVersion
  public let id: WorkoutID
  public let workout: WorkoutDescriptor
  public let series: [MetricSeries]
  public let events: [WorkoutEvent]
  public let route: WorkoutRoute?
  public let provenance: FixtureProvenance

  public init(
    schemaVersion: SchemaVersion = .current,
    id: WorkoutID,
    workout: WorkoutDescriptor,
    series: [MetricSeries],
    events: [WorkoutEvent] = [],
    route: WorkoutRoute? = nil,
    provenance: FixtureProvenance
  ) {
    self.schemaVersion = schemaVersion
    self.id = id
    self.workout = workout
    self.series = series
    self.events = events
    self.route = route
    self.provenance = provenance
  }
}

public struct WorkoutSummary: Codable, Equatable, Sendable, Identifiable {
  public let id: WorkoutID
  public let activity: WorkoutActivity
  public let location: WorkoutLocation
  public let startDate: Date
  public let endDate: Date
  public let elapsedDuration: TimeInterval
  public let activeDuration: TimeInterval
  public let distanceMeters: Double?
  public let activeEnergyKilocalories: Double?
  public let averageHeartRate: Double?
  public let hasRoute: Bool

  public init(
    id: WorkoutID,
    activity: WorkoutActivity,
    location: WorkoutLocation,
    startDate: Date,
    endDate: Date,
    elapsedDuration: TimeInterval,
    activeDuration: TimeInterval,
    distanceMeters: Double?,
    activeEnergyKilocalories: Double?,
    averageHeartRate: Double?,
    hasRoute: Bool
  ) {
    self.id = id
    self.activity = activity
    self.location = location
    self.startDate = startDate
    self.endDate = endDate
    self.elapsedDuration = elapsedDuration
    self.activeDuration = activeDuration
    self.distanceMeters = distanceMeters
    self.activeEnergyKilocalories = activeEnergyKilocalories
    self.averageHeartRate = averageHeartRate
    self.hasRoute = hasRoute
  }

  public init(fixture: WorkoutFixture) {
    id = fixture.id
    activity = fixture.workout.activity
    location = fixture.workout.location
    startDate = fixture.workout.startDate
    endDate = fixture.workout.endDate
    elapsedDuration = max(0, endDate.timeIntervalSince(startDate))
    activeDuration = max(0, elapsedDuration - fixture.pausedDuration)
    distanceMeters = fixture.total(for: .distance)
    activeEnergyKilocalories = fixture.total(for: .activeEnergy)
    averageHeartRate = fixture.average(for: .heartRate)
    hasRoute = fixture.route?.points.isEmpty == false
  }
}

extension WorkoutFixture {
  public var summary: WorkoutSummary { WorkoutSummary(fixture: self) }

  public func series(for metric: MetricIdentifier) -> MetricSeries? {
    series.first { $0.metric == metric }
  }

  public func total(for metric: MetricIdentifier) -> Double? {
    guard let metricSeries = series(for: metric), !metricSeries.samples.isEmpty else { return nil }
    return metricSeries.samples.reduce(0) { $0 + $1.value }
  }

  public func average(for metric: MetricIdentifier) -> Double? {
    guard let samples = series(for: metric)?.samples, !samples.isEmpty else { return nil }
    let weighted = samples.reduce(into: (value: 0.0, duration: 0.0)) { partial, sample in
      let duration = max(sample.endDate.timeIntervalSince(sample.startDate), 1)
      partial.value += sample.value * duration
      partial.duration += duration
    }
    return weighted.value / weighted.duration
  }

  public var pausedDuration: TimeInterval {
    var pauseStart: Date?
    var total: TimeInterval = 0
    for event in events.sorted(by: { $0.startDate < $1.startDate }) {
      switch event.kind {
      case .pause:
        pauseStart = pauseStart ?? event.startDate
      case .resume:
        if let start = pauseStart {
          total += max(0, event.startDate.timeIntervalSince(start))
          pauseStart = nil
        }
      case .lap, .segment, .marker:
        break
      }
    }
    if let pauseStart {
      total += max(0, workout.endDate.timeIntervalSince(pauseStart))
    }
    return min(total, max(0, workout.endDate.timeIntervalSince(workout.startDate)))
  }
}
