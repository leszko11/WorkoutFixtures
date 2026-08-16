import Foundation
import HealthKit
import Testing
import WorkoutFixtures
import WorkoutFixturesHealthKit
import WorkoutFixturesTestSupport

extension Tag {
  @Tag static var healthKitIntegration: Self
}

@Suite(
  "HealthKit round trip",
  .serialized,
  .tags(.healthKitIntegration),
  .enabled(if: ProcessInfo.processInfo.environment["WORKOUT_FIXTURES_HEALTHKIT_INTEGRATION"] == "1")
)
struct HealthKitIntegrationTests {
  @Test("Fixture writes, reads, and cleans up")
  func roundTrip() async throws {
    let healthStore = HKHealthStore()
    let authorization = HealthKitAuthorizationController(healthStore: healthStore)
    try await authorization.requestAuthorization(for: .readWrite)

    let fixture = try WorkoutFixturePreset.outdoorRun.fixture()
    let sink = HealthKitWorkoutSink(healthStore: healthStore)
    let stored = try await sink.store(fixture)
    let externalID = try #require(stored.externalID)
    do {
      let source = HealthKitWorkoutSource(healthStore: healthStore)
      let captured = try await source.fixture(for: WorkoutID(rawValue: externalID))
      #expect(captured.workout.activity == fixture.workout.activity)
      #expect(captured.workout.startDate == fixture.workout.startDate)
      #expect(captured.workout.endDate == fixture.workout.endDate)
      #expect(abs((captured.total(for: .distance) ?? 0) - (fixture.total(for: .distance) ?? 0)) < 1)
      #expect(captured.route?.points.count == fixture.route?.points.count)
      try await sink.delete(externalID: externalID)
    } catch {
      try? await sink.delete(externalID: externalID)
      throw error
    }
  }
}
