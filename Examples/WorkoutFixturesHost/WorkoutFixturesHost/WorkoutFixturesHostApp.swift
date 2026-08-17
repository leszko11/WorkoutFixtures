import SwiftUI
import WorkoutFixturesDebugUI

// The host app is a thin shell around the package's debug panel: it exists to
// provide the HealthKit entitlement, usage descriptions, and a runnable target
// for UI and integration tests. Apps with their own HealthKit entitlement can
// embed WorkoutFixtureDebugView directly instead of using this host.
@main
struct WorkoutFixturesHostApp: App {
  var body: some Scene {
    WindowGroup {
      WorkoutFixtureDebugView()
    }
  }
}
