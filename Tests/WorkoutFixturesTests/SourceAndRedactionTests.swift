import Foundation
import Testing
import WorkoutFixtures
import WorkoutFixturesTestSupport

@Suite("Sources and privacy")
struct SourceAndRedactionTests {
  @Test("Source filters, sorts, and limits")
  func sourceQuery() async throws {
    let fixtures = try WorkoutFixturePreset.allFixtures()
    let source = InMemoryWorkoutSource(fixtures: fixtures)
    let summaries = try await source.summaries(
      matching: WorkoutQuery(
        activities: [.running, .walking],
        sort: .startDateAscending,
        limit: 1
      ))
    let only = try #require(summaries.first)
    #expect(summaries.count == 1)
    #expect(only.activity == .running)
  }

  @Test("Missing IDs produce a typed error")
  func missingID() async throws {
    let source = InMemoryWorkoutSource(fixtures: [])
    await #expect(throws: WorkoutFixtureSourceError.notFound("missing")) {
      try await source.fixture(for: "missing")
    }
  }

  @Test("Concurrent reads have no shared mutable state")
  func concurrentReads() async throws {
    let fixtures = try WorkoutFixturePreset.allFixtures()
    let source = InMemoryWorkoutSource(fixtures: fixtures)
    let results = try await withThrowingTaskGroup(of: WorkoutFixture.self) { group in
      for fixture in fixtures {
        group.addTask { try await source.fixture(for: fixture.id) }
      }
      var values: [WorkoutFixture] = []
      for try await value in group { values.append(value) }
      return values
    }
    #expect(Set(results.map(\.id)) == Set(fixtures.map(\.id)))
  }

  @Test("JSON source loads a multi-workout archive")
  func archiveSource() async throws {
    let fixtures = try WorkoutFixturePreset.allFixtures()
    let archive = try WorkoutFixtureArchive(fixtures: fixtures)
    let source = try JSONWorkoutSource(data: FixtureArchiveJSONCodec().encode(archive))

    let summaries = try await source.summaries(matching: WorkoutQuery())
    let routedID = try #require(fixtures.first(where: { $0.route != nil })?.id)
    let routedFixture = try await source.fixture(for: routedID)

    #expect(Set(summaries.map(\.id)) == Set(fixtures.map(\.id)))
    #expect(routedFixture.route?.points.isEmpty == false)
  }

  @Test("Sharing redaction is deterministic and removes identifying data")
  func sharingRedaction() throws {
    let captured = try WorkoutFixturePreset.outdoorRun.fixture()
    let first = try WorkoutRedactor().redact(captured, seed: 123)
    let second = try WorkoutRedactor().redact(captured, seed: 123)
    #expect(first == second)
    #expect(first.id != captured.id)
    #expect(first.workout.startDate != captured.workout.startDate)
    #expect(first.route == nil)
    #expect(first.provenance.source == nil)
    #expect(first.provenance.sourceFixtureID == nil)
    #expect(WorkoutValidator().validate(first).contains { $0.severity == .error } == false)
  }

  @Test(
    "Redaction policies preserve exactly what they promise",
    arguments: [
      (preserveRoute: false, preserveSource: false),
      (preserveRoute: false, preserveSource: true),
      (preserveRoute: true, preserveSource: false),
      (preserveRoute: true, preserveSource: true),
    ])
  func redactionPolicyCombinations(_ combo: (preserveRoute: Bool, preserveSource: Bool)) throws {
    let preset = try WorkoutFixturePreset.outdoorRun.fixture()
    let captured = WorkoutFixture(
      id: preset.id,
      workout: preset.workout,
      series: preset.series,
      events: preset.events,
      route: preset.route,
      provenance: FixtureProvenance(
        kind: .captured,
        createdAt: preset.provenance.createdAt,
        sourceFixtureID: nil,
        generatorVersion: nil,
        seed: nil,
        source: SourceProvenance(
          name: "Test App",
          bundleIdentifier: "dev.workoutfixtures.tests",
          version: "1.0",
          deviceModel: "iPhone"
        )
      )
    )
    #expect(captured.route != nil)
    #expect(captured.provenance.source != nil)

    let policy = RedactionPolicy(
      regenerateID: true,
      removeRoute: !combo.preserveRoute,
      removeSourceMetadata: !combo.preserveSource,
      shiftDates: true
    )
    let redacted = try WorkoutRedactor().redact(captured, using: policy, seed: 7)

    #expect((redacted.route != nil) == combo.preserveRoute)
    #expect((redacted.provenance.source != nil) == combo.preserveSource)
    if combo.preserveRoute {
      #expect(redacted.route?.points.count == captured.route?.points.count)
    }
    if combo.preserveSource {
      #expect(redacted.provenance.source == captured.provenance.source)
    }
    #expect(redacted.id != captured.id)
    #expect(redacted.workout.startDate != captured.workout.startDate)
    #expect(WorkoutValidator().validate(redacted).contains { $0.severity == .error } == false)
  }

  @Test("Redacted output does not reveal the seed that shifted its dates")
  func redactionDoesNotLeakSeed() throws {
    let captured = try WorkoutFixturePreset.outdoorRun.fixture()
    let seed: UInt64 = 0xDEAD_BEEF_1234_5678
    let redacted = try WorkoutRedactor().redact(captured, seed: seed)

    #expect(redacted.provenance.seed == nil)

    let json = try #require(
      String(data: FixtureJSONCodec().encode(redacted), encoding: .utf8)
    )
    #expect(!json.contains(String(seed)))
    #expect(!json.lowercased().contains(String(seed, radix: 16)))
  }

  @Test("Bundle source loads a fixture")
  func bundleSource() async throws {
    let source = try BundleWorkoutSource(resource: "outdoor-run", subdirectory: "Fixtures")
    let fixture = try await source.fixture(for: "outdoor-run")
    #expect(fixture.workout.activity == .running)
  }
}
