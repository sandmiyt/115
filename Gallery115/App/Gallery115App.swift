import SwiftUI

@main
struct Gallery115App: App {
  @Environment(\.scenePhase) private var scenePhase
  @State private var appState = AppState()

  var body: some Scene {
    WindowGroup {
      RootView()
        .environment(appState)
        .preferredColorScheme(appState.colorSchemePreference.colorScheme)
        .tint(.purple)
        .onChange(of: scenePhase) { _, phase in
          switch phase {
          case .active:
            Task { await appState.authenticateIfNeeded() }
          case .background:
            appState.lockForBackground()
          default:
            break
          }
        }
    }
  }
}
