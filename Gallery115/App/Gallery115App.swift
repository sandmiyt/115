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
        .tint(CinevaTheme.accent)
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

enum CinevaTheme {
  static let accent = Color(red: 1.00, green: 0.40, blue: 0.08)
  static let accentWarm = Color(red: 1.00, green: 0.62, blue: 0.08)
  static let accentRed = Color(red: 0.96, green: 0.16, blue: 0.10)
  static let darkBackground = Color(red: 0.025, green: 0.027, blue: 0.032)
  static let darkPanel = Color(red: 0.075, green: 0.078, blue: 0.088)
  static let darkRaisedPanel = Color(red: 0.105, green: 0.108, blue: 0.118)

  static var brandGradient: LinearGradient {
    LinearGradient(
      colors: [accentWarm, accent, accentRed],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
  }
}

struct CinevaLogoMark: View {
  var size: CGFloat = 44

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        .fill(.white.opacity(0.98))

      CinevaTheme.brandGradient
        .mask {
          Image(systemName: "play.fill")
            .font(.system(size: size * 0.50, weight: .black))
            .offset(x: size * 0.025)
        }

      RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        .stroke(.black.opacity(0.06), lineWidth: 0.7)
    }
    .frame(width: size, height: size)
    .shadow(color: CinevaTheme.accent.opacity(0.24), radius: size * 0.20, y: size * 0.08)
  }
}
