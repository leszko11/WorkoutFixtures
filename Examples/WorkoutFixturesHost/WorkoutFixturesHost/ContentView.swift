import SwiftUI
import UniformTypeIdentifiers
import WorkoutFixtures

struct ContentView: View {
  @Bindable var model: HostViewModel
  @State private var confirmsPrivateExport = false
  @State private var privateExportRequest = PrivateExportRequest.selectedFixture
  @State private var isImportingFixture = false

  var body: some View {
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

        StatusSection(phase: model.phase)
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
          Task { await model.prepareFullArchiveExport() }
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
      "The full fixture can contain exact dates, a GPS route, and source metadata. Keep the file private."
    case .allWorkouts:
      "The archive can contain exact dates, every GPS route, and source metadata for all supported workouts. Keep the file private."
    }
  }
}

private struct TransferGuidanceSection: View {
  var body: some View {
    Section("Device → Mock Source") {
      Label {
        #if targetEnvironment(simulator)
          Text(
            "Load the device archive directly in your app with JSONWorkoutSource. This host is only needed here when testing the real HealthKit adapter."
          )
        #else
          Text(
            "Export one private archive below, then add it to your app target and load it with JSONWorkoutSource."
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
  let model: HostViewModel
  let requestFullArchiveExport: () -> Void

  var body: some View {
    Section("HealthKit") {
      Button("Authorize and Refresh") {
        Task { await model.authorizeAndRefresh() }
      }
      .accessibilityIdentifier("authorizeAndRefresh")

      #if !targetEnvironment(simulator)
        Button("Export All Workouts for Mocking", role: .destructive) {
          requestFullArchiveExport()
        }
        .accessibilityIdentifier("exportAllWorkouts")

        Text("Captures supported workouts, metric samples, events, and every route into one file.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      #endif

      ForEach(model.summaries) { summary in
        Button {
          Task { await model.select(summary) }
        } label: {
          WorkoutSummaryRow(activity: summary.activity, startDate: summary.startDate)
        }
      }
    }
  }
}

private struct FixtureSection: View {
  let model: HostViewModel
  @Binding var isImportingFixture: Bool
  let requestFullExport: () -> Void

  private var hasValidationErrors: Bool {
    model.validationIssues.contains { $0.severity == .error }
  }

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
        LabeledContent("Samples", value: String(fixture.series.flatMap(\.samples).count))
        LabeledContent(
          "Validation errors",
          value: String(model.validationIssues.filter { $0.severity == .error }.count)
        )

        Button("Write Fixture to HealthKit") {
          Task { await model.writeSelectedFixtureToHealthKit() }
        }
        .disabled(hasValidationErrors)
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
  let model: HostViewModel

  var body: some View {
    Section("Cleanup") {
      Button("Remove Last Imported Workout", role: .destructive) {
        Task { await model.removeLastImport() }
      }
      .accessibilityIdentifier("removeLastImport")
    }
  }
}

private struct StatusSection: View {
  let phase: HostViewModel.Phase

  var body: some View {
    Section("Status") {
      switch phase {
      case .idle:
        Text("Ready")
      case .working(let message):
        HStack {
          ProgressView()
          Text(message)
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
      Text(startDate.formatted()).font(.caption).foregroundStyle(.secondary)
    }
  }
}
