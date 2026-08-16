import Foundation
import Testing
import WorkoutFixtures
import WorkoutFixturesTestSupport

@Suite("Fixture codec and validation")
struct CodecAndValidationTests {
  @Test("Bundled presets are valid", arguments: WorkoutFixturePreset.allCases)
  func bundledPresetIsValid(_ preset: WorkoutFixturePreset) throws {
    let fixture = try preset.fixture()
    #expect(WorkoutValidator().validate(fixture).contains { $0.severity == .error } == false)
  }

  @Test("Canonical JSON round trips", arguments: WorkoutFixturePreset.allCases)
  func canonicalRoundTrip(_ preset: WorkoutFixturePreset) throws {
    let codec = FixtureJSONCodec()
    let fixture = try preset.fixture()
    let encoded = try codec.encode(fixture)
    let decoded = try codec.decode(encoded)
    #expect(decoded == fixture)
    #expect(encoded.last == 0x0A)
  }

  @Test("Unknown fields are rejected")
  func unknownFieldIsRejected() throws {
    let fixture = try WorkoutFixturePreset.outdoorRun.fixture()
    let encoded = try FixtureJSONCodec().encode(fixture)
    var object = try #require(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    object["unexpected"] = true
    let data = try JSONSerialization.data(withJSONObject: object)

    #expect(throws: FixtureCodingError.unknownField(path: "unexpected")) {
      try FixtureJSONCodec().decode(data)
    }
    #expect(try FixtureJSONCodec().decode(data, unknownFields: .ignore) == fixture)
  }

  @Test("Future schema versions are rejected")
  func futureVersionIsRejected() throws {
    let fixture = try WorkoutFixturePreset.outdoorRun.fixture()
    let encoded = try FixtureJSONCodec().encode(fixture)
    var object = try #require(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    object["schemaVersion"] = 99
    let data = try JSONSerialization.data(withJSONObject: object)

    #expect(throws: FixtureCodingError.unsupportedSchemaVersion(.init(rawValue: 99))) {
      try FixtureJSONCodec().decode(data)
    }
  }

  @Test("JSON Schema is packaged")
  func schemaIsPackaged() throws {
    let data = try FixtureJSONCodec.schemaData
    let object = try #require(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    #expect(object["$schema"] as? String == "https://json-schema.org/draft/2020-12/schema")

    let archiveData = try FixtureArchiveJSONCodec.schemaData
    let archiveObject = try #require(
      JSONSerialization.jsonObject(with: archiveData) as? [String: Any]
    )
    #expect(archiveObject["title"] as? String == "Workout Fixture Archive")
  }

  @Test("Archive round trips every fixture and route")
  func archiveRoundTrip() throws {
    let fixtures = try WorkoutFixturePreset.allFixtures()
    let createdAt = try #require(
      ISO8601DateFormatter().date(from: "2026-08-12T08:00:00Z")
    )
    let archive = try WorkoutFixtureArchive(createdAt: createdAt, fixtures: fixtures)
    let codec = FixtureArchiveJSONCodec()

    let encoded = try codec.encode(archive)
    let decoded = try codec.decode(encoded)

    #expect(decoded == archive)
    #expect(decoded.fixtures.first(where: { $0.route != nil })?.route?.points.isEmpty == false)
    #expect(encoded.last == 0x0A)
  }

  @Test("Archive rejects duplicate workout IDs")
  func archiveRejectsDuplicateIDs() throws {
    let fixture = try WorkoutFixturePreset.outdoorRun.fixture()

    #expect(throws: FixtureArchiveCodingError.duplicateFixtureID(fixture.id)) {
      try WorkoutFixtureArchive(fixtures: [fixture, fixture])
    }
  }

  @Test("Archive rejects unknown nested fixture fields")
  func archiveRejectsUnknownNestedFields() throws {
    let archive = try WorkoutFixtureArchive(
      fixtures: [WorkoutFixturePreset.outdoorRun.fixture()]
    )
    let encoded = try FixtureArchiveJSONCodec().encode(archive)
    var object = try #require(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    var fixtures = try #require(object["fixtures"] as? [[String: Any]])
    fixtures[0]["unexpected"] = true
    object["fixtures"] = fixtures
    let data = try JSONSerialization.data(withJSONObject: object)

    #expect(
      throws: FixtureArchiveCodingError.unknownField(path: "fixtures[0].unexpected")
    ) {
      try FixtureArchiveJSONCodec().decode(data)
    }
  }

  @Test("Reversed or empty workout bounds are reported, not trapped", arguments: [-60.0, 0.0])
  func invalidBoundsProduceError(_ endOffset: Double) throws {
    let template = try WorkoutFixturePreset.outdoorRun.fixture()
    let fixture = WorkoutFixture(
      id: template.id,
      workout: WorkoutDescriptor(
        activity: template.workout.activity,
        location: template.workout.location,
        startDate: template.workout.startDate,
        endDate: template.workout.startDate.addingTimeInterval(endOffset),
        timeZoneIdentifier: template.workout.timeZoneIdentifier
      ),
      series: template.series,
      events: template.events,
      route: template.route,
      provenance: template.provenance
    )
    let issues = WorkoutValidator().validate(fixture)
    #expect(issues.contains { $0.code == "workout.invalidBounds" })
  }

  @Test("Validation reports incompatible units and out-of-bounds samples")
  func validationReportsStablePaths() throws {
    let template = try WorkoutFixturePreset.outdoorRun.fixture()
    let invalid = WorkoutFixture(
      id: template.id,
      workout: template.workout,
      series: [
        MetricSeries(
          metric: .heartRate,
          unit: .meter,
          samples: [
            MetricSample(
              startDate: template.workout.startDate.addingTimeInterval(-1),
              endDate: template.workout.startDate,
              value: 20
            )
          ]
        )
      ],
      provenance: template.provenance
    )
    let issues = WorkoutValidator().validate(invalid)
    #expect(issues.contains { $0.code == "series.incompatibleUnit" && $0.path == "series[0].unit" })
    #expect(issues.contains { $0.code == "sample.outOfBounds" })
    #expect(issues.contains { $0.code == "sample.unusualHeartRate" && $0.severity == .warning })
  }
}

@Test("Public concurrency values are Sendable")
func publicTypesAreSendable() {
  assertSendable(WorkoutFixture.self)
  assertSendable(WorkoutQuery.self)
  assertSendable(GenerationRecipe.self)
  assertSendable(TemplateWorkoutGenerator.self)
  assertSendable(InMemoryWorkoutSource.self)
  assertSendable(JSONWorkoutSource.self)
  assertSendable(WorkoutFixtureArchive.self)
  assertSendable(FixtureArchiveJSONCodec.self)
}
