import SwiftUI
import Combine
import UIKit

@main
struct Gallery115App: App {
  @Environment(\.scenePhase) private var scenePhase
  @State private var appState = AppState()
  @State private var foregroundAuthenticationInProgress = false

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
        .task {
          // scenePhase normally transitions to .active after the root view mounts,
          // but run the same guarded path for a cold launch that is already active.
          if scenePhase == .active {
            await handleForegroundActivation()
          }
        }
        .onChange(of: scenePhase) { _, phase in
          switch phase {
          case .active:
            Task { @MainActor in
              await handleForegroundActivation()
            }
          case .inactive:
            // Protect the app-switcher snapshot immediately, but do not change
            // the biometric lock state for Control Center / Notification Center.
            AppPrivacyShield.shared.show()
          case .background:
            // Keep the privacy glass visible while PiP continues on the Home Screen.
            // Face ID itself is deferred until the app becomes active again.
            AppPrivacyShield.shared.show()
            appState.lockForBackground()
          @unknown default:
            break
          }
        }
    }
  }

  @MainActor
  private func handleForegroundActivation() async {
    guard !foregroundAuthenticationInProgress else { return }
    foregroundAuthenticationInProgress = true
    defer { foregroundAuthenticationInProgress = false }

    // Convert a real background transition into the visible locked state while
    // the window-level frosted glass is STILL covering the app. This prevents a
    // single clear frame from appearing before Face ID is presented.
    appState.prepareForForegroundAuthentication()
    _ = await appState.authenticateIfNeeded()

    // Keep the privacy glass until SwiftUI has committed either the fully
    // unlocked hierarchy or the locked fallback after a cancelled/failed scan.
    await Task.yield()
    await Task.yield()
    AppPrivacyShield.shared.hide()
  }
}

@MainActor
private final class AppPrivacyShield {
  static let shared = AppPrivacyShield()

  private var shields: [ObjectIdentifier: UIView] = [:]

  private init() {}

  func show() {
    for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
      for window in scene.windows
      where !window.isHidden && window.alpha > 0 && window.windowLevel == .normal
      {
        let key = ObjectIdentifier(window)
        guard shields[key] == nil else { continue }

        let container = UIView(frame: window.bounds)
        container.translatesAutoresizingMaskIntoConstraints = false
        container.isUserInteractionEnabled = true
        container.accessibilityViewIsModal = true
        container.backgroundColor = .clear
        container.clipsToBounds = true

        // Freeze the current app frame first, then blur that frozen frame. Using
        // a snapshot behind the blur makes the app-switcher card look like real
        // frosted glass and prevents live content from briefly peeking through
        // while the scene is moving between active/background states.
        if let snapshot = window.snapshotView(afterScreenUpdates: false) {
          snapshot.translatesAutoresizingMaskIntoConstraints = false
          snapshot.isUserInteractionEnabled = false
          container.addSubview(snapshot)
          NSLayoutConstraint.activate([
            snapshot.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            snapshot.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            snapshot.topAnchor.constraint(equalTo: container.topAnchor),
            snapshot.bottomAnchor.constraint(equalTo: container.bottomAnchor),
          ])
        }

        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.isUserInteractionEnabled = false
        container.addSubview(blur)

        // A light veil raises privacy without turning the effect into an opaque
        // white/black plate; text and video remain visibly blurred underneath.
        let veil = UIView()
        veil.translatesAutoresizingMaskIntoConstraints = false
        veil.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.18)
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
    UIView.performWithoutAnimation {
      for shield in shields.values {
        shield.removeFromSuperview()
      }
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
