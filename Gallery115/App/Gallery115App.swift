import SwiftUI
import Combine
import UIKit

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
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
          // Install the window-level blur before iOS captures the app-switcher snapshot.
          // This is visual privacy only; Face ID remains untouched until .background.
          AppPrivacyShield.shared.show()
        }
        .onChange(of: scenePhase) { _, phase in
          switch phase {
          case .active:
            // If we really entered the background, convert the deferred lock
            // now—not while Picture in Picture is running on the Home Screen.
            // This keeps PiP uninterrupted but still guarantees Face ID when
            // the user returns to Cineva from PiP or from the Home Screen.
            appState.prepareForForegroundAuthentication()
            Task { @MainActor in
              // Give SwiftUI one turn to mount its locked/blurred presentation
              // before removing the window-level privacy glass.
              await Task.yield()
              AppPrivacyShield.shared.hide()
              await appState.authenticateIfNeeded()
            }
          case .inactive:
            // Only protect the system app-switcher snapshot here. Do not change
            // Face ID state for Control Center, Notification Center, permission
            // prompts, or other temporary inactive transitions.
            AppPrivacyShield.shared.show()
          case .background:
            AppPrivacyShield.shared.show()
            appState.lockForBackground()
          @unknown default:
            break
          }
        }
    }
  }
}

@MainActor
private final class AppPrivacyShield {
  static let shared = AppPrivacyShield()

  private var shields: [ObjectIdentifier: UIView] = [:]

  private init() {}

  func show() {
    for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
      for window in scene.windows where !window.isHidden && window.alpha > 0 {
        let key = ObjectIdentifier(window)
        guard shields[key] == nil else { continue }

        let container = UIView(frame: window.bounds)
        container.translatesAutoresizingMaskIntoConstraints = false
        container.isUserInteractionEnabled = true
        container.accessibilityViewIsModal = true

        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.isUserInteractionEnabled = false
        container.addSubview(blur)

        let veil = UIView()
        veil.translatesAutoresizingMaskIntoConstraints = false
        // A stronger frosted-glass veil keeps titles, thumbnails and video
        // frames unreadable in the app switcher without changing Cineva's UI.
        veil.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.32)
        veil.isUserInteractionEnabled = false
        container.addSubview(veil)

        window.addSubview(container)
        NSLayoutConstraint.activate([
          container.leadingAnchor.constraint(equalTo: window.leadingAnchor),
          container.trailingAnchor.constraint(equalTo: window.trailingAnchor),
          container.topAnchor.constraint(equalTo: window.topAnchor),
          container.bottomAnchor.constraint(equalTo: window.bottomAnchor),
          blur.leadingAnchor.constraint(equalTo: container.leadingAnchor),
          blur.trailingAnchor.constraint(equalTo: container.trailingAnchor),
          blur.topAnchor.constraint(equalTo: container.topAnchor),
          blur.bottomAnchor.constraint(equalTo: container.bottomAnchor),
          veil.leadingAnchor.constraint(equalTo: container.leadingAnchor),
          veil.trailingAnchor.constraint(equalTo: container.trailingAnchor),
          veil.topAnchor.constraint(equalTo: container.topAnchor),
          veil.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        shields[key] = container
      }
    }
  }

  func hide() {
    for shield in shields.values {
      shield.removeFromSuperview()
    }
    shields.removeAll()
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
