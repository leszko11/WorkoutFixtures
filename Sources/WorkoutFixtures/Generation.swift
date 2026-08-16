import Foundation

public struct DoubleRange: Codable, Equatable, Sendable {
  public let lowerBound: Double
  public let upperBound: Double

  public init(_ value: Double) {
    lowerBound = value
    upperBound = value
  }

  public init(_ range: ClosedRange<Double>) {
    lowerBound = range.lowerBound
    upperBound = range.upperBound
  }
}

public struct IntegerRange: Codable, Equatable, Sendable {
  public let lowerBound: Int
  public let upperBound: Int

  public init(_ value: Int) {
    lowerBound = value
    upperBound = value
  }

  public init(_ range: ClosedRange<Int>) {
    lowerBound = range.lowerBound
    upperBound = range.upperBound
  }
}

public struct Coordinate: Codable, Equatable, Sendable {
  public let latitude: Double
  public let longitude: Double

  public init(latitude: Double, longitude: Double) {
    self.latitude = latitude
    self.longitude = longitude
  }
}

enum GenerationTransformKind: String, Codable, Sendable {
  case shiftDate
  case scaleDuration
  case scaleMetric
  case addNoise
  case resample
  case translateRoute
  case rotateRoute
  case jitterRoute
  case removeRoute
}

public enum GenerationTransform: Codable, Equatable, Sendable {
  case shiftDate(days: IntegerRange)
  case scaleDuration(DoubleRange)
  case scaleMetric(MetricIdentifier, factor: DoubleRange)
  case addNoise(to: MetricIdentifier, standardDeviation: Double, bounds: ClosedRange<Double>?)
  case resample(MetricIdentifier, every: TimeInterval)
  case translateRoute(to: Coordinate)
  case rotateRoute(degrees: Double)
  case jitterRoute(maxMeters: Double)
  case removeRoute

  private enum CodingKeys: String, CodingKey {
    case kind
    case metric
    case integerRange
    case valueRange
    case standardDeviation
    case minimum
    case maximum
    case intervalSeconds
    case coordinate
    case degrees
    case maxMeters
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(GenerationTransformKind.self, forKey: .kind) {
    case .shiftDate:
      self = .shiftDate(days: try container.decode(IntegerRange.self, forKey: .integerRange))
    case .scaleDuration:
      self = .scaleDuration(try container.decode(DoubleRange.self, forKey: .valueRange))
    case .scaleMetric:
      self = .scaleMetric(
        try container.decode(MetricIdentifier.self, forKey: .metric),
        factor: try container.decode(DoubleRange.self, forKey: .valueRange)
      )
    case .addNoise:
      self = .addNoise(
        to: try container.decode(MetricIdentifier.self, forKey: .metric),
        standardDeviation: try container.decode(Double.self, forKey: .standardDeviation),
        bounds: try Self.decodeNoiseBounds(from: container)
      )
    case .resample:
      self = .resample(
        try container.decode(MetricIdentifier.self, forKey: .metric),
        every: try container.decode(TimeInterval.self, forKey: .intervalSeconds)
      )
    case .translateRoute:
      self = .translateRoute(to: try container.decode(Coordinate.self, forKey: .coordinate))
    case .rotateRoute:
      self = .rotateRoute(degrees: try container.decode(Double.self, forKey: .degrees))
    case .jitterRoute:
      self = .jitterRoute(maxMeters: try container.decode(Double.self, forKey: .maxMeters))
    case .removeRoute:
      self = .removeRoute
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .shiftDate(let days):
      try container.encode(GenerationTransformKind.shiftDate, forKey: .kind)
      try container.encode(days, forKey: .integerRange)
    case .scaleDuration(let factor):
      try container.encode(GenerationTransformKind.scaleDuration, forKey: .kind)
      try container.encode(factor, forKey: .valueRange)
    case .scaleMetric(let metric, let factor):
      try container.encode(GenerationTransformKind.scaleMetric, forKey: .kind)
      try container.encode(metric, forKey: .metric)
      try container.encode(factor, forKey: .valueRange)
    case .addNoise(let metric, let standardDeviation, let bounds):
      try container.encode(GenerationTransformKind.addNoise, forKey: .kind)
      try container.encode(metric, forKey: .metric)
      try container.encode(standardDeviation, forKey: .standardDeviation)
      try container.encodeIfPresent(bounds?.lowerBound, forKey: .minimum)
      try container.encodeIfPresent(bounds?.upperBound, forKey: .maximum)
    case .resample(let metric, let interval):
      try container.encode(GenerationTransformKind.resample, forKey: .kind)
      try container.encode(metric, forKey: .metric)
      try container.encode(interval, forKey: .intervalSeconds)
    case .translateRoute(let coordinate):
      try container.encode(GenerationTransformKind.translateRoute, forKey: .kind)
      try container.encode(coordinate, forKey: .coordinate)
    case .rotateRoute(let degrees):
      try container.encode(GenerationTransformKind.rotateRoute, forKey: .kind)
      try container.encode(degrees, forKey: .degrees)
    case .jitterRoute(let maxMeters):
      try container.encode(GenerationTransformKind.jitterRoute, forKey: .kind)
      try container.encode(maxMeters, forKey: .maxMeters)
    case .removeRoute:
      try container.encode(GenerationTransformKind.removeRoute, forKey: .kind)
    }
  }

  private static func decodeNoiseBounds(
    from container: KeyedDecodingContainer<CodingKeys>
  ) throws -> ClosedRange<Double>? {
    let minimum = try container.decodeIfPresent(Double.self, forKey: .minimum)
    let maximum = try container.decodeIfPresent(Double.self, forKey: .maximum)
    switch (minimum, maximum) {
    case (nil, nil):
      return nil
    case (let minimum?, let maximum?) where minimum <= maximum:
      return minimum...maximum
    default:
      throw DecodingError.dataCorrupted(
        DecodingError.Context(
          codingPath: container.codingPath,
          debugDescription:
            "addNoise bounds require both minimum and maximum with minimum <= maximum."
        ))
    }
  }
}

public struct GenerationRecipe: Codable, Equatable, Sendable {
  public let transforms: [GenerationTransform]

  public init(transforms: [GenerationTransform]) {
    self.transforms = transforms
  }
}

public enum GenerationError: Error, Equatable, Sendable, LocalizedError {
  case invalidTransform(index: Int, message: String)
  case dateCalculationFailed

  public var errorDescription: String? {
    switch self {
    case .invalidTransform(let index, let message):
      "Invalid generation transform at index \(index): \(message)"
    case .dateCalculationFailed:
      "A requested calendar-date transformation could not be calculated."
    }
  }
}

public struct TemplateWorkoutGenerator: WorkoutGenerating, Sendable {
  public static let generatorVersion = "1"

  private let validator: WorkoutValidator

  public init(validator: WorkoutValidator = WorkoutValidator()) {
    self.validator = validator
  }

  @concurrent
  public func generate(
    from template: WorkoutFixture,
    recipe: GenerationRecipe,
    seed: UInt64
  ) async throws -> WorkoutFixture {
    try Task.checkCancellation()
    try validator.requireValid(template)
    var fixture = template
    for (index, transform) in recipe.transforms.enumerated() {
      try Task.checkCancellation()
      var random = SplitMix64(seed: SeedDeriver.derive(seed: seed, index: index))
      fixture = try apply(transform, at: index, to: fixture, random: &random)
    }

    let generated = WorkoutFixture(
      id: WorkoutID(rawValue: "\(template.id.rawValue)-\(String(seed, radix: 16))"),
      workout: fixture.workout,
      series: fixture.series,
      events: fixture.events,
      route: fixture.route,
      provenance: FixtureProvenance(
        kind: .generated,
        createdAt: fixture.workout.startDate,
        sourceFixtureID: template.id,
        generatorVersion: Self.generatorVersion,
        seed: seed
      )
    )
    try validator.requireValid(generated)
    return generated
  }

  @concurrent
  public func generate(
    count: Int,
    from template: WorkoutFixture,
    recipe: GenerationRecipe,
    seed: UInt64
  ) async throws -> [WorkoutFixture] {
    guard count >= 0 else {
      throw GenerationError.invalidTransform(index: -1, message: "Count cannot be negative.")
    }
    return try await withThrowingTaskGroup(of: (Int, WorkoutFixture).self) { group in
      for index in 0..<count {
        let outputSeed = SeedDeriver.derive(seed: seed, index: index)
        group.addTask {
          try Task.checkCancellation()
          return (
            index,
            try await generate(from: template, recipe: recipe, seed: outputSeed)
          )
        }
      }
      var outputs: [(Int, WorkoutFixture)] = []
      outputs.reserveCapacity(count)
      for try await output in group {
        outputs.append(output)
      }
      return outputs.sorted { $0.0 < $1.0 }.map(\.1)
    }
  }

  private func apply(
    _ transform: GenerationTransform,
    at index: Int,
    to fixture: WorkoutFixture,
    random: inout SplitMix64
  ) throws -> WorkoutFixture {
    switch transform {
    case .shiftDate(let days):
      guard days.lowerBound <= days.upperBound else {
        throw GenerationError.invalidTransform(
          index: index, message: "shiftDate requires a valid integerRange.")
      }
      return try fixture.shiftingDates(
        byDays: random.nextInt(in: days.lowerBound...days.upperBound)
      )
    case .scaleDuration(let range):
      guard range.lowerBound > 0, range.lowerBound <= range.upperBound else {
        throw GenerationError.invalidTransform(
          index: index, message: "scaleDuration requires a positive valueRange.")
      }
      return fixture.scalingTimeline(by: random.nextDouble(in: range.lowerBound...range.upperBound))
    case .scaleMetric(let metric, let range):
      guard range.lowerBound >= 0, range.lowerBound <= range.upperBound else {
        throw GenerationError.invalidTransform(
          index: index, message: "scaleMetric requires metric and nonnegative valueRange.")
      }
      let factor = random.nextDouble(in: range.lowerBound...range.upperBound)
      return fixture.mappingSamples(for: metric) { sample in
        MetricSample(
          startDate: sample.startDate,
          endDate: sample.endDate,
          value: sample.value * factor
        )
      }
    case .addNoise(let metric, let deviation, let bounds):
      guard deviation >= 0 else {
        throw GenerationError.invalidTransform(
          index: index,
          message: "addNoise requires metric, nonnegative deviation, and valid optional bounds.")
      }
      return fixture.mappingSamples(for: metric) { sample in
        var value = sample.value + random.nextStandardNormal() * deviation
        if let bounds {
          value = min(bounds.upperBound, max(bounds.lowerBound, value))
        }
        return MetricSample(startDate: sample.startDate, endDate: sample.endDate, value: value)
      }
    case .resample(let metric, let interval):
      guard interval > 0 else {
        throw GenerationError.invalidTransform(
          index: index, message: "resample requires metric and a positive intervalSeconds.")
      }
      return try fixture.resampling(metric, every: interval)
    case .translateRoute(let coordinate):
      guard (-90...90).contains(coordinate.latitude), (-180...180).contains(coordinate.longitude)
      else {
        throw GenerationError.invalidTransform(
          index: index, message: "translateRoute requires a valid coordinate.")
      }
      return fixture.mappingRoute { points in points.translated(to: coordinate) }
    case .rotateRoute(let degrees):
      guard degrees.isFinite else {
        throw GenerationError.invalidTransform(
          index: index, message: "rotateRoute requires finite degrees.")
      }
      return fixture.mappingRoute { points in points.rotated(degrees: degrees) }
    case .jitterRoute(let maxMeters):
      guard maxMeters >= 0, maxMeters.isFinite else {
        throw GenerationError.invalidTransform(
          index: index, message: "jitterRoute requires nonnegative maxMeters.")
      }
      return try fixture.mappingRoute { points in
        try points.enumerated().map { index, point in
          if index.isMultiple(of: 256) { try Task.checkCancellation() }
          return point.jittered(maxMeters: maxMeters, random: &random)
        }
      }
    case .removeRoute:
      return fixture.replacingRoute(nil)
    }
  }
}

struct SplitMix64: Sendable {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var result = state
    result = (result ^ (result >> 30)) &* 0xBF58_476D_1CE4_E5B9
    result = (result ^ (result >> 27)) &* 0x94D0_49BB_1331_11EB
    return result ^ (result >> 31)
  }

  mutating func nextDouble(in range: ClosedRange<Double>) -> Double {
    let unit = Double(next() >> 11) * 0x1.0p-53
    return range.lowerBound + (range.upperBound - range.lowerBound) * unit
  }

  mutating func nextInt(in range: ClosedRange<Int>) -> Int {
    guard range.lowerBound != range.upperBound else { return range.lowerBound }
    let width = UInt64(range.upperBound - range.lowerBound + 1)
    return range.lowerBound + Int(next() % width)
  }

  mutating func nextStandardNormal() -> Double {
    var sum = 0.0
    for _ in 0..<12 {
      sum += nextDouble(in: 0...1)
    }
    return sum - 6
  }
}

private enum SeedDeriver {
  static func derive(seed: UInt64, index: Int) -> UInt64 {
    var random = SplitMix64(seed: seed ^ UInt64(truncatingIfNeeded: index) &* 0xD6E8_FEB8_6659_FD93)
    return random.next()
  }
}

extension WorkoutFixture {
  func shiftingDates(byDays days: Int, shiftProvenanceCreatedAt: Bool = true) throws -> Self {
    guard days != 0 else { return self }
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
          metric: item.metric,
          unit: item.unit,
          samples: try item.samples.map {
            MetricSample(
              startDate: try shift($0.startDate),
              endDate: try shift($0.endDate),
              value: $0.value
            )
          }
        )
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
      provenance: FixtureProvenance(
        kind: provenance.kind,
        createdAt: shiftProvenanceCreatedAt
          ? try shift(provenance.createdAt)
          : provenance.createdAt,
        sourceFixtureID: provenance.sourceFixtureID,
        generatorVersion: provenance.generatorVersion,
        seed: provenance.seed,
        source: provenance.source
      )
    )
  }

  fileprivate func scalingTimeline(by factor: Double) -> Self {
    let origin = workout.startDate
    func scale(_ date: Date) -> Date {
      origin.addingTimeInterval(date.timeIntervalSince(origin) * factor)
    }
    return WorkoutFixture(
      id: id,
      workout: WorkoutDescriptor(
        activity: workout.activity,
        location: workout.location,
        startDate: origin,
        endDate: scale(workout.endDate),
        timeZoneIdentifier: workout.timeZoneIdentifier
      ),
      series: series.map { item in
        MetricSeries(
          metric: item.metric,
          unit: item.unit,
          samples: item.samples.map {
            MetricSample(
              startDate: scale($0.startDate), endDate: scale($0.endDate), value: $0.value)
          }
        )
      },
      events: events.map {
        WorkoutEvent(kind: $0.kind, startDate: scale($0.startDate), endDate: scale($0.endDate))
      },
      route: route.map { route in
        WorkoutRoute(
          points: route.points.map { point in
            RoutePoint(
              date: scale(point.date),
              latitude: point.latitude,
              longitude: point.longitude,
              altitude: point.altitude,
              horizontalAccuracy: point.horizontalAccuracy,
              verticalAccuracy: point.verticalAccuracy,
              speed: point.speed.map { $0 / factor },
              course: point.course
            )
          })
      },
      provenance: provenance
    )
  }

  fileprivate func mappingSamples(
    for metric: MetricIdentifier,
    _ transform: (MetricSample) throws -> MetricSample
  ) rethrows -> Self {
    try replacingSeries(
      series.map { item in
        guard item.metric == metric else { return item }
        return MetricSeries(
          metric: item.metric, unit: item.unit, samples: try item.samples.map(transform))
      })
  }

  fileprivate func resampling(_ metric: MetricIdentifier, every interval: TimeInterval) throws
    -> Self
  {
    guard let original = series(for: metric), !original.samples.isEmpty else { return self }
    var output: [MetricSample] = []
    var bucketStart = workout.startDate
    while bucketStart < workout.endDate {
      if output.count.isMultiple(of: 256) { try Task.checkCancellation() }
      let bucketEnd = min(workout.endDate, bucketStart.addingTimeInterval(interval))
      let overlapping = original.samples.filter {
        $0.endDate > bucketStart && $0.startDate < bucketEnd
      }
      if !overlapping.isEmpty {
        let value: Double
        if metric == .heartRate {
          value = overlapping.reduce(0) { $0 + $1.value } / Double(overlapping.count)
        } else {
          value = overlapping.reduce(0) { partial, sample in
            let sampleDuration = max(sample.endDate.timeIntervalSince(sample.startDate), 1)
            let overlapStart = max(sample.startDate, bucketStart)
            let overlapEnd = min(sample.endDate, bucketEnd)
            let fraction = max(0, overlapEnd.timeIntervalSince(overlapStart)) / sampleDuration
            return partial + sample.value * fraction
          }
        }
        output.append(MetricSample(startDate: bucketStart, endDate: bucketEnd, value: value))
      }
      bucketStart = bucketEnd
    }
    return replacingSeries(
      series.map {
        $0.metric == metric ? MetricSeries(metric: metric, unit: $0.unit, samples: output) : $0
      })
  }

  fileprivate func mappingRoute(_ transform: ([RoutePoint]) throws -> [RoutePoint]) rethrows -> Self
  {
    guard let route else { return self }
    return try replacingRoute(WorkoutRoute(points: transform(route.points)))
  }

  fileprivate func replacingSeries(_ series: [MetricSeries]) -> Self {
    WorkoutFixture(
      id: id,
      workout: workout,
      series: series,
      events: events,
      route: route,
      provenance: provenance
    )
  }

  fileprivate func replacingRoute(_ route: WorkoutRoute?) -> Self {
    WorkoutFixture(
      id: id,
      workout: workout,
      series: series,
      events: events,
      route: route,
      provenance: provenance
    )
  }
}

extension [RoutePoint] {
  fileprivate var center: Coordinate? {
    guard !isEmpty else { return nil }
    return Coordinate(
      latitude: reduce(0) { $0 + $1.latitude } / Double(count),
      longitude: reduce(0) { $0 + $1.longitude } / Double(count)
    )
  }

  fileprivate func translated(to target: Coordinate) -> Self {
    guard let center else { return self }
    let latitudeOffset = target.latitude - center.latitude
    let longitudeOffset = target.longitude - center.longitude
    return map {
      $0.replacing(
        latitude: Swift.min(90, Swift.max(-90, $0.latitude + latitudeOffset)),
        longitude: Self.normalizedLongitude($0.longitude + longitudeOffset)
      )
    }
  }

  fileprivate func rotated(degrees: Double) -> Self {
    guard let center else { return self }
    let radians = degrees * .pi / 180
    let latitudeScale = Swift.max(cos(center.latitude * .pi / 180), 0.000_001)
    return map { point in
      let x = (point.longitude - center.longitude) * latitudeScale
      let y = point.latitude - center.latitude
      let rotatedX = x * cos(radians) - y * sin(radians)
      let rotatedY = x * sin(radians) + y * cos(radians)
      return point.replacing(
        latitude: Swift.min(90, Swift.max(-90, center.latitude + rotatedY)),
        longitude: Self.normalizedLongitude(center.longitude + rotatedX / latitudeScale)
      )
    }
  }

  fileprivate static func normalizedLongitude(_ longitude: Double) -> Double {
    var result = longitude
    while result > 180 { result -= 360 }
    while result < -180 { result += 360 }
    return result
  }
}

extension RoutePoint {
  fileprivate func jittered(maxMeters: Double, random: inout SplitMix64) -> Self {
    let distance = random.nextDouble(in: 0...maxMeters)
    let angle = random.nextDouble(in: 0...(2 * .pi))
    let latitudeDelta = (distance * cos(angle)) / 111_320
    let longitudeScale = max(cos(latitude * .pi / 180), 0.000_001)
    let longitudeDelta = (distance * sin(angle)) / (111_320 * longitudeScale)
    return replacing(
      latitude: min(90, max(-90, latitude + latitudeDelta)),
      longitude: [RoutePoint].normalizedLongitude(longitude + longitudeDelta)
    )
  }

  fileprivate func replacing(latitude: Double, longitude: Double) -> Self {
    RoutePoint(
      date: date,
      latitude: latitude,
      longitude: longitude,
      altitude: altitude,
      horizontalAccuracy: horizontalAccuracy,
      verticalAccuracy: verticalAccuracy,
      speed: speed,
      course: course
    )
  }
}
