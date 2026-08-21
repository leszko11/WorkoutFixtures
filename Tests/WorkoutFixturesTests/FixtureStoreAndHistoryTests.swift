import Foundation
import Testing
import WorkoutFixtures
import WorkoutFixturesTestSupport

@Suite("FixtureWorkoutStore")
struct FixtureWorkoutStoreTests {
  @Test("Validating store rejects invalid fixtures on enable")
  func validateOnEnable() throws {
    let template = try WorkoutFixturePreset.outdoorRun.fixture()
    let invalid = WorkoutFixture(
      id: template.id,
      workout: WorkoutDescriptor(
        activity: template.workout.activity,
        location: template.workout.location,
        startDate: template.workout.startDate,
        endDate: template.workout.startDate.addingTimeInterval(-60),
        timeZoneIdentifier: template.workout.timeZoneIdentifier
      ),
      series: [],
      provenance: template.provenance
    )

    #expect(throws: FixtureWorkoutStoreError.self) {
      try FixtureWorkoutStore(fixtures: [invalid], validate: true)
    }
  }

  @Test("Store round-trips fixtures after validation")
  func roundTrip() async throws {
    let fixture = try WorkoutFixturePreset.outdoorRun.fixture()
    let store = try FixtureWorkoutStore(fixtures: [fixture], validate: true)
    #expect(try await store.fixture(for: fixture.id) == fixture)
    #expect(try await store.summaries(matching: WorkoutQuery()).count == 1)
  }
}

@Suite("Workout history export")
struct WorkoutHistoryExportTests {
  @Test("Summarize emits ascent and preserves schema version")
  func summarizeEmitsAscent() throws {
    let fixture = try WorkoutFixturePreset.outdoorRun.fixture()
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    let document = try WorkoutHistoryExporter.summarize(
      fixtures: [fixture],
      shiftWeeks: 0,
      createdAt: createdAt
    )

    #expect(document.schemaVersion == WorkoutHistoryDocument.currentSchemaVersion)
    #expect(document.workouts.count == 1)
    #expect(document.workouts[0].ascentMeters == fixture.summary.ascentMeters)
    #expect(document.workouts[0].averageHeartRate == fixture.summary.averageHeartRate)

    let roundTripped = try WorkoutHistoryDocument.decode(try document.encode())
    #expect(roundTripped == document)
  }

  @Test("Merge firstWins keeps the earlier fixture")
  func mergeFirstWins() throws {
    let first = try WorkoutFixturePreset.outdoorRun.fixture()
    let second = WorkoutFixture(
      id: first.id,
      workout: first.workout,
      series: [],
      provenance: first.provenance
    )
    let merged = try FixtureMerger.merge([[first], [second]], policy: .firstWins)
    #expect(merged == [first])
  }

  @Test("Merge rejectDuplicates throws")
  func mergeRejectDuplicates() throws {
    let fixture = try WorkoutFixturePreset.outdoorRun.fixture()
    #expect(throws: FixtureMergeError.duplicateID(fixture.id)) {
      try FixtureMerger.merge([[fixture], [fixture]], policy: .rejectDuplicates)
    }
  }

  @Test("Whole-week shift preserves weekday")
  func weekShiftPreservesWeekday() throws {
    let fixture = try WorkoutFixturePreset.outdoorRun.fixture()
    let shifted = try WorkoutHistoryExporter.summarize(
      fixtures: [fixture],
      shiftWeeks: 2,
      createdAt: Date(timeIntervalSince1970: 0)
    )
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: fixture.workout.timeZoneIdentifier)!
    let originalWeekday = calendar.component(.weekday, from: fixture.workout.startDate)
    let shiftedWeekday = calendar.component(.weekday, from: shifted.workouts[0].startDate)
    #expect(shiftedWeekday == originalWeekday)
    #expect(
      shifted.workouts[0].startDate.timeIntervalSince(fixture.workout.startDate)
        == TimeInterval(14 * 24 * 60 * 60)
    )
  }
}
