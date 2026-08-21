#if canImport(SwiftUI) && canImport(HealthKit) && !os(watchOS)
  import Foundation
  import WorkoutFixtures

  /// User-editable criteria for which workouts the debug panel lists and exports.
  ///
  /// Activities and the date window are pushed into the HealthKit query; the
  /// distance, duration, and limit criteria are applied to the returned
  /// summaries. ``captureOptions`` controls which expensive HealthKit components are queried.
  public struct WorkoutExportFilter: Equatable, Sendable {
    public enum DateWindow: String, CaseIterable, Equatable, Sendable {
      case allTime
      case last30Days
      case last90Days
      case lastYear

      var displayName: String {
        switch self {
        case .allTime: "All time"
        case .last30Days: "Last 30 days"
        case .last90Days: "Last 90 days"
        case .lastYear: "Last year"
        }
      }

      func startDate(before now: Date) -> Date? {
        let days: Int? =
          switch self {
          case .allTime: nil
          case .last30Days: 30
          case .last90Days: 90
          case .lastYear: 365
          }
        return days.map { now.addingTimeInterval(-Double($0) * 86_400) }
      }
    }

    /// Activities to include; an empty set includes every supported activity.
    public var activities: Set<WorkoutActivity> = []
    public var dateWindow: DateWindow = .allTime
    /// Excludes workouts shorter than this distance; `nil` disables the filter.
    public var minimumDistanceKilometers: Double?
    /// Excludes workouts shorter than this duration; `nil` disables the filter.
    public var minimumDurationMinutes: Double?
    /// Components captured for both individual and archive exports.
    public var captureOptions = WorkoutFixtureCaptureOptions.fullDump
    /// Caps how many (filtered, newest-first) workouts are listed and exported.
    public var limit: Int?

    public init() {}

    public subscript(captures metric: MetricIdentifier) -> Bool {
      get { captureOptions.includedMetrics.contains(metric) }
      set {
        if newValue {
          captureOptions.includedMetrics.insert(metric)
        } else {
          captureOptions.includedMetrics.remove(metric)
        }
      }
    }

    public var includesRoutes: Bool {
      get { captureOptions.includesRoutes }
      set { captureOptions.includesRoutes = newValue }
    }

    public var simplifiesRoutes: Bool {
      get { captureOptions.routeSimplification == .adaptive }
      set { captureOptions.routeSimplification = newValue ? .adaptive : .none }
    }

    /// The portion of the filter that can be pushed into the workout query.
    /// The limit is deliberately not pushed down: it must apply after the
    /// distance/duration post-filters or matching workouts would be lost.
    func query(now: Date = Date()) -> WorkoutQuery {
      WorkoutQuery(
        activities: activities,
        startDate: dateWindow.startDate(before: now),
        sort: .startDateDescending
      )
    }

    // Also re-checks the criteria the query already pushed down (activities,
    // date window) so an edited filter reshapes already-loaded summaries
    // immediately, without waiting for the next refresh.
    func matches(_ summary: WorkoutSummary, now: Date = Date()) -> Bool {
      if !activities.isEmpty, !activities.contains(summary.activity) {
        return false
      }
      if let windowStart = dateWindow.startDate(before: now), summary.endDate < windowStart {
        return false
      }
      if let minimumDistanceKilometers,
        (summary.distanceMeters ?? 0) < minimumDistanceKilometers * 1_000
      {
        return false
      }
      if let minimumDurationMinutes,
        summary.elapsedDuration < minimumDurationMinutes * 60
      {
        return false
      }
      return true
    }

    func apply(to summaries: [WorkoutSummary], now: Date = Date()) -> [WorkoutSummary] {
      let matching = summaries.filter { matches($0, now: now) }
      guard let limit else { return matching }
      return Array(matching.prefix(max(0, limit)))
    }
  }

#endif
