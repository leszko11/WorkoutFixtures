#if canImport(SwiftUI) && canImport(HealthKit) && !os(watchOS)
  import SwiftUI
  import UniformTypeIdentifiers
  import WorkoutFixtures
  import WorkoutFixturesHealthKit
  import WorkoutFixturesTestSupport

  /// A drop-in debug panel for capturing, exporting, importing, and replaying
  /// workout fixtures.
  ///
  /// Embed it behind `#if DEBUG` in any app that already holds the HealthKit
  /// entitlement and usage descriptions:
  ///
  /// ```swift
  /// #if DEBUG
  ///   WorkoutFixtureDebugView()
  /// #endif
  /// ```
  public struct WorkoutFixtureDebugView: View {
    @State private var model: WorkoutFixtureDebugModel
    @State private var confirmsPrivateExport = false
    @State private var privateExportRequest = PrivateExportRequest.selectedFixture
    @State private var isImportingFixture = false

    /// Uses the real HealthKit adapters; the hosting app provides the
    /// entitlement and usage descriptions.
    public init() {
      _model = State(initialValue: WorkoutFixtureDebugModel())
    }

    /// Uses an externally configured model — for injected sources, tests,
    /// or previews.
    public init(model: WorkoutFixtureDebugModel) {
      _model = State(initialValue: model)
    }

    public var body: some View {
      @Bindable var model = model
      NavigationStack {
        List {
          TransferGuidanceSection()
          HealthKitSection(model: model) {
            privateExportRequest = .allWorkouts
            confirmsPrivateExport = true
          }
          FixtureSection(
            model: model,
            isImportingFixture: $isImportingFixture,
            requestFullExport: {
              privateExportRequest = .selectedFixture
              confirmsPrivateExport = true
            }
          )

          if model.lastStoredWorkout != nil {
            CleanupSection(model: model)
          }

          if !model.lastSkippedWorkouts.isEmpty {
            SkippedSection(skipped: model.lastSkippedWorkouts)
          }

          StatusSection(model: model)
        }
        .navigationTitle("Workout Fixtures")
      }
      .alert("Export identifiable workout data?", isPresented: $confirmsPrivateExport) {
        Button("Cancel", role: .cancel) {}
        Button(privateExportRequest.actionTitle, role: .destructive) {
          switch privateExportRequest {
          case .selectedFixture:
            model.prepareFullExport()
          case .allWorkouts:
            model.prepareFullArchiveExport()
          }
        }
      } message: {
        Text(privateExportRequest.warning)
      }
      .fileImporter(
        isPresented: $isImportingFixture,
        allowedContentTypes: [.json],
        allowsMultipleSelection: false
      ) { result in
        switch result {
        case .success(let urls):
          guard let url = urls.first else { return }
          model.importFixture(from: url)
        case .failure(let error):
          model.report(error)
        }
      }
      .fileExporter(
        isPresented: $model.isExporting,
        document: model.exportedDocument,
        contentType: .json,
        defaultFilename: model.exportFilename
      ) { result in
        if case .failure(let error) = result {
          model.report(error)
        }
      }
    }
  }

  private enum PrivateExportRequest {
    case selectedFixture
    case allWorkouts

    var actionTitle: String {
      switch self {
      case .selectedFixture: "Export Full Fixture"
      case .allWorkouts: "Export Matching Workouts"
      }
    }

    var warning: String {
      switch self {
      case .selectedFixture:
        "The full fixture can contain exact dates, a GPS route, and source metadata. "
          + "Keep the file private."
      case .allWorkouts:
        "The archive can contain exact dates, GPS routes, and source metadata for every "
          + "matching workout. Keep the file private."
      }
    }
  }

  private struct TransferGuidanceSection: View {
    var body: some View {
      Section("Device → Mock Source") {
        Label {
          #if targetEnvironment(simulator)
            Text(
              "Load the device archive directly in your app with JSONWorkoutSource. This host is "
                + "only needed here when testing the real HealthKit adapter."
            )
          #else
            Text(
              "Export one private archive below, then add it to your app target and load it with "
                + "JSONWorkoutSource."
            )
          #endif
        } icon: {
          Image(systemName: "iphone.and.arrow.forward")
        }
        .accessibilityIdentifier("transferGuidance")
      }
    }
  }

  private struct HealthKitSection: View {
    let model: WorkoutFixtureDebugModel
    let requestFullArchiveExport: () -> Void

    var body: some View {
      Section("HealthKit") {
        Button("Authorize and Refresh") {
          model.authorizeAndRefresh()
        }
        .accessibilityIdentifier("authorizeAndRefresh")

        if !model.summaries.isEmpty {
          LabeledContent("Workouts") {
            Text("\(model.filteredSummaries.count) of \(model.summaries.count) match")
          }
          .accessibilityIdentifier("workoutCounts")
        }

        NavigationLink("Export Filters") {
          ExportFilterView(model: model)
        }
        .accessibilityIdentifier("exportFilters")

        NavigationLink {
          WorkoutListView(model: model)
        } label: {
          LabeledContent("Browse Workouts", value: "\(model.filteredSummaries.count)")
        }
        .accessibilityIdentifier("browseWorkouts")

        #if !targetEnvironment(simulator)
          Button("Export Matching Workouts for Mocking", role: .destructive) {
            requestFullArchiveExport()
          }
          .accessibilityIdentifier("exportAllWorkouts")

          Text(
            "Captures every workout matching the export filters — samples, events, and routes — "
              + "into one file. Workouts that fail to capture are skipped."
          )
          .font(.footnote)
          .foregroundStyle(.secondary)
        #endif
      }
    }
  }

  private struct ExportFilterView: View {
    @Bindable var model: WorkoutFixtureDebugModel

    var body: some View {
      Form {
        Section {
          NavigationLink {
            ActivityFilterView(model: model)
          } label: {
            LabeledContent("Activities", value: activitiesSummary)
          }
          .accessibilityIdentifier("filterActivities")
        } footer: {
          Text("With nothing selected, every activity is included.")
        }

        Section("Date") {
          Picker("Time window", selection: $model.exportFilter.dateWindow) {
            ForEach(WorkoutExportFilter.DateWindow.allCases, id: \.self) { window in
              Text(window.displayName).tag(window)
            }
          }
          .accessibilityIdentifier("filterDateWindow")
        }

        Section {
          LabeledContent("Min distance (km)") {
            TextField("Any", value: optionalBinding(\.minimumDistanceKilometers), format: .number)
              .multilineTextAlignment(.trailing)
              .accessibilityIdentifier("filterMinDistance")
          }
          LabeledContent("Min duration (min)") {
            TextField("Any", value: optionalBinding(\.minimumDurationMinutes), format: .number)
              .multilineTextAlignment(.trailing)
              .accessibilityIdentifier("filterMinDuration")
          }
          LabeledContent("Max workouts") {
            TextField("All", value: limitBinding, format: .number)
              .multilineTextAlignment(.trailing)
              .accessibilityIdentifier("filterLimit")
          }
        } header: {
          Text("Thresholds")
        } footer: {
          Text("Zero means no limit. The newest workouts are kept when a maximum is set.")
        }

        Section {
          Toggle("Include GPS routes", isOn: $model.exportFilter.includesRoutes)
            .accessibilityIdentifier("filterIncludeRoutes")
        } footer: {
          Text(
            "Routes identify places you visit. Exclude them unless the code under test needs them."
          )
        }

        if !model.summaries.isEmpty {
          LabeledContent("Matching workouts", value: "\(model.filteredSummaries.count)")
            .accessibilityIdentifier("filterMatchCount")
        }
      }
      .navigationTitle("Export Filters")
      #if os(iOS)
        .keyboardType(.decimalPad)
      #endif
    }

    private var activitiesSummary: String {
      let selected = model.exportFilter.activities
      switch selected.count {
      case 0:
        return "All"
      case 1, 2:
        return selected.map(\.displayName).sorted().joined(separator: ", ")
      default:
        return "\(selected.count) selected"
      }
    }

    // Zero-backed bindings for the optional thresholds: 0 in the field means
    // "no filter", which round-trips as nil on the model.
    private func optionalBinding(
      _ keyPath: WritableKeyPath<WorkoutExportFilter, Double?>
    ) -> Binding<Double> {
      Binding(
        get: { model.exportFilter[keyPath: keyPath] ?? 0 },
        set: { model.exportFilter[keyPath: keyPath] = $0 > 0 ? $0 : nil }
      )
    }

    private var limitBinding: Binding<Int> {
      Binding(
        get: { model.exportFilter.limit ?? 0 },
        set: { model.exportFilter.limit = $0 > 0 ? $0 : nil }
      )
    }
  }

  private struct WorkoutListView: View {
    let model: WorkoutFixtureDebugModel

    var body: some View {
      List(model.filteredSummaries) { summary in
        Button {
          model.select(summary)
        } label: {
          HStack {
            WorkoutSummaryRow(activity: summary.activity, startDate: summary.startDate)
            if model.selectedFixture?.id == summary.id {
              Spacer()
              Image(systemName: "checkmark")
                .foregroundStyle(.tint)
            }
          }
        }
        .accessibilityIdentifier("workoutSummaryRow-\(summary.id.rawValue)")
      }
      .overlay {
        if model.filteredSummaries.isEmpty {
          ContentUnavailableView(
            "No Workouts",
            systemImage: "figure.run",
            description: Text("Authorize and refresh, or loosen the export filters.")
          )
        }
      }
      .navigationTitle("Workouts (\(model.filteredSummaries.count))")
    }
  }

  private struct FixtureSection: View {
    let model: WorkoutFixtureDebugModel
    @Binding var isImportingFixture: Bool
    let requestFullExport: () -> Void

    var body: some View {
      Section("Fixture") {
        Button("Import Fixture File") {
          isImportingFixture = true
        }
        .accessibilityIdentifier("importFixtureFile")

        Button("Load Bundled Fixture") { model.loadBundledFixture() }
          .accessibilityIdentifier("loadBundledFixture")

        if let fixture = model.selectedFixture {
          LabeledContent("ID", value: fixture.id.rawValue)
            .accessibilityIdentifier("fixtureID")
          LabeledContent("Activity", value: fixture.workout.activity.rawValue)
            .accessibilityIdentifier("fixtureActivity")
          LabeledContent("Samples", value: String(model.selectedSampleCount))
            .accessibilityIdentifier("fixtureSampleCount")
          LabeledContent("Validation errors", value: String(model.validationErrorCount))
            .accessibilityIdentifier("fixtureValidationErrors")

          Button("Write Fixture to HealthKit") {
            model.writeSelectedFixtureToHealthKit()
          }
          .disabled(model.validationErrorCount > 0)
          .accessibilityIdentifier("writeFixture")

          Button("Export Shareable Copy") {
            model.prepareShareableExport()
          }
          .accessibilityIdentifier("exportShareable")

          Text("The shareable copy removes the GPS route and identifying metadata.")
            .font(.footnote)
            .foregroundStyle(.secondary)

          Button("Export Full Fixture for Simulator", role: .destructive) {
            requestFullExport()
          }
          .accessibilityIdentifier("exportFullFixture")
        }
      }
    }
  }

  private struct CleanupSection: View {
    let model: WorkoutFixtureDebugModel

    var body: some View {
      Section("Cleanup") {
        Button("Remove Last Imported Workout", role: .destructive) {
          model.removeLastImport()
        }
        .accessibilityIdentifier("removeLastImport")
      }
    }
  }

  private struct SkippedSection: View {
    let skipped: [WorkoutFixtureDebugModel.SkippedWorkout]
    private static let previewCount = 5

    var body: some View {
      Section("Skipped by Last Export") {
        ForEach(skipped.prefix(Self.previewCount)) { workout in
          VStack(alignment: .leading) {
            Text(workout.id.rawValue).font(.footnote.monospaced())
            Text(workout.reason).font(.caption).foregroundStyle(.secondary)
          }
        }
        if skipped.count > Self.previewCount {
          Text("… and \(skipped.count - Self.previewCount) more")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private struct StatusSection: View {
    let model: WorkoutFixtureDebugModel

    var body: some View {
      Section("Status") {
        switch model.phase {
        case .idle:
          Text("Ready")
        case .working(let message):
          HStack {
            ProgressView()
            Text(message)
            Spacer()
            Button("Cancel") { model.cancelCurrentOperation() }
              .accessibilityIdentifier("cancelOperation")
          }
        case .success(let message):
          Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failure(let message):
          Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
      }
    }
  }

  private struct WorkoutSummaryRow: View {
    let activity: WorkoutActivity
    let startDate: Date

    var body: some View {
      VStack(alignment: .leading) {
        Text(activity.rawValue.capitalized).font(.headline)
        Text(startDate, format: .dateTime.day().month().year().hour().minute())
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  #if DEBUG
    #Preview {
      WorkoutFixtureDebugView(model: makePreviewModel())
    }

    @MainActor
    private func makePreviewModel() -> WorkoutFixtureDebugModel {
      struct PreviewAuthorizer: HealthAuthorizing {
        func requestAuthorization(for access: HealthKitWorkoutAccess) async throws {}
      }
      let store = InMemoryWorkoutStore(fixtures: (try? WorkoutFixturePreset.allFixtures()) ?? [])
      let model = WorkoutFixtureDebugModel(
        source: store,
        sink: store,
        authorization: PreviewAuthorizer(),
        requestsAuthorization: false,
        loadsBundledFixtureOnLaunch: false
      )
      model.authorizeAndRefresh()
      return model
    }
  #endif
#endif
