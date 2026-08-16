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
  ///   WorkoutFixtureDebugView(model: WorkoutFixtureDebugModel())
  /// #endif
  /// ```
  public struct WorkoutFixtureDebugView: View {
    @Bindable private var model: WorkoutFixtureDebugModel
    @State private var confirmsPrivateExport = false
    @State private var privateExportRequest = PrivateExportRequest.selectedFixture
    @State private var isImportingFixture = false

    public init(model: WorkoutFixtureDebugModel) {
      self.model = model
    }

    public var body: some View {
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
      case .allWorkouts: "Export All Workouts"
      }
    }

    var warning: String {
      switch self {
      case .selectedFixture:
        "The full fixture can contain exact dates, a GPS route, and source metadata. "
          + "Keep the file private."
      case .allWorkouts:
        "The archive can contain exact dates, every GPS route, and source metadata for all "
          + "supported workouts. Keep the file private."
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

        #if !targetEnvironment(simulator)
          Button("Export All Workouts for Mocking", role: .destructive) {
            requestFullArchiveExport()
          }
          .accessibilityIdentifier("exportAllWorkouts")

          Text(
            "Captures supported workouts, metric samples, events, and every route into one file."
          )
          .font(.footnote)
          .foregroundStyle(.secondary)
        #endif

        ForEach(model.summaries) { summary in
          Button {
            model.select(summary)
          } label: {
            WorkoutSummaryRow(activity: summary.activity, startDate: summary.startDate)
          }
          .accessibilityIdentifier("workoutSummaryRow-\(summary.id.rawValue)")
        }
      }
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
