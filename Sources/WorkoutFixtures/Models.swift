import Foundation

/// The version of the fixture JSON schema; codecs reject anything other than ``current``.
public struct SchemaVersion: RawRepresentable, Codable, Hashable, Sendable, Comparable {
  /// The schema version this library reads and writes.
  public static let current = SchemaVersion(rawValue: 1)

  public let rawValue: Int

  public init(rawValue: Int) {
    self.rawValue = rawValue
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

/// The stable identifier of a workout fixture; any non-empty string is valid.
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

/// The workout activity types the fixture schema supports.
///
/// Each case corresponds to the non-deprecated `HKWorkoutActivityType` of the
/// same name (as of iOS 17). The raw value is the wire format, so cases must
/// stay in sync with the `activity` enum in `WorkoutFixture.schema.json`;
/// a test asserts that parity.
public enum WorkoutActivity: String, Codable, CaseIterable, Sendable {
  case americanFootball
  case archery
  case australianFootball
  case badminton
  case barre
  case baseball
  case basketball
  case bowling
  case boxing
  case cardioDance
  case climbing
  case cooldown
  case coreTraining
  case cricket
  case crossCountrySkiing
  case crossTraining
  case curling
  case cycling
  case dance
  case discSports
  case downhillSkiing
  case elliptical
  case equestrianSports
  case fencing
  case fishing
  case fitnessGaming
  case flexibility
  case functionalStrengthTraining
  case golf
  case gymnastics
  case handCycling
  case handball
  case highIntensityIntervalTraining
  case hiking
  case hockey
  case hunting
  case jumpRope
  case kickboxing
  case lacrosse
  case martialArts
  case mindAndBody
  case mixedCardio
  case paddleSports
  case pickleball
  case pilates
  case play
  case preparationAndRecovery
  case racquetball
  case rowing
  case rugby
  case running
  case sailing
  case skatingSports
  case snowSports
  case snowboarding
  case soccer
  case socialDance
  case softball
  case squash
  case stairClimbing
  case stairs
  case stepTraining
  case surfingSports
  case swimBikeRun
  case swimming
  case tableTennis
  case taiChi
  case tennis
  case trackAndField
  case traditionalStrengthTraining
  case transition
  case underwaterDiving
  case volleyball
  case walking
  case waterFitness
  case waterPolo
  case waterSports
  case wheelchairRunPace
  case wheelchairWalkPace
  case wrestling
  case yoga
}

/// Where the workout took place, when known.
public enum WorkoutLocation: String, Codable, CaseIterable, Sendable {
  case indoor
  case outdoor
  case unknown
}

/// The core facts of a workout: what, where, and when.
public struct WorkoutDescriptor: Codable, Equatable, Sendable {
  public let activity: WorkoutActivity
  public let location: WorkoutLocation
  /// Wall-clock start; every sample, event, and route point must fall inside
  /// `startDate...endDate`.
  public let startDate: Date
  public let endDate: Date
  /// The IANA identifier of the zone the workout was recorded in; used for calendar-day date
  /// shifts. Validation rejects identifiers `TimeZone` does not recognize.
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

/// The metric kinds a fixture can carry as time series.
///
/// `heartRate` samples are instantaneous rates; `distance` and `activeEnergy` samples are the
/// amounts accrued during each sample's interval, so summing them yields the workout total.
public enum MetricIdentifier: String, Codable, CaseIterable, Sendable {
  case heartRate
  case distance
  case activeEnergy

  /// The only unit the schema accepts for this metric.
  public var canonicalUnit: UnitIdentifier {
    switch self {
    case .heartRate: .countPerMinute
    case .distance: .meter
    case .activeEnergy: .kilocalorie
    }
  }
}

/// Measurement units, spelled as HealthKit-compatible unit strings.
public enum UnitIdentifier: String, Codable, CaseIterable, Sendable {
  case countPerMinute = "count/min"
  case meter = "m"
  case kilocalorie = "kcal"
}

/// One measured value over a time interval; instantaneous readings use equal start and end.
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

/// All samples of one metric, in chronological, non-overlapping order.
public struct MetricSeries: Codable, Equatable, Sendable, Identifiable {
  public var id: MetricIdentifier { metric }

  public let metric: MetricIdentifier
  public let unit: UnitIdentifier
  public let samples: [MetricSample]

  /// Creates a series.
  /// - Parameter unit: Pass `nil` to use the metric's canonical unit; validation rejects any
  ///   other unit, so the parameter mainly serves round-tripping decoded data.
  public init(metric: MetricIdentifier, unit: UnitIdentifier? = nil, samples: [MetricSample]) {
    self.metric = metric
    self.unit = unit ?? metric.canonicalUnit
    self.samples = samples
  }
}

/// Timeline events a workout can contain.
///
/// `pause` and `resume` must alternate, starting with a pause; the time between them counts
/// as paused and is excluded from ``WorkoutSummary/activeDuration``.
public enum WorkoutEventKind: String, Codable, CaseIterable, Sendable {
  case pause
  case resume
  case lap
  case segment
  case marker
}

/// An event on the workout timeline; instantaneous events have equal start and end dates.
public struct WorkoutEvent: Codable, Equatable, Sendable {
  public let kind: WorkoutEventKind
  public let startDate: Date
  public let endDate: Date

  /// Creates an event; omitting `endDate` makes it instantaneous (`endDate == startDate`).
  public init(kind: WorkoutEventKind, startDate: Date, endDate: Date? = nil) {
    self.kind = kind
    self.startDate = startDate
    self.endDate = endDate ?? startDate
  }
}

/// A single GPS fix on the workout route.
///
/// The optional fields mirror `CLLocation` and use its conventions: accuracies and altitude in
/// meters, speed in meters per second, course in degrees clockwise from true north.
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

/// The GPS trace of a workout, as points ordered by date.
public struct WorkoutRoute: Codable, Equatable, Sendable {
  public let points: [RoutePoint]

  public init(points: [RoutePoint]) {
    self.points = points
  }
}

/// Identifies the app and device that originally recorded a captured workout.
///
/// This is user-identifying metadata; ``RedactionPolicy/sharing`` strips it before a fixture
/// leaves the device it was captured on.
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

/// How a fixture came to exist.
public enum ProvenanceKind: String, Codable, Sendable {
  /// Read from a real store such as HealthKit.
  case captured
  /// Derived from a template by a ``WorkoutGenerating`` implementation.
  case generated
  /// Written by hand (or by tooling other than capture, generation, or redaction).
  case authored
  /// Produced by ``WorkoutRedactor``; identifying details have been removed.
  case redacted
}

/// The origin story of a fixture: how, when, and from what it was created.
public struct FixtureProvenance: Codable, Equatable, Sendable {
  public let kind: ProvenanceKind
  public let createdAt: Date
  /// The template this fixture was generated from; set only for ``ProvenanceKind/generated``.
  public let sourceFixtureID: WorkoutID?
  /// The ``TemplateWorkoutGenerator/generatorVersion`` that produced this fixture, so outputs
  /// can be regenerated when the generator's behavior changes.
  public let generatorVersion: String?
  /// The root seed used for generation; redacted fixtures never carry a seed.
  public let seed: UInt64?
  /// Recording app/device metadata; present only on captured fixtures that keep it.
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

/// A complete, self-contained workout recording.
///
/// A fixture bundles the descriptor, metric series, timeline events, optional GPS route, and
/// provenance into one value that round-trips through the canonical JSON codecs. Use
/// ``WorkoutValidator`` to check the semantic rules (bounds, ordering, units) the type itself
/// does not enforce.
public struct WorkoutFixture: Codable, Equatable, Sendable, Identifiable {
  public let schemaVersion: SchemaVersion
  public let id: WorkoutID
  public let workout: WorkoutDescriptor
  /// At most one series per metric; validation reports duplicates as errors.
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

/// A lightweight listing row for a workout, cheap enough to build for query results.
public struct WorkoutSummary: Codable, Equatable, Sendable, Identifiable {
  public let id: WorkoutID
  public let activity: WorkoutActivity
  public let location: WorkoutLocation
  public let startDate: Date
  public let endDate: Date
  /// Wall-clock time from start to end, including pauses.
  public let elapsedDuration: TimeInterval
  /// Elapsed time minus the paused time between pause/resume events.
  public let activeDuration: TimeInterval
  public let distanceMeters: Double?
  public let activeEnergyKilocalories: Double?
  /// Duration-weighted mean heart rate in count/min, or `nil` when no samples exist.
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

  /// Derives the summary from a fixture: totals for distance and energy, the duration-weighted
  /// heart-rate average, and an active duration that excludes paused time.
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
  /// A listing summary derived from this fixture; computed on each access.
  public var summary: WorkoutSummary { WorkoutSummary(fixture: self) }

  /// The series carrying `metric`, or `nil` when the fixture has none.
  public func series(for metric: MetricIdentifier) -> MetricSeries? {
    series.first { $0.metric == metric }
  }

  /// The sum of the metric's sample values (meaningful for cumulative metrics such as distance
  /// and energy), or `nil` when the series is missing or empty.
  public func total(for metric: MetricIdentifier) -> Double? {
    guard let metricSeries = series(for: metric), !metricSeries.samples.isEmpty else { return nil }
    return metricSeries.samples.reduce(0) { $0 + $1.value }
  }

  /// The duration-weighted mean of the metric's samples — each sample weighted by its interval
  /// length, with a one-second floor so instantaneous samples still count — or `nil` when the
  /// series is missing or empty.
  public func average(for metric: MetricIdentifier) -> Double? {
    guard let samples = series(for: metric)?.samples, !samples.isEmpty else { return nil }
    let weighted = samples.reduce(into: (value: 0.0, duration: 0.0)) { partial, sample in
      let duration = max(sample.endDate.timeIntervalSince(sample.startDate), 1)
      partial.value += sample.value * duration
      partial.duration += duration
    }
    return weighted.value / weighted.duration
  }

  /// Total time spent paused, from matched pause/resume event pairs.
  ///
  /// A pause with no matching resume runs until the workout's end date; the result is clamped
  /// to the elapsed duration.
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
