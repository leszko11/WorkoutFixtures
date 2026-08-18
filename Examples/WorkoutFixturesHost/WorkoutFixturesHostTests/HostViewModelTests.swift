import Foundation
import Testing
import WorkoutFixtures
import WorkoutFixturesHealthKit
import WorkoutFixturesTestSupport

@testable import WorkoutFixturesDebugUI

private struct AuthorizingStub: HealthAuthorizing {
  func requestAuthorization(for access: HealthKitWorkoutAccess) async throws {}
}

private actor ArchiveBuilderGate {
  private var started = false
  private var continuation: CheckedContinuation<Void, Never>?

  var hasStarted: Bool { started }

  func suspend() async {
    await withCheckedContinuation { continuation in
      self.continuation = continuation
      started = true
    }
  }

  func release() {
    continuation?.resume()
    continuation = nil
  }
}

@MainActor
@Suite("Debug model")
struct DebugModelTests {
  private static func makeModel(
    fixtures: [WorkoutFixture] = [],
    sink: (any WorkoutFixtureSink & WorkoutFixtureDeleting)? = nil
  ) -> (model: WorkoutFixtureDebugModel, sink: RecordingWorkoutSink) {
    let recordingSink = RecordingWorkoutSink()
    let model = WorkoutFixtureDebugModel(
      source: InMemoryWorkoutSource(fixtures: fixtures),
      sink: sink ?? recordingSink,
      authorization: AuthorizingStub(),
      requestsAuthorization: false,
      loadsBundledFixtureOnLaunch: false
    )
    return (model, recordingSink)
  }

  @Test("Bundled fixture loads and validates")
  func bundledFixtureValidates() async throws {
    let (model, _) = Self.makeModel()
    model.loadBundledFixture()
    await model.awaitCurrentOperation()

    #expect(model.selectedFixture?.id.rawValue == "outdoor-run")
    #expect(model.validationErrorCount == 0)
    #expect(model.selectedSampleCount > 0)
  }

  @Test("Fixture file import decodes and validates")
  func fixtureFileImportValidates() async throws {
    let fixture = try WorkoutFixturePreset.pausedWalk.fixture()
    let fileURL = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString)
      .appendingPathExtension("json")
    defer { try? FileManager.default.removeItem(at: fileURL) }
    try FixtureJSONCodec().encode(fixture).write(to: fileURL)

    let (model, _) = Self.makeModel()
    model.importFixture(from: fileURL)
    await model.awaitCurrentOperation()

    #expect(model.selectedFixture == fixture)
    #expect(model.validationErrorCount == 0)
    guard case .success = model.phase else {
      Issue.record("Expected import to succeed, got \(model.phase)")
      return
    }
  }

  @Test("Gzipped fixture file import decodes and validates")
  func gzippedFixtureFileImportValidates() async throws {
    let fixture = try WorkoutFixturePreset.pausedWalk.fixture()
    let fileURL = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString)
      .appendingPathExtension("json.gz")
    defer { try? FileManager.default.removeItem(at: fileURL) }
    let json = try FixtureJSONCodec().encode(fixture, formatting: .compact)
    try GzipCodec.compress(json).write(to: fileURL)

    let (model, _) = Self.makeModel()
    model.importFixture(from: fileURL)
    await model.awaitCurrentOperation()

    #expect(model.selectedFixture == fixture)
    #expect(model.validationErrorCount == 0)
  }

  @Test("Malformed fixture file is rejected")
  func malformedFixtureFileIsRejected() async throws {
    let fileURL = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString)
      .appendingPathExtension("json")
    defer { try? FileManager.default.removeItem(at: fileURL) }
    try Data("not json".utf8).write(to: fileURL)

    let (model, _) = Self.makeModel()
    model.importFixture(from: fileURL)
    await model.awaitCurrentOperation()

    #expect(model.selectedFixture == nil)
    guard case .failure = model.phase else {
      Issue.record("Expected malformed fixture import to fail, got \(model.phase)")
      return
    }
  }

  @Test("Write path stores through the injected sink")
  func writePathUsesSink() async throws {
    let fixture = try WorkoutFixturePreset.outdoorRun.fixture()
    let (model, sink) = Self.makeModel(fixtures: [fixture])

    model.authorizeAndRefresh()
    await model.awaitCurrentOperation()
    #expect(model.summaries.count == 1)

    model.select(model.summaries[0])
    await model.awaitCurrentOperation()

    model.writeSelectedFixtureToHealthKit()
    await model.awaitCurrentOperation()

    #expect(await sink.storedFixtures == [fixture.applyingCaptureOptions(.peakmeLean)])
    #expect(model.lastStoredWorkout?.fixtureID == fixture.id)
  }

  @Test("Delete path removes the last stored workout via the sink")
  func deletePathUsesSink() async throws {
    let fixture = try WorkoutFixturePreset.outdoorRun.fixture()
    let (model, sink) = Self.makeModel(fixtures: [fixture])

    model.authorizeAndRefresh()
    await model.awaitCurrentOperation()
    model.select(model.summaries[0])
    await model.awaitCurrentOperation()
    model.writeSelectedFixtureToHealthKit()
    await model.awaitCurrentOperation()

    model.removeLastImport()
    await model.awaitCurrentOperation()

    #expect(await sink.deletedExternalIDs == [fixture.id.rawValue])
    #expect(model.lastStoredWorkout == nil)
  }

  @Test("Sink failures surface as failure phase")
  func sinkFailureSurfaces() async throws {
    let fixture = try WorkoutFixturePreset.outdoorRun.fixture()
    let sink = RecordingWorkoutSink()
    await sink.setStoreError(WorkoutFixtureSourceError.notFound("hk-down"))
    let (model, _) = Self.makeModel(fixtures: [fixture], sink: sink)

    model.authorizeAndRefresh()
    await model.awaitCurrentOperation()
    model.select(model.summaries[0])
    await model.awaitCurrentOperation()
    model.writeSelectedFixtureToHealthKit()
    await model.awaitCurrentOperation()

    guard case .failure = model.phase else {
      Issue.record("Expected sink failure to surface, got \(model.phase)")
      return
    }
    #expect(model.lastStoredWorkout == nil)
  }

  @Test("Shareable export produces a redacted, decodable document")
  func shareableExportIsRedacted() async throws {
    let (model, _) = Self.makeModel()
    model.loadBundledFixture()
    await model.awaitCurrentOperation()

    model.prepareShareableExport(seed: 42)
    await model.awaitCurrentOperation()

    let data = try #require(model.exportedDocument?.data)
    let redacted = try FixtureJSONCodec().decode(data)
    #expect(redacted.provenance.kind == .redacted)
    #expect(redacted.route == nil)
    #expect(redacted.provenance.seed == nil)
    #expect(model.exportFilename.hasSuffix("-shareable.json.gz"))
    #expect(model.isExporting)
  }

  @Test("Full export produces the exact selected fixture")
  func fullExportMatchesSelection() async throws {
    let (model, _) = Self.makeModel()
    model.loadBundledFixture()
    await model.awaitCurrentOperation()
    let selected = try #require(model.selectedFixture)

    model.prepareFullExport()
    await model.awaitCurrentOperation()

    let data = try #require(model.exportedDocument?.data)
    #expect(try FixtureJSONCodec().decode(data) == selected)
    #expect(model.exportFilename == "\(selected.id.rawValue).json.gz")
  }

  private static func invalidFixture(id: String) throws -> WorkoutFixture {
    let template = try WorkoutFixturePreset.outdoorRun.fixture()
    return WorkoutFixture(
      id: WorkoutID(rawValue: id),
      workout: WorkoutDescriptor(
        activity: template.workout.activity,
        location: template.workout.location,
        startDate: template.workout.startDate,
        endDate: template.workout.startDate.addingTimeInterval(-60),
        timeZoneIdentifier: template.workout.timeZoneIdentifier
      ),
      series: [],
      events: [],
      route: nil,
      provenance: template.provenance
    )
  }

  @Test("Archive export skips workouts that fail and exports the rest")
  func archiveExportSkipsFailedWorkouts() async throws {
    var fixtures = try WorkoutFixturePreset.allFixtures()
    fixtures.append(try Self.invalidFixture(id: "broken-workout"))
    let (model, _) = Self.makeModel(fixtures: fixtures)

    model.prepareFullArchiveExport()
    await model.awaitCurrentOperation()

    let data = try #require(model.exportedDocument?.data)
    let archive = try FixtureArchiveJSONCodec().decode(data)
    #expect(archive.fixtures.count == fixtures.count - 1)
    #expect(!archive.fixtures.contains { $0.id.rawValue == "broken-workout" })
    #expect(model.lastSkippedWorkouts.map(\.id) == [WorkoutID(rawValue: "broken-workout")])
    guard case .success(let message) = model.phase else {
      Issue.record("Expected a partial export to succeed, got \(model.phase)")
      return
    }
    #expect(message.contains("skipped 1"))
  }

  @Test("Archive export fails when every workout fails")
  func archiveExportFailsWhenEverythingFails() async throws {
    let fixtures = [
      try Self.invalidFixture(id: "broken-1"),
      try Self.invalidFixture(id: "broken-2"),
    ]
    let (model, _) = Self.makeModel(fixtures: fixtures)

    model.prepareFullArchiveExport()
    await model.awaitCurrentOperation()

    #expect(model.exportedDocument == nil)
    #expect(model.lastSkippedWorkouts.count == 2)
    guard case .failure = model.phase else {
      Issue.record("Expected an all-failed export to fail, got \(model.phase)")
      return
    }
  }

  @Test("Export filters narrow the listed and exported workouts")
  func exportFiltersNarrowResults() async throws {
    let fixtures = try WorkoutFixturePreset.allFixtures()
    let (model, _) = Self.makeModel(fixtures: fixtures)

    model.authorizeAndRefresh()
    await model.awaitCurrentOperation()
    #expect(model.filteredSummaries.count == fixtures.count)

    model.exportFilter.activities = [.running]
    #expect(model.filteredSummaries.allSatisfy { $0.activity == .running })
    #expect(model.filteredSummaries.count == 1)

    model.exportFilter.activities = []
    model.exportFilter.limit = 2
    #expect(model.filteredSummaries.count == 2)

    model.exportFilter.limit = nil
    model.exportFilter.minimumDurationMinutes = 100_000
    #expect(model.filteredSummaries.isEmpty)

    model.prepareFullArchiveExport()
    await model.awaitCurrentOperation()
    guard case .failure = model.phase else {
      Issue.record("Expected export with no matches to fail, got \(model.phase)")
      return
    }

    model.exportFilter.minimumDurationMinutes = nil
    model.exportFilter.activities = [.running]
    model.prepareFullArchiveExport()
    await model.awaitCurrentOperation()

    let data = try #require(model.exportedDocument?.data)
    let archive = try FixtureArchiveJSONCodec().decode(data)
    #expect(archive.fixtures.allSatisfy { $0.workout.activity == .running })
  }

  @Test("Route stripping removes GPS routes from the exported archive")
  func archiveExportStripsRoutes() async throws {
    let fixtures = try WorkoutFixturePreset.allFixtures()
    #expect(fixtures.contains { $0.route != nil })
    let (model, _) = Self.makeModel(fixtures: fixtures)

    model.exportFilter.includesRoutes = false
    model.prepareFullArchiveExport()
    await model.awaitCurrentOperation()

    let data = try #require(model.exportedDocument?.data)
    let archive = try FixtureArchiveJSONCodec().decode(data)
    #expect(archive.fixtures.count == fixtures.count)
    #expect(archive.fixtures.allSatisfy { $0.route == nil })
  }

  @Test("Full archive export captures every workout and route")
  func fullArchiveExportCapturesEveryWorkout() async throws {
    let fixtures = try WorkoutFixturePreset.allFixtures()
    let (model, _) = Self.makeModel(fixtures: fixtures)

    model.prepareFullArchiveExport()
    await model.awaitCurrentOperation()

    let data = try #require(model.exportedDocument?.data)
    let archive = try FixtureArchiveJSONCodec().decode(data)
    #expect(Set(archive.fixtures.map(\.id)) == Set(fixtures.map(\.id)))
    #expect(archive.fixtures.first(where: { $0.route != nil })?.route?.points.isEmpty == false)
    #expect(model.exportFilename == "workout-fixtures-archive.json.gz")
    #expect(model.isExporting)
    guard case .success = model.phase else {
      Issue.record("Expected archive export to succeed, got \(model.phase)")
      return
    }
  }

  @Test("Archive export reports encoding and compression after capture")
  func archiveExportReportsCompressionPhase() async throws {
    let fixtures = try WorkoutFixturePreset.allFixtures()
    let (model, _) = Self.makeModel(fixtures: fixtures)
    let gate = ArchiveBuilderGate()
    model.archiveDocumentBuilder = { fixtures in
      await gate.suspend()
      return try FixtureDocument(archive: WorkoutFixtureArchive(fixtures: fixtures))
    }

    model.prepareFullArchiveExport()
    while await !gate.hasStarted {
      await Task.yield()
    }

    #expect(model.phase == .working("Encoding and compressing \(fixtures.count) workouts…"))
    await gate.release()
    await model.awaitCurrentOperation()
    #expect(model.isExporting)
  }

  @Test("Archive export with no workouts is a failure, not an empty archive")
  func archiveExportRequiresWorkouts() async throws {
    let (model, _) = Self.makeModel(fixtures: [])
    model.prepareFullArchiveExport()
    await model.awaitCurrentOperation()

    #expect(model.exportedDocument == nil)
    guard case .failure = model.phase else {
      Issue.record("Expected empty archive export to fail, got \(model.phase)")
      return
    }
  }

  @Test("A second operation is ignored while one is in flight")
  func reentrancyGuardIgnoresSecondOperation() async throws {
    let fixtures = try WorkoutFixturePreset.allFixtures()
    let (model, _) = Self.makeModel(fixtures: fixtures)

    model.prepareFullArchiveExport()
    model.loadBundledFixture()
    await model.awaitCurrentOperation()

    // The archive export ran; the bundled-fixture load was dropped.
    #expect(model.exportFilename == "workout-fixtures-archive.json.gz")
    #expect(model.selectedFixture == nil)
  }

  @Test("Cancellation returns the phase to idle")
  func cancellationReturnsToIdle() async throws {
    let fixtures = try WorkoutFixturePreset.allFixtures()
    let (model, _) = Self.makeModel(fixtures: fixtures)

    model.prepareFullArchiveExport()
    model.cancelCurrentOperation()
    await model.awaitCurrentOperation()

    #expect(model.phase == .idle || model.exportedDocument != nil)
  }

  @Test("FixtureDocument round trips through a FileWrapper")
  func fixtureDocumentRoundTrips() throws {
    let fixture = try WorkoutFixturePreset.outdoorRun.fixture()
    let document = try FixtureDocument(fixture: fixture)
    let wrapper = FileWrapper(regularFileWithContents: document.data)

    let reloaded = try FixtureDocument(fileWrapper: wrapper)
    #expect(try FixtureJSONCodec().decode(reloaded.data) == fixture)
  }
}
