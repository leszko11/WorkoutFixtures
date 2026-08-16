import Foundation
import Testing
import WorkoutFixtures
import WorkoutFixturesHealthKit
import WorkoutFixturesTestSupport

@testable import WorkoutFixturesDebugUI

private struct AuthorizingStub: HealthAuthorizing {
  func requestAuthorization(for access: HealthKitWorkoutAccess) async throws {}
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

    #expect(await sink.storedFixtures == [fixture])
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
    #expect(model.exportFilename.hasSuffix("-shareable"))
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
    #expect(model.exportFilename == selected.id.rawValue)
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
    #expect(model.exportFilename == "workout-fixtures-archive")
    #expect(model.isExporting)
    guard case .success = model.phase else {
      Issue.record("Expected archive export to succeed, got \(model.phase)")
      return
    }
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
    #expect(model.exportFilename == "workout-fixtures-archive")
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
