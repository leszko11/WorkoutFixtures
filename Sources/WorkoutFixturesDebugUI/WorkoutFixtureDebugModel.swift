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

    /// A workout the last archive export could not capture, with the reason.
    public struct SkippedWorkout: Equatable, Sendable, Identifiable {
      public let id: WorkoutID
      public let reason: String
    }

    /// Criteria for listing and exporting workouts; bindable from the filter screen.
    public var exportFilter = WorkoutExportFilter()

    public private(set) var summaries: [WorkoutSummary] = []
    /// Workouts the last archive export skipped because capture or validation failed.
    public private(set) var lastSkippedWorkouts: [SkippedWorkout] = []
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
    @ObservationIgnored var archiveDocumentBuilder:
      @Sendable ([WorkoutFixture]) async throws ->
        FixtureDocument = OffMainCodec.archiveDocument(fixtures:)

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

    /// The loaded summaries after applying ``exportFilter``.
    public var filteredSummaries: [WorkoutSummary] {
      exportFilter.apply(to: summaries)
    }

    public func authorizeAndRefresh() {
      run("Requesting HealthKit access") {
        if self.requestsAuthorization {
          try await self.authorization.requestAuthorization(for: .readWrite)
        }
        self.summaries = try await self.source.summaries(
          matching: self.exportFilter.query(),
          captureOptions: self.exportFilter.captureOptions
        )
        return "Loaded \(self.summaries.count) workout(s); "
          + "\(self.filteredSummaries.count) match the filters."
      }
    }

    public func select(_ summary: WorkoutSummary) {
      run("Capturing workout") {
        let fixture = try await self.source.fixture(
          for: summary.id,
          captureOptions: self.exportFilter.captureOptions
        )
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
        self.phase = .working("Encoding and compressing 1 workout…")
        let export = try await OffMainCodec.shareableDocument(fixture: selectedFixture, seed: seed)
        self.presentExport(document: export.document, filename: export.filename)
        return "Prepared shareable fixture."
      }
    }

    public func prepareFullExport() {
      guard let selectedFixture else { return }
      run("Preparing full export") {
        self.phase = .working("Encoding and compressing 1 workout…")
        let document = try await OffMainCodec.document(fixture: selectedFixture)
        self.presentExport(document: document, filename: "\(selectedFixture.id.rawValue).json.gz")
        return "Prepared full fixture."
      }
    }

    /// Exports every workout matching ``exportFilter`` as one archive.
    ///
    /// Workouts whose capture or validation fails are skipped and recorded in
    /// ``lastSkippedWorkouts`` instead of aborting the export; the export
    /// fails only when nothing could be captured.
    public func prepareFullArchiveExport() {
      run("Requesting HealthKit access") {
        if self.requestsAuthorization {
          try await self.authorization.requestAuthorization(for: .read)
        }
        self.lastSkippedWorkouts = []
        let filter = self.exportFilter
        self.summaries = try await self.source.summaries(
          matching: filter.query(),
          captureOptions: filter.captureOptions
        )
        let matching = filter.apply(to: self.summaries)
        guard !matching.isEmpty else {
          throw ArchiveExportError.noSupportedWorkouts
        }

        var fixtures: [WorkoutFixture] = []
        var skipped: [SkippedWorkout] = []
        fixtures.reserveCapacity(matching.count)
        for (index, summary) in matching.enumerated() {
          try Task.checkCancellation()
          self.phase = .working("Capturing workout \(index + 1) of \(matching.count)")
          do {
            let fixture = try await self.source.fixture(
              for: summary.id,
              captureOptions: filter.captureOptions
            )
            try WorkoutValidator().requireValid(fixture)
            fixtures.append(fixture)
          } catch let cancellation as CancellationError {
            throw cancellation
          } catch {
            skipped.append(SkippedWorkout(id: summary.id, reason: error.localizedDescription))
          }
        }
        self.lastSkippedWorkouts = skipped
        guard !fixtures.isEmpty else {
          throw ArchiveExportError.everyWorkoutFailed(count: skipped.count)
        }

        self.phase = .working("Encoding and compressing \(fixtures.count) workouts…")
        let document = try await self.archiveDocumentBuilder(fixtures)
        self.presentExport(document: document, filename: "workout-fixtures-archive.json.gz")
        if skipped.isEmpty {
          return "Prepared \(fixtures.count) workout(s) in one mock archive."
        }
        return "Prepared \(fixtures.count) workout(s); skipped \(skipped.count) that failed."
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

  enum ArchiveExportError: Error, Equatable, LocalizedError {
    case noSupportedWorkouts
    case everyWorkoutFailed(count: Int)

    var errorDescription: String? {
      switch self {
      case .noSupportedWorkouts:
        "No workouts match the current export filters."
      case .everyWorkoutFailed(let count):
        "All \(count) matching workout(s) failed to capture or validate."
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
      var data = try Data(contentsOf: url)
      if GzipCodec.isGzipped(data) {
        data = try GzipCodec.decompress(data)
      }
      return try FixtureJSONCodec().decode(data)
    }

    @concurrent
    static func bundledPreset() async throws -> WorkoutFixture {
      try WorkoutFixturePreset.outdoorRun.fixture()
    }

    @concurrent
    static func document(fixture: WorkoutFixture) async throws -> FixtureDocument {
      try Task.checkCancellation()
      return try FixtureDocument(fixture: fixture)
    }

    @concurrent
    static func shareableDocument(
      fixture: WorkoutFixture,
      seed: UInt64
    ) async throws -> (document: FixtureDocument, filename: String) {
      let redacted = try WorkoutRedactor().redact(fixture, seed: seed)
      try Task.checkCancellation()
      return (try FixtureDocument(fixture: redacted), "\(redacted.id.rawValue)-shareable.json.gz")
    }

    @concurrent
    static func archiveDocument(fixtures: [WorkoutFixture]) async throws -> FixtureDocument {
      try Task.checkCancellation()
      return try FixtureDocument(archive: WorkoutFixtureArchive(fixtures: fixtures))
    }
  }
#endif
