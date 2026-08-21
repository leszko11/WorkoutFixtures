import Foundation
import Testing

@testable import WorkoutFixtures

@Suite("Route elevation")
struct RouteElevationTests {
  private let start = Date(timeIntervalSince1970: 1_700_000_000)

  @Test("Ascent sums only the climbs")
  func ascentSumsOnlyClimbs() throws {
    let route = WorkoutRoute(points: [
      point(0, altitude: 100),
      point(60, altitude: 140),
      point(120, altitude: 110),
      point(180, altitude: 160),
    ])

    #expect(route.ascentMeters == 90)
    #expect(route.descentMeters == 30)
  }

  @Test("A flat route reports no climb")
  func flatRouteReportsNoClimb() {
    let route = WorkoutRoute(points: [
      point(0, altitude: 100),
      point(60, altitude: 100),
    ])

    #expect(route.ascentMeters == 0)
    #expect(route.descentMeters == 0)
  }

  @Test("Routes without usable altitudes report nothing rather than zero")
  func missingAltitudesReportNothing() {
    let withoutAltitude = WorkoutRoute(points: [
      point(0, altitude: nil),
      point(60, altitude: nil),
    ])
    let singlePoint = WorkoutRoute(points: [point(0, altitude: 100)])

    #expect(withoutAltitude.ascentMeters == nil)
    #expect(withoutAltitude.descentMeters == nil)
    #expect(singlePoint.ascentMeters == nil)
  }

  @Test("Adaptive simplification preserves the climb it thins")
  func simplificationPreservesClimb() {
    let points = (0..<40).map { index in
      point(Double(index) * 30, altitude: 100 + Double(index) * 5)
    }
    let route = WorkoutRoute(points: points)
    let simplified = WorkoutRoute(points: WorkoutRouteSimplifier.adaptive(points))

    #expect(route.ascentMeters == 195)
    #expect(simplified.ascentMeters == route.ascentMeters)
  }

  @Test("Summary prefers stored elevation over route-derived climb")
  func summaryPrefersStoredElevation() {
    let route = WorkoutRoute(points: [
      point(0, altitude: 100),
      point(60, altitude: 140),
    ])
    let fixture = WorkoutFixture(
      id: "elev",
      workout: WorkoutDescriptor(
        activity: .hiking,
        location: .outdoor,
        startDate: start,
        endDate: start.addingTimeInterval(60),
        timeZoneIdentifier: "UTC"
      ),
      series: [],
      route: route,
      elevation: WorkoutElevation(ascentMeters: 250, descentMeters: 10),
      provenance: FixtureProvenance(kind: .authored, createdAt: start)
    )

    #expect(route.ascentMeters == 40)
    #expect(fixture.summary.ascentMeters == 250)
    #expect(fixture.summary.descentMeters == 10)
  }

  @Test("Stripping the route preserves stored or derived elevation")
  func strippingRoutePreservesElevation() {
    let route = WorkoutRoute(points: [
      point(0, altitude: 100),
      point(60, altitude: 150),
    ])
    let fixture = WorkoutFixture(
      id: "elev-strip",
      workout: WorkoutDescriptor(
        activity: .hiking,
        location: .outdoor,
        startDate: start,
        endDate: start.addingTimeInterval(60),
        timeZoneIdentifier: "UTC"
      ),
      series: [],
      route: route,
      provenance: FixtureProvenance(kind: .authored, createdAt: start)
    )

    let stripped = fixture.applyingCaptureOptions(
      WorkoutFixtureCaptureOptions(includesRoutes: false)
    )
    #expect(stripped.route == nil)
    #expect(stripped.elevation?.ascentMeters == 50)
    #expect(stripped.summary.ascentMeters == 50)
  }

  private func point(_ seconds: TimeInterval, altitude: Double?) -> RoutePoint {
    RoutePoint(
      date: start.addingTimeInterval(seconds),
      latitude: 50 + seconds / 1_000,
      longitude: 20 + seconds / 1_000,
      altitude: altitude,
      horizontalAccuracy: 5,
      verticalAccuracy: 5
    )
  }
}
