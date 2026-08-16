import SwiftUI

@main
struct WorkoutFixturesHostApp: App {
  @State private var model = HostViewModel()

  var body: some Scene {
    WindowGroup {
      ContentView(model: model)
    }
  }
}
