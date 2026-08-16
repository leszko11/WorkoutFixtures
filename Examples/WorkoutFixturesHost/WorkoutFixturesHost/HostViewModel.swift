import Foundation
import HealthKit
import Observation
import WorkoutFixtures
import WorkoutFixturesHealthKit
import WorkoutFixturesTestSupport

@MainActor
@Observable
final class HostViewModel {
  enum Phase: Equatable {
    case idle
    case working(String)
    case success(String)
    case failure(String)
  }

  private let source: any WorkoutFixtureSource
  private let sink: HealthKitWorkoutSink
  private let authorization: HealthKitAuthorizationController
  private let requestsAuthorization: Bool

  var summaries: [WorkoutSummary] = []
  var selectedFixture: WorkoutFixture?
  var validationIssues: [ValidationIssue] = []
  var lastStoredWorkout: StoredWorkout?
  var phase: Phase = .idle
  var exportedDocument: FixtureDocument?
  var exportFilename = "workout-fixture"
  var isExporting = false

  init(
    store: HKHealthStore = HKHealthStore(),
    source: (any WorkoutFixtureSource)? = nil,
    requestsAuthorization: Bool = true
  ) {
    self.source = source ?? HealthKitWorkoutSource(healthStore: store)
    self.requestsAuthorization = requestsAuthorization
    sink = HealthKitWorkoutSink(healthStore: store)
    authorization = HealthKitAuthorizationController(healthStore: store)
    if ProcessInfo.processInfo.arguments.contains("--bundled-fixture") {
      loadBundledFixture()
    }
  }

  func authorizeAndRefresh() async {
    await perform("Requesting HealthKit access") {
      try await authorization.requestAuthorization(for: .readWrite)
      summaries = try await source.summaries(matching: WorkoutQuery())
      return "Loaded \(summaries.count) HealthKit workout(s)."
    }
  }

  func refresh() async {
    await perform("Reading workouts") {
      summaries = try await source.summaries(matching: WorkoutQuery())
      return "Loaded \(summaries.count) HealthKit workout(s)."
    }
  }

  func select(_ summary: WorkoutSummary) async {
    await perform("Capturing workout") {
      let fixture = try await source.fixture(for: summary.id)
      selectFixture(fixture)
      return "Captured \(summary.activity.rawValue) fixture."
    }
  }

  func loadBundledFixture() {
    do {
      let fixture = try WorkoutFixturePreset.outdoorRun.fixture()
      selectFixture(fixture)
      phase = .success("Loaded bundled fixture.")
    } catch {
      phase = .failure(error.localizedDescription)
    }
  }

  func importFixture(from fileURL: URL) {
    selectedFixture = nil
    validationIssues = []
    exportedDocument = nil

    let hasSecurityScope = fileURL.startAccessingSecurityScopedResource()
    defer {
      if hasSecurityScope {
        fileURL.stopAccessingSecurityScopedResource()
      }
    }

    do {
      let fixture = try FixtureJSONCodec().decode(Data(contentsOf: fileURL))
      selectFixture(fixture)
      let errorCount = validationIssues.filter { $0.severity == .error }.count
      if errorCount == 0 {
        phase = .success("Imported and validated fixture file.")
      } else {
        phase = .failure("Imported fixture has \(errorCount) validation error(s).")
      }
    } catch {
      phase = .failure("Could not import fixture: \(error.localizedDescription)")
    }
  }

  func writeSelectedFixtureToHealthKit() async {
    guard let selectedFixture else { return }
    await perform("Writing fixture to HealthKit") {
      lastStoredWorkout = try await sink.store(selectedFixture)
      return "Fixture stored in HealthKit."
    }
  }

  func removeLastImport() async {
    guard let externalID = lastStoredWorkout?.externalID else { return }
    await perform("Removing imported workout") {
      try await sink.delete(externalID: externalID)
      lastStoredWorkout = nil
      return "Imported workout removed."
    }
  }

  func prepareShareableExport(seed: UInt64 = 42) {
    guard let selectedFixture else { return }
    do {
      let fixture = try WorkoutRedactor().redact(selectedFixture, seed: seed)
      exportedDocument = try FixtureDocument(fixture: fixture)
      exportFilename = "\(fixture.id.rawValue)-shareable"
      isExporting = true
    } catch {
      phase = .failure(error.localizedDescription)
    }
  }

  func prepareFullExport() {
    guard let selectedFixture else { return }
    do {
      exportedDocument = try FixtureDocument(fixture: selectedFixture)
      exportFilename = selectedFixture.id.rawValue
      isExporting = true
    } catch {
      phase = .failure(error.localizedDescription)
    }
  }

  func prepareFullArchiveExport() async {
    await perform("Requesting HealthKit access") {
      if requestsAuthorization {
        try await authorization.requestAuthorization(for: .read)
      }
      let availableSummaries = try await source.summaries(matching: WorkoutQuery())
      guard !availableSummaries.isEmpty else {
        throw ArchiveExportError.noSupportedWorkouts
      }

      var fixtures: [WorkoutFixture] = []
      fixtures.reserveCapacity(availableSummaries.count)
      for (index, summary) in availableSummaries.enumerated() {
        try Task.checkCancellation()
        phase = .working("Capturing workout \(index + 1) of \(availableSummaries.count)")
        let fixture = try await source.fixture(for: summary.id)
        do {
          try WorkoutValidator().requireValid(fixture)
        } catch let error as FixtureValidationError {
          selectFixture(fixture)
          throw ArchiveExportError.invalidWorkout(id: summary.id, issues: error.issues)
        }
        fixtures.append(fixture)
      }

      let archive = try WorkoutFixtureArchive(fixtures: fixtures)
      exportedDocument = try FixtureDocument(archive: archive)
      exportFilename = "workout-fixtures-archive"
      isExporting = true
      return "Prepared \(fixtures.count) workout(s) in one mock archive."
    }
  }

  func report(_ error: any Error) {
    phase = .failure(error.localizedDescription)
  }

  private func selectFixture(_ fixture: WorkoutFixture) {
    selectedFixture = fixture
    validationIssues = WorkoutValidator().validate(fixture)
  }

  private func perform(
    _ message: String,
    operation: () async throws -> String
  ) async {
    phase = .working(message)
    do {
      phase = .success(try await operation())
    } catch is CancellationError {
      phase = .idle
    } catch {
      phase = .failure(error.localizedDescription)
    }
  }
}

private enum ArchiveExportError: Error, LocalizedError {
  case noSupportedWorkouts
  case invalidWorkout(id: WorkoutID, issues: [ValidationIssue])

  var errorDescription: String? {
    switch self {
    case .noSupportedWorkouts:
      "No supported running, walking, or cycling workouts were found."
    case .invalidWorkout(let id, let issues):
      "Workout \(id.rawValue) failed validation: \(issues.map(\.code).joined(separator: ", "))."
    }
  }
}
