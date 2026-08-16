#if canImport(SwiftUI) && canImport(HealthKit) && !os(watchOS)
  import Foundation
  import HealthKit
  import Observation
  import WorkoutFixtures
  import WorkoutFixturesHealthKit
  import WorkoutFixturesTestSupport

  /// The state and operations behind ``WorkoutFixtureDebugView``.
  ///
  /// All collaborators are protocol-typed, so the model runs against the real
  /// HealthKit adapters in an entitled app and against in-memory doubles in
  /// tests. Operations run one at a time: starting one while another is in
  /// flight is ignored, and ``cancelCurrentOperation()`` cancels cooperatively.
  @MainActor
  @Observable
  public final class WorkoutFixtureDebugModel {
    public enum Phase: Equatable, Sendable {
      case idle
      case working(String)
      case success(String)
      case failure(String)
    }

    private let source: any WorkoutFixtureSource
    private let sink: any WorkoutFixtureSink & WorkoutFixtureDeleting
    private let authorization: any HealthAuthorizing
    private let requestsAuthorization: Bool

    public private(set) var summaries: [WorkoutSummary] = []
    public private(set) var selectedFixture: WorkoutFixture?
    public private(set) var validationIssues: [ValidationIssue] = []
    public private(set) var selectedSampleCount = 0
    public private(set) var validationErrorCount = 0
    public private(set) var lastStoredWorkout: StoredWorkout?
    public private(set) var phase: Phase = .idle
    public private(set) var exportedDocument: FixtureDocument?
    public private(set) var exportFilename = "workout-fixture"
    public var isExporting = false

    @ObservationIgnored private var currentOperation: Task<Void, Never>?

    public init(
      source: any WorkoutFixtureSource,
      sink: any WorkoutFixtureSink & WorkoutFixtureDeleting,
      authorization: any HealthAuthorizing,
      requestsAuthorization: Bool = true,
      loadsBundledFixtureOnLaunch: Bool =
        ProcessInfo.processInfo.arguments.contains("--bundled-fixture")
    ) {
      self.source = source
      self.sink = sink
      self.authorization = authorization
      self.requestsAuthorization = requestsAuthorization
      if loadsBundledFixtureOnLaunch {
        loadBundledFixture()
      }
    }

    /// Wires the real HealthKit adapters; the hosting app must hold the
    /// HealthKit entitlement and usage descriptions.
    public convenience init(
      healthStore: HKHealthStore = HKHealthStore(),
      requestsAuthorization: Bool = true
    ) {
      self.init(
        source: HealthKitWorkoutSource(healthStore: healthStore),
        sink: HealthKitWorkoutSink(healthStore: healthStore),
        authorization: HealthKitAuthorizationController(healthStore: healthStore),
        requestsAuthorization: requestsAuthorization
      )
    }

    public func authorizeAndRefresh() {
      run("Requesting HealthKit access") {
        if self.requestsAuthorization {
          try await self.authorization.requestAuthorization(for: .readWrite)
        }
        self.summaries = try await self.source.summaries(matching: WorkoutQuery())
        return "Loaded \(self.summaries.count) HealthKit workout(s)."
      }
    }

    public func select(_ summary: WorkoutSummary) {
      run("Capturing workout") {
        let fixture = try await self.source.fixture(for: summary.id)
        self.selectFixture(fixture)
        return "Captured \(summary.activity.rawValue) fixture."
      }
    }

    public func loadBundledFixture() {
      run("Loading bundled fixture") {
        let fixture = try await OffMainCodec.bundledPreset()
        self.selectFixture(fixture)
        return "Loaded bundled fixture."
      }
    }

    public func importFixture(from fileURL: URL) {
      clearSelection()
      run("Importing fixture") {
        let fixture = try await OffMainCodec.decodeFixture(at: fileURL)
        self.selectFixture(fixture)
        guard self.validationErrorCount == 0 else {
          throw FixtureImportValidationError(errorCount: self.validationErrorCount)
        }
        return "Imported and validated fixture file."
      }
    }

    public func writeSelectedFixtureToHealthKit() {
      guard let selectedFixture else { return }
      run("Writing fixture to HealthKit") {
        self.lastStoredWorkout = try await self.sink.store(selectedFixture)
        return "Fixture stored in HealthKit."
      }
    }

    public func removeLastImport() {
      guard let externalID = lastStoredWorkout?.externalID else { return }
      run("Removing imported workout") {
        try await self.sink.delete(externalID: externalID)
        self.lastStoredWorkout = nil
        return "Imported workout removed."
      }
    }

    public func prepareShareableExport(seed: UInt64 = 42) {
      guard let selectedFixture else { return }
      run("Preparing shareable export") {
        let export = try await OffMainCodec.shareableDocument(fixture: selectedFixture, seed: seed)
        self.presentExport(document: export.document, filename: export.filename)
        return "Prepared shareable fixture."
      }
    }

    public func prepareFullExport() {
      guard let selectedFixture else { return }
      run("Preparing full export") {
        let document = try await OffMainCodec.document(fixture: selectedFixture)
        self.presentExport(document: document, filename: selectedFixture.id.rawValue)
        return "Prepared full fixture."
      }
    }

    public func prepareFullArchiveExport() {
      run("Requesting HealthKit access") {
        if self.requestsAuthorization {
          try await self.authorization.requestAuthorization(for: .read)
        }
        let availableSummaries = try await self.source.summaries(matching: WorkoutQuery())
        guard !availableSummaries.isEmpty else {
          throw ArchiveExportError.noSupportedWorkouts
        }

        var fixtures: [WorkoutFixture] = []
        fixtures.reserveCapacity(availableSummaries.count)
        for (index, summary) in availableSummaries.enumerated() {
          try Task.checkCancellation()
          self.phase = .working("Capturing workout \(index + 1) of \(availableSummaries.count)")
          let fixture = try await self.source.fixture(for: summary.id)
          do {
            try WorkoutValidator().requireValid(fixture)
          } catch let error as FixtureValidationError {
            self.selectFixture(fixture)
            throw ArchiveExportError.invalidWorkout(id: summary.id, issues: error.issues)
          }
          fixtures.append(fixture)
        }

        let document = try await OffMainCodec.archiveDocument(fixtures: fixtures)
        self.presentExport(document: document, filename: "workout-fixtures-archive")
        return "Prepared \(fixtures.count) workout(s) in one mock archive."
      }
    }

    public func report(_ error: any Error) {
      phase = .failure(error.localizedDescription)
    }

    /// Cancels the in-flight operation, if any; the phase returns to idle.
    public func cancelCurrentOperation() {
      currentOperation?.cancel()
    }

    /// Awaits the in-flight operation. Intended for tests.
    public func awaitCurrentOperation() async {
      await currentOperation?.value
    }

    private func clearSelection() {
      selectedFixture = nil
      validationIssues = []
      selectedSampleCount = 0
      validationErrorCount = 0
      exportedDocument = nil
    }

    private func selectFixture(_ fixture: WorkoutFixture) {
      selectedFixture = fixture
      validationIssues = WorkoutValidator().validate(fixture)
      selectedSampleCount = fixture.series.reduce(0) { $0 + $1.samples.count }
      validationErrorCount = validationIssues.count(where: { $0.severity == .error })
    }

    private func presentExport(document: FixtureDocument, filename: String) {
      exportedDocument = document
      exportFilename = filename
      isExporting = true
    }

    private func run(_ message: String, operation: @escaping () async throws -> String) {
      guard currentOperation == nil else { return }
      phase = .working(message)
      currentOperation = Task {
        do {
          phase = .success(try await operation())
        } catch is CancellationError {
          phase = .idle
        } catch {
          phase = .failure(error.localizedDescription)
        }
        currentOperation = nil
      }
    }
  }

  struct FixtureImportValidationError: Error, LocalizedError {
    let errorCount: Int

    var errorDescription: String? {
      "Imported fixture has \(errorCount) validation error(s)."
    }
  }

  enum ArchiveExportError: Error, LocalizedError {
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

  /// JSON decode/encode helpers that run off the main actor so large fixtures
  /// and archives never hitch the UI.
  private enum OffMainCodec {
    @concurrent
    static func decodeFixture(at url: URL) async throws -> WorkoutFixture {
      let hasSecurityScope = url.startAccessingSecurityScopedResource()
      defer {
        if hasSecurityScope {
          url.stopAccessingSecurityScopedResource()
        }
      }
      return try FixtureJSONCodec().decode(Data(contentsOf: url))
    }

    @concurrent
    static func bundledPreset() async throws -> WorkoutFixture {
      try WorkoutFixturePreset.outdoorRun.fixture()
    }

    @concurrent
    static func document(fixture: WorkoutFixture) async throws -> FixtureDocument {
      try FixtureDocument(fixture: fixture)
    }

    @concurrent
    static func shareableDocument(
      fixture: WorkoutFixture,
      seed: UInt64
    ) async throws -> (document: FixtureDocument, filename: String) {
      let redacted = try WorkoutRedactor().redact(fixture, seed: seed)
      return (try FixtureDocument(fixture: redacted), "\(redacted.id.rawValue)-shareable")
    }

    @concurrent
    static func archiveDocument(fixtures: [WorkoutFixture]) async throws -> FixtureDocument {
      try FixtureDocument(archive: WorkoutFixtureArchive(fixtures: fixtures))
    }
  }
#endif
