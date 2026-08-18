import Foundation

/// Deterministically reduces captured routes while preserving their useful shape and elevation.
public enum WorkoutRouteSimplifier {
  private static let horizontalAccuracyRange = 0.0...70.0
  private static let targetSampleCount = 40_000
  private static let minimumCadenceSeconds: TimeInterval = 3
  private static let altitudeBucketSeconds: TimeInterval = 180

  /// Filters inaccurate and duplicate points, keeps the endpoints, samples by cadence, and keeps
  /// the minimum and maximum altitude in each three-minute bucket.
  public static func adaptive(_ points: [RoutePoint]) -> [RoutePoint] {
    let validIndices = qualityFilteredIndices(points)
    guard !validIndices.isEmpty else { return [] }

    var kept: Set<Int> = [validIndices[0], validIndices[validIndices.count - 1]]
    keepCadencePoints(from: validIndices, points: points, kept: &kept)
    keepAltitudeExtrema(from: validIndices, points: points, kept: &kept)
    return kept.sorted().map { points[$0] }
  }

  private static func qualityFilteredIndices(_ points: [RoutePoint]) -> [Int] {
    var indices: [Int] = []
    indices.reserveCapacity(points.count)
    var previous: RoutePoint?

    for (index, point) in points.enumerated() {
      if let accuracy = point.horizontalAccuracy,
        !horizontalAccuracyRange.contains(accuracy)
      {
        continue
      }
      if let accuracy = point.verticalAccuracy, accuracy < 0 { continue }
      if let previous, point.isExactDuplicate(of: previous) { continue }
      indices.append(index)
      previous = point
    }
    return indices
  }

  private static func keepCadencePoints(
    from indices: [Int],
    points: [RoutePoint],
    kept: inout Set<Int>
  ) {
    guard let first = indices.first, let last = indices.last else { return }
    let duration = max(0, points[last].date.timeIntervalSince(points[first].date))
    let cadence = max(minimumCadenceSeconds, duration / Double(targetSampleCount))
    var previousDate: Date?

    for index in indices {
      let date = points[index].date
      if previousDate.map({ date.timeIntervalSince($0) >= cadence }) ?? true {
        kept.insert(index)
        previousDate = date
      }
    }
  }

  private static func keepAltitudeExtrema(
    from indices: [Int],
    points: [RoutePoint],
    kept: inout Set<Int>
  ) {
    guard let first = indices.first else { return }
    let firstDate = points[first].date
    var buckets: [Int: (minimum: Int, maximum: Int)] = [:]

    for index in indices {
      guard let altitude = points[index].altitude else { continue }
      let bucket = Int(
        floor(points[index].date.timeIntervalSince(firstDate) / altitudeBucketSeconds)
      )
      if let existing = buckets[bucket] {
        let minimumAltitude = points[existing.minimum].altitude ?? altitude
        let maximumAltitude = points[existing.maximum].altitude ?? altitude
        buckets[bucket] = (
          altitude < minimumAltitude ? index : existing.minimum,
          altitude > maximumAltitude ? index : existing.maximum
        )
      } else {
        buckets[bucket] = (index, index)
      }
    }

    for extrema in buckets.values {
      kept.insert(extrema.minimum)
      kept.insert(extrema.maximum)
    }
  }
}

extension RoutePoint {
  fileprivate func isExactDuplicate(of previous: RoutePoint) -> Bool {
    latitude == previous.latitude && longitude == previous.longitude
      && altitude == previous.altitude
  }
}
