import LocalAuthentication
import SwiftUI

@MainActor
final class AppLockService: ObservableObject {
    enum LockDelay: String, CaseIterable, Identifiable {
        case immediately
        case oneMinute
        case fiveMinutes

        var id: String { rawValue }

        var title: String {
            switch self {
            case .immediately: "Immediately"
            case .oneMinute: "After 1 Minute"
            case .fiveMinutes: "After 5 Minutes"
            }
        }

        var interval: TimeInterval {
            switch self {
            case .immediately: 0
            case .oneMinute: 60
            case .fiveMinutes: 300
            }
        }
    }

    private enum Key {
        static let isEnabled = "kassigner.security.appLockEnabled"
        static let lockDelay = "kassigner.security.lockDelay"
        static let hideAppSwitcherPreview = "kassigner.security.hideAppSwitcherPreview"
    }

    @Published private(set) var isLocked = false
    @Published private(set) var isAuthenticating = false
    @Published var authenticationError: String?

    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Key.isEnabled) }
    }

    @Published var lockDelay: LockDelay {
        didSet { defaults.set(lockDelay.rawValue, forKey: Key.lockDelay) }
    }

    @Published var hideAppSwitcherPreview: Bool {
        didSet { defaults.set(hideAppSwitcherPreview, forKey: Key.hideAppSwitcherPreview) }
    }

    private let defaults: UserDefaults
    private var backgroundedAt: Date?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Key.isEnabled)
        lockDelay = LockDelay(rawValue: defaults.string(forKey: Key.lockDelay) ?? "") ?? .immediately
        hideAppSwitcherPreview = defaults.object(forKey: Key.hideAppSwitcherPreview) as? Bool ?? true
        isLocked = isEnabled
    }

    var biometricName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return switch context.biometryType {
        case .faceID: "Face ID"
        case .touchID: "Touch ID"
        default: "Biometrics"
        }
    }

    func enableAppLock() async -> Bool {
        let succeeded = await authenticate(reason: "Use Face ID to enable App Lock.")
        if succeeded {
            isEnabled = true
            isLocked = false
        }
        return succeeded
    }

    func disableAppLock() async -> Bool {
        let succeeded = await authenticate(reason: "Authenticate to turn off App Lock.")
        if succeeded {
            isEnabled = false
            isLocked = false
        }
        return succeeded
    }

    func unlock() async {
        guard isEnabled, isLocked else { return }
        if await authenticate(reason: "Unlock KasSigner") {
            isLocked = false
        }
    }

    func sceneDidEnterBackground() {
        backgroundedAt = Date()
        if isEnabled, lockDelay == .immediately {
            isLocked = true
        }
    }

    func sceneDidBecomeActive() {
        guard isEnabled, let backgroundedAt else {
            backgroundedAt = nil
            return
        }
        if Date().timeIntervalSince(backgroundedAt) >= lockDelay.interval {
            isLocked = true
        }
        self.backgroundedAt = nil
    }

    private func authenticate(reason: String) async -> Bool {
        guard !isAuthenticating else { return false }
        isAuthenticating = true
        authenticationError = nil
        defer { isAuthenticating = false }

        let context = LAContext()
        context.localizedCancelTitle = "Cancel"

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            authenticationError = error?.localizedDescription ?? "Face ID or a device passcode is not available."
            return false
        }

        do {
            return try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            )
        } catch {
            let code = LAError.Code(rawValue: (error as NSError).code)
            if code != .userCancel && code != .appCancel && code != .systemCancel {
                authenticationError = error.localizedDescription
            }
            return false
        }
    }
}
