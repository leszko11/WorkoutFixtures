import Foundation

/// Optional route reduction applied after HealthKit returns the original points.
public enum RouteSimplificationPolicy: Equatable, Sendable {
  /// Preserve every valid captured route point.
  case none
  /// Filter inaccurate and duplicate points, retain a minimum three-second cadence, and preserve
  /// altitude extrema in three-minute buckets.
  case adaptive
}

/// Selects which expensive workout components a source should capture.
///
/// Source implementations should avoid starting work for disabled components. The optionless
/// ``WorkoutFixtureSource`` methods remain full-fidelity for compatibility.
public struct WorkoutFixtureCaptureOptions: Equatable, Sendable {
  public var includedMetrics: Set<MetricIdentifier>
  public var includesRoutes: Bool
  public var routeSimplification: RouteSimplificationPolicy

  public init(
    includedMetrics: Set<MetricIdentifier> = Set(MetricIdentifier.allCases),
    includesRoutes: Bool = true,
    routeSimplification: RouteSimplificationPolicy = .none
  ) {
    self.includedMetrics = includedMetrics
    self.includesRoutes = includesRoutes
    self.routeSimplification = routeSimplification
  }

  /// Full-fidelity capture matching the behavior of optionless source calls.
  public static let full = WorkoutFixtureCaptureOptions()

  /// Full-fidelity dump of HealthKit workouts: every metric series and an unsimplified route.
  public static let fullDump = WorkoutFixtureCaptureOptions.full

  /// Compact defaults for UI-test fixtures: distance plus a reduced route.
  public static let lean = WorkoutFixtureCaptureOptions(
    includedMetrics: [.distance],
    includesRoutes: true,
    routeSimplification: .adaptive
  )

  /// - Important: Renamed to ``lean``. Prefer ``lean`` or ``fullDump``.
  @available(*, deprecated, renamed: "lean")
  public static let peakmeLean = lean
}

extension WorkoutFixture {
  /// Returns a copy containing only the selected metrics and route representation.
  public func applyingCaptureOptions(
    _ options: WorkoutFixtureCaptureOptions
  ) -> WorkoutFixture {
    let selectedSeries = series.filter { options.includedMetrics.contains($0.metric) }
    let selectedRoute: WorkoutRoute?
    if !options.includesRoutes {
      selectedRoute = nil
    } else if let route {
      switch options.routeSimplification {
      case .none:
        selectedRoute = route
      case .adaptive:
        selectedRoute = WorkoutRoute(points: WorkoutRouteSimplifier.adaptive(route.points))
      }
    } else {
      selectedRoute = nil
    }

    // Keep climb when the route is dropped: prefer stored elevation, else derive from the
    // original route before stripping.
    let preservedElevation =
      elevation
      ?? (selectedRoute == nil
        ? WorkoutElevation(
          ascentMeters: route?.ascentMeters,
          descentMeters: route?.descentMeters
        )
        : nil)

    return WorkoutFixture(
      schemaVersion: schemaVersion,
      id: id,
      workout: workout,
      series: selectedSeries,
      events: events,
      route: selectedRoute,
      elevation: preservedElevation,
      provenance: provenance
    )
  }
}
