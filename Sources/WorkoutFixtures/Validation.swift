import Foundation

/// How serious a validation finding is; only errors fail
/// ``WorkoutValidator/requireValid(_:)``.
public enum ValidationSeverity: String, Codable, Comparable, Sendable {
  /// Suspicious but usable data (empty series, unusual heart rate, large gaps).
  case warning
  /// A violation of the fixture schema's semantic rules; the fixture should be rejected.
  case error

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs == .warning && rhs == .error
  }
}

/// A single validation finding at a specific location in a fixture.
public struct ValidationIssue: Codable, Equatable, Sendable {
  public let severity: ValidationSeverity
  /// A stable, machine-readable identifier such as `"sample.outOfBounds"`; suitable for
  /// filtering or suppressing specific findings.
  public let code: String
  /// A JSON-path-like location of the offending data, e.g. `"series[0].samples[2].value"`.
  public let path: String
  /// A human-readable explanation of the finding.
  public let message: String

  public init(severity: ValidationSeverity, code: String, path: String, message: String) {
    self.severity = severity
    self.code = code
    self.path = path
    self.message = message
  }
}

/// Thrown by ``WorkoutValidator/requireValid(_:)`` when a fixture has error-severity issues.
public struct FixtureValidationError: Error, Equatable, Sendable, LocalizedError {
  /// Every issue found, warnings included, so callers can report the full picture.
  public let issues: [ValidationIssue]

  public init(issues: [ValidationIssue]) {
    self.issues = issues
  }

  public var errorDescription: String? {
    "Fixture validation failed with \(issues.filter { $0.severity == .error }.count) error(s)."
  }
}

/// Checks fixtures against the semantic rules the type system cannot enforce.
///
/// Errors cover schema version, empty IDs, reversed or out-of-bounds dates, invalid time
/// zones, duplicate metrics, wrong units, unordered or non-finite samples, unbalanced
/// pause/resume events, and invalid route coordinates. Warnings flag suspicious but usable
/// data such as empty series, unusual heart rates, and long sample gaps.
public struct WorkoutValidator: Sendable {
  public init() {}

  /// Returns every issue found in `fixture`; an empty array means fully valid.
  public func validate(_ fixture: WorkoutFixture) -> [ValidationIssue] {
    var issues: [ValidationIssue] = []
    // A reversed workout is reported via workout.invalidBounds below; forming the
    // range unconditionally would trap, so containment checks are skipped instead.
    let bounds: ClosedRange<Date>? =
      fixture.workout.startDate <= fixture.workout.endDate
      ? fixture.workout.startDate...fixture.workout.endDate
      : nil

    if fixture.schemaVersion != .current {
      issues.append(
        .error(
          "schema.unsupported",
          "schemaVersion",
          "Expected schema version \(SchemaVersion.current.rawValue)."
        ))
    }
    if fixture.id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      issues.append(.error("id.empty", "id", "Workout ID must not be empty."))
    }
    if fixture.workout.startDate >= fixture.workout.endDate {
      issues.append(
        .error(
          "workout.invalidBounds",
          "workout",
          "Workout startDate must be earlier than endDate."
        ))
    }
    if TimeZone(identifier: fixture.workout.timeZoneIdentifier) == nil {
      issues.append(
        .error(
          "workout.invalidTimeZone",
          "workout.timeZoneIdentifier",
          "Use a valid IANA time-zone identifier."
        ))
    }

    let duplicates = Dictionary(grouping: fixture.series, by: \MetricSeries.metric)
      .filter { $0.value.count > 1 }
    for metric in duplicates.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
      issues.append(
        .error(
          "series.duplicateMetric",
          "series",
          "Metric '\(metric.rawValue)' appears more than once."
        ))
    }

    for (seriesIndex, series) in fixture.series.enumerated() {
      let base = "series[\(seriesIndex)]"
      if series.unit != series.metric.canonicalUnit {
        issues.append(
          .error(
            "series.incompatibleUnit",
            "\(base).unit",
            "Metric '\(series.metric.rawValue)' requires unit '\(series.metric.canonicalUnit.rawValue)'."
          ))
      }
      if series.samples.isEmpty {
        issues.append(
          .warning(
            "series.empty",
            "\(base).samples",
            "The metric series contains no samples."
          ))
      }
      var previousEnd: Date?
      for (sampleIndex, sample) in series.samples.enumerated() {
        let path = "\(base).samples[\(sampleIndex)]"
        let priorEnd = previousEnd
        if !sample.value.isFinite {
          issues.append(.error("sample.nonFinite", "\(path).value", "Sample value must be finite."))
        }
        if sample.startDate > sample.endDate {
          issues.append(
            .error("sample.invalidBounds", path, "Sample startDate must not follow endDate."))
        }
        if let bounds, !bounds.contains(sample.startDate) || !bounds.contains(sample.endDate) {
          issues.append(.error("sample.outOfBounds", path, "Sample must be inside workout bounds."))
        }
        if let priorEnd, sample.startDate < priorEnd {
          issues.append(
            .error("sample.unordered", path, "Samples must be ordered and non-overlapping."))
        }
        previousEnd = sample.endDate
        if series.metric != .heartRate, sample.value < 0 {
          issues.append(
            .error(
              "sample.negativeCumulativeValue",
              "\(path).value",
              "Distance and energy samples cannot be negative."
            ))
        }
        if series.metric == .heartRate, !(30...240).contains(sample.value) {
          issues.append(
            .warning(
              "sample.unusualHeartRate",
              "\(path).value",
              "Heart rate is outside the usual 30–240 count/min range."
            ))
        }
        if let priorEnd, sample.startDate.timeIntervalSince(priorEnd) > 300 {
          issues.append(
            .warning(
              "series.largeGap",
              path,
              "Metric series contains a gap longer than five minutes."
            ))
        }
      }
    }

    var isPaused = false
    for (index, event) in fixture.events.enumerated().sorted(by: {
      $0.element.startDate < $1.element.startDate
    }) {
      let path = "events[\(index)]"
      if event.startDate > event.endDate {
        issues.append(
          .error("event.invalidBounds", path, "Event startDate must not follow endDate."))
      }
      if let bounds, !bounds.contains(event.startDate) || !bounds.contains(event.endDate) {
        issues.append(.error("event.outOfBounds", path, "Event must be inside workout bounds."))
      }
      switch event.kind {
      case .pause where isPaused:
        issues.append(
          .error("event.duplicatePause", path, "A paused workout cannot be paused again."))
      case .pause:
        isPaused = true
      case .resume where !isPaused:
        issues.append(
          .error("event.resumeWithoutPause", path, "Resume requires a preceding pause."))
      case .resume:
        isPaused = false
      case .lap, .segment, .marker:
        break
      }
    }

    if let route = fixture.route {
      var previousDate: Date?
      for (index, point) in route.points.enumerated() {
        let path = "route.points[\(index)]"
        if !point.latitude.isFinite || !(-90...90).contains(point.latitude) {
          issues.append(
            .error(
              "route.invalidLatitude", "\(path).latitude", "Latitude must be between -90 and 90."))
        }
        if !point.longitude.isFinite || !(-180...180).contains(point.longitude) {
          issues.append(
            .error(
              "route.invalidLongitude", "\(path).longitude",
              "Longitude must be between -180 and 180."))
        }
        if let bounds, !bounds.contains(point.date) {
          issues.append(
            .error(
              "route.outOfBounds", "\(path).date", "Route point must be inside workout bounds."))
        }
        if let previousDate, point.date < previousDate {
          issues.append(.error("route.unordered", path, "Route points must be ordered by date."))
        }
        previousDate = point.date
      }
    }
    return issues
  }

  /// Validates `fixture` and throws when any error-severity issue is found; warnings alone
  /// pass.
  /// - Throws: ``FixtureValidationError`` carrying all issues, warnings included.
  public func requireValid(_ fixture: WorkoutFixture) throws {
    let issues = validate(fixture)
    guard !issues.contains(where: { $0.severity == .error }) else {
      throw FixtureValidationError(issues: issues)
    }
  }
}

extension ValidationIssue {
  fileprivate static func error(_ code: String, _ path: String, _ message: String) -> Self {
    Self(severity: .error, code: code, path: path, message: message)
  }

  fileprivate static func warning(_ code: String, _ path: String, _ message: String) -> Self {
    Self(severity: .warning, code: code, path: path, message: message)
  }
}
