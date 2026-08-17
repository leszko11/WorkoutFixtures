#if canImport(SwiftUI) && canImport(HealthKit) && !os(watchOS)
  import SwiftUI
  import WorkoutFixtures

  extension WorkoutActivity {
    /// Human-readable name derived from the camelCase raw value,
    /// e.g. `highIntensityIntervalTraining` → "High Intensity Interval Training".
    var displayName: String {
      var result = ""
      for (index, character) in rawValue.enumerated() {
        if index == 0 {
          result.append(contentsOf: character.uppercased())
        } else {
          if character.isUppercase {
            result.append(" ")
          }
          result.append(character)
        }
      }
      return result
    }
  }

  /// A searchable multi-select list of every supported workout activity.
  /// An empty selection means "include everything".
  struct ActivityFilterView: View {
    @Bindable var model: WorkoutFixtureDebugModel
    @State private var searchText = ""

    private static let allActivities = WorkoutActivity.allCases.sorted {
      $0.displayName < $1.displayName
    }

    private var visibleActivities: [WorkoutActivity] {
      guard !searchText.isEmpty else { return Self.allActivities }
      return Self.allActivities.filter {
        $0.displayName.localizedCaseInsensitiveContains(searchText)
      }
    }

    var body: some View {
      List {
        Section {
          Button("Select All", action: selectAll)
            .disabled(model.exportFilter.activities.count == Self.allActivities.count)
            .accessibilityIdentifier("selectAllActivities")
          Button("Deselect All", action: deselectAll)
            .disabled(model.exportFilter.activities.isEmpty)
            .accessibilityIdentifier("deselectAllActivities")
        }

        Section {
          ForEach(visibleActivities, id: \.self) { activity in
            ActivityRow(
              activity: activity,
              isSelected: model.exportFilter.activities.contains(activity),
              toggle: { toggle(activity) }
            )
          }
        } footer: {
          Text("With nothing selected, every activity is included.")
        }
      }
      .searchable(text: $searchText, prompt: "Search activities")
      .navigationTitle(navigationTitle)
    }

    private var navigationTitle: String {
      let count = model.exportFilter.activities.count
      return count == 0 ? "Activities" : "Activities (\(count))"
    }

    private func toggle(_ activity: WorkoutActivity) {
      if model.exportFilter.activities.contains(activity) {
        model.exportFilter.activities.remove(activity)
      } else {
        model.exportFilter.activities.insert(activity)
      }
    }

    private func selectAll() {
      model.exportFilter.activities = Set(Self.allActivities)
    }

    private func deselectAll() {
      model.exportFilter.activities = []
    }
  }

  private struct ActivityRow: View {
    let activity: WorkoutActivity
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
      Button(action: toggle) {
        HStack {
          Text(activity.displayName)
            .foregroundStyle(.primary)
          Spacer()
          Image(systemName: "checkmark")
            .foregroundStyle(.tint)
            .opacity(isSelected ? 1 : 0)
        }
      }
      .accessibilityIdentifier("filterActivity-\(activity.rawValue)")
      .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
  }
#endif
