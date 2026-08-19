import SwiftUI

@main
struct Gallery115App: App {
  @State private var appState = AppState()

  var body: some Scene {
    WindowGroup {
      RootView()
        .environment(appState)
        .preferredColorScheme(appState.colorSchemePreference.colorScheme)
    }
  }
}
