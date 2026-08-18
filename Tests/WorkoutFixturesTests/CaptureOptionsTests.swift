import Foundation
import Testing
import WorkoutFixturesTestSupport

@testable import WorkoutFixtures

private struct LegacyFixtureSource: WorkoutFixtureSource {
  let fixtureValue: WorkoutFixture

  func summaries(matching query: WorkoutQuery) async throws -> [WorkoutSummary] {
    [fixtureValue.summary]
  }

  func fixture(for id: WorkoutID) async throws -> WorkoutFixture {
    fixtureValue
  }
}

@Suite("Capture options")
struct CaptureOptionsTests {
  @Test("Optionless sources remain full fidelity and selective calls filter components")
  func protocolDefaultsPreserveCompatibility() async throws {
    let fixture = try WorkoutFixturePreset.outdoorRun.fixture()
    let source = InMemoryWorkoutSource(fixtures: [fixture])

    #expect(try await source.fixture(for: fixture.id) == fixture)

    let selected = try await source.fixture(
      for: fixture.id,
      captureOptions: WorkoutFixtureCaptureOptions(
        includedMetrics: [.distance],
        includesRoutes: false
      )
    )
    #expect(selected.series.map(\.metric) == [.distance])
    #expect(selected.route == nil)
  }

  @Test("Legacy custom sources gain selective calls through protocol defaults")
  func legacyConformerRemainsSourceCompatible() async throws {
    let fixture = try WorkoutFixturePreset.outdoorRun.fixture()
    let source = LegacyFixtureSource(fixtureValue: fixture)
    let selected = try await source.fixture(
      for: fixture.id,
      captureOptions: WorkoutFixtureCaptureOptions(
        includedMetrics: [.heartRate],
        includesRoutes: false
      )
    )

    #expect(selected.series.map(\.metric) == [.heartRate])
    #expect(selected.route == nil)
  }

  @Test("Peakme defaults capture distance and an adaptive route")
  func peakmeDefaultsAreLean() {
    #expect(WorkoutFixtureCaptureOptions.peakmeLean.includedMetrics == [.distance])
    #expect(WorkoutFixtureCaptureOptions.peakmeLean.includesRoutes)
    #expect(WorkoutFixtureCaptureOptions.peakmeLean.routeSimplification == .adaptive)
  }
}

@Suite("Adaptive route simplification")
struct RouteSimplificationTests {
  private let start = Date(timeIntervalSinceReferenceDate: 10_000)

  @Test("Empty and already sparse routes remain stable")
  func sparseRoutesRemainStable() {
    #expect(WorkoutRouteSimplifier.adaptive([]).isEmpty)
    let points = [point(0, altitude: 1), point(3, altitude: 2), point(6, altitude: 3)]
    #expect(WorkoutRouteSimplifier.adaptive(points) == points)
  }

  @Test("Invalid accuracy and exact duplicates are removed while missing accuracy is accepted")
  func qualityFiltering() {
    let missingAccuracy = point(
      0,
      altitude: 1,
      horizontalAccuracy: nil,
      verticalAccuracy: nil
    )
    let duplicate = point(
      1,
      altitude: 1,
      horizontalAccuracy: nil,
      verticalAccuracy: nil
    )
    let invalidHorizontal = point(2, altitude: 2, horizontalAccuracy: -1)
    let invalidVertical = point(2.5, altitude: 2, verticalAccuracy: -1)
    let end = point(3, altitude: 3, horizontalAccuracy: 10)

    #expect(
      WorkoutRouteSimplifier.adaptive([
        missingAccuracy, duplicate, invalidHorizontal, invalidVertical, end,
      ])
        == [missingAccuracy, end]
    )
  }

  @Test("Cadence keeps endpoints and altitude extrema")
  func cadenceAndAltitudeExtrema() {
    let points = [
      point(0, altitude: 10),
      point(1, altitude: 50),
      point(2, altitude: 20),
      point(3, altitude: 30),
    ]

    let simplified = WorkoutRouteSimplifier.adaptive(points)
    #expect(simplified == [points[0], points[1], points[3]])
    #expect(WorkoutRouteSimplifier.adaptive(points) == simplified)
  }

  private func point(
    _ seconds: TimeInterval,
    altitude: Double,
    horizontalAccuracy: Double? = 5,
    verticalAccuracy: Double? = 5
  ) -> RoutePoint {
    RoutePoint(
      date: start.addingTimeInterval(seconds),
      latitude: 50 + seconds / 1_000,
      longitude: 20 + seconds / 1_000,
      altitude: altitude,
      horizontalAccuracy: horizontalAccuracy,
      verticalAccuracy: verticalAccuracy
    )
  }
}

@Suite("Compact JSON formatting")
struct CompactJSONFormattingTests {
  @Test("Compact and canonical JSON decode to the same fixture")
  func compactRoundTrip() throws {
    let fixture = try WorkoutFixturePreset.outdoorRun.fixture()
    let canonical = try FixtureJSONCodec().encode(fixture)
    let compact = try FixtureJSONCodec().encode(fixture, formatting: .compact)

    #expect(compact.count < canonical.count)
    #expect(try FixtureJSONCodec().decode(compact) == fixture)

    let archive = try WorkoutFixtureArchive(
      createdAt: fixture.workout.startDate, fixtures: [fixture])
    let compactArchive = try FixtureArchiveJSONCodec().encode(archive, formatting: .compact)
    #expect(try FixtureArchiveJSONCodec().decode(compactArchive) == archive)
  }
}
