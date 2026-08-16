import Foundation
import Testing
import WorkoutFixtures
import WorkoutFixturesTestSupport

@testable import WorkoutFixturesHost

@MainActor
@Test("Bundled fixture validates")
func bundledFixtureValidates() {
  let model = HostViewModel()
  model.loadBundledFixture()
  #expect(model.selectedFixture?.id.rawValue == "outdoor-run")
  #expect(model.validationIssues.contains { $0.severity == .error } == false)
}

@MainActor
@Test("Fixture file import decodes and validates")
func fixtureFileImportValidates() throws {
  let fixture = try WorkoutFixturePreset.pausedWalk.fixture()
  let fileURL = FileManager.default.temporaryDirectory
    .appending(path: UUID().uuidString)
    .appendingPathExtension("json")
  defer { try? FileManager.default.removeItem(at: fileURL) }
  try FixtureJSONCodec().encode(fixture).write(to: fileURL)

  let model = HostViewModel()
  model.importFixture(from: fileURL)

  #expect(model.selectedFixture == fixture)
  #expect(model.validationIssues.contains { $0.severity == .error } == false)
  #expect(model.phase == .success("Imported and validated fixture file."))
}

@MainActor
@Test("Malformed fixture file is rejected")
func malformedFixtureFileIsRejected() throws {
  let fileURL = FileManager.default.temporaryDirectory
    .appending(path: UUID().uuidString)
    .appendingPathExtension("json")
  defer { try? FileManager.default.removeItem(at: fileURL) }
  try Data("not json".utf8).write(to: fileURL)

  let model = HostViewModel()
  model.importFixture(from: fileURL)

  #expect(model.selectedFixture == nil)
  guard case .failure(let message) = model.phase else {
    Issue.record("Expected malformed fixture import to fail")
    return
  }
  #expect(message.hasPrefix("Could not import fixture:"))
}

@MainActor
@Test("Full archive export captures every workout and route")
func fullArchiveExportCapturesEveryWorkout() async throws {
  let fixtures = try WorkoutFixturePreset.allFixtures()
  let source = InMemoryWorkoutSource(fixtures: fixtures)
  let model = HostViewModel(source: source, requestsAuthorization: false)

  await model.prepareFullArchiveExport()

  let data = try #require(model.exportedDocument?.data)
  let archive = try FixtureArchiveJSONCodec().decode(data)
  #expect(Set(archive.fixtures.map(\.id)) == Set(fixtures.map(\.id)))
  #expect(archive.fixtures.first(where: { $0.route != nil })?.route?.points.isEmpty == false)
  #expect(model.exportFilename == "workout-fixtures-archive")
  #expect(model.isExporting)
  #expect(model.phase == .success("Prepared 3 workout(s) in one mock archive."))
}
