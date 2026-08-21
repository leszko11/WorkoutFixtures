import Foundation
import Testing
import WorkoutFixtures
import WorkoutFixturesTestSupport

@Suite("Test doubles")
struct TestDoublesTests {
  @Test(
    "InMemoryWorkoutStore answers queries exactly like InMemoryWorkoutSource",
    arguments: [
      WorkoutQuery(),
      WorkoutQuery(activities: [.running]),
      WorkoutQuery(activities: [.running, .walking], sort: .startDateAscending),
      WorkoutQuery(sort: .startDateAscending, limit: 1),
      WorkoutQuery(limit: 0),
    ])
  func storeMatchesSource(_ query: WorkoutQuery) async throws {
    let fixtures = try WorkoutFixturePreset.allFixtures()
    let source = InMemoryWorkoutSource(fixtures: fixtures)
    let store = InMemoryWorkoutStore.unchecked(fixtures: fixtures)

    let fromSource = try await source.summaries(matching: query)
    let fromStore = try await store.summaries(matching: query)
    #expect(fromSource == fromStore)
  }

  @Test("InMemoryWorkoutStore round trips store and delete")
  func storeRoundTrip() async throws {
    let store = InMemoryWorkoutStore.unchecked()
    let fixture = try WorkoutFixturePreset.outdoorRun.fixture()

    let stored = try await store.store(fixture)
    #expect(stored.externalID == fixture.id.rawValue)
    #expect(try await store.fixture(for: fixture.id) == fixture)

    try await store.delete(externalID: fixture.id.rawValue)
    await #expect(throws: WorkoutFixtureSourceError.notFound(fixture.id)) {
      try await store.fixture(for: fixture.id)
    }
    await #expect(throws: WorkoutFixtureSourceError.notFound(fixture.id)) {
      try await store.delete(externalID: fixture.id.rawValue)
    }
  }

  @Test("RecordingWorkoutSink records stores and deletes")
  func recordingSinkRecords() async throws {
    let sink = RecordingWorkoutSink()
    let fixture = try WorkoutFixturePreset.outdoorRun.fixture()

    let stored = try await sink.store(fixture)
    try await sink.delete(externalID: "external-1")

    #expect(stored.externalID == fixture.id.rawValue)
    #expect(await sink.storedFixtures == [fixture])
    #expect(await sink.deletedExternalIDs == ["external-1"])
  }

  @Test("RecordingWorkoutSink injects failures")
  func recordingSinkInjectsFailures() async throws {
    let sink = RecordingWorkoutSink()
    await sink.setStoreError(WorkoutFixtureSourceError.notFound("boom"))

    await #expect(throws: WorkoutFixtureSourceError.notFound("boom")) {
      try await sink.store(try WorkoutFixturePreset.outdoorRun.fixture())
    }
    #expect(await sink.storedFixtures.isEmpty)
  }

  @Test("FailingWorkoutSource throws its configured error")
  func failingSourceThrows() async {
    let source = FailingWorkoutSource(error: WorkoutFixtureSourceError.notFound("offline"))
    await #expect(throws: WorkoutFixtureSourceError.notFound("offline")) {
      _ = try await source.summaries(matching: WorkoutQuery())
    }
    await #expect(throws: WorkoutFixtureSourceError.notFound("offline")) {
      _ = try await source.fixture(for: "anything")
    }
  }

  @Test("Doubles satisfy Sendable boundaries")
  func doublesAreSendable() {
    assertSendable(RecordingWorkoutSink.self)
    assertSendable(FailingWorkoutSource.self)
    assertSendable(InMemoryWorkoutStore.self)
  }
}
