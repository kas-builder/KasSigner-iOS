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
        static let privacyCoverEnabled = "kassigner.security.decoyLaunchScreenEnabled"
    }

    @Published private(set) var isLocked = false
    @Published private(set) var isAuthenticating = false
    @Published private(set) var isPrivacyCoverSuspendedForSession = false
    @Published var authenticationError: String?

    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Key.isEnabled) }
    }

    @Published var lockDelay: LockDelay {
        didSet { defaults.set(lockDelay.rawValue, forKey: Key.lockDelay) }
    }

    private let defaults: UserDefaults
    private var backgroundedAt: Date?
    private let now: () -> Date
    private let authenticationEvaluator: ((String) async -> Bool)?
    private var authenticationGeneration: UInt64 = 0

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init,
         authenticationEvaluator: ((String) async -> Bool)? = nil) {
        self.defaults = defaults
        self.now = now
        self.authenticationEvaluator = authenticationEvaluator
        isEnabled = defaults.bool(forKey: Key.isEnabled)
        lockDelay = LockDelay(rawValue: defaults.string(forKey: Key.lockDelay) ?? "") ?? .immediately
        isLocked = isEnabled
        if !isEnabled {
            defaults.set(false, forKey: Key.privacyCoverEnabled)
        }
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
        let succeeded = await authenticate(
            reason: "Use \(biometricName) to enable App Lock."
        )
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
            defaults.set(false, forKey: Key.privacyCoverEnabled)
        }
        return succeeded
    }

    func unlock() async {
        guard isEnabled, isLocked else { return }
        let generation = authenticationGeneration
        if await authenticate(reason: "Unlock KasSigner"), generation == authenticationGeneration, isEnabled {
            isLocked = false
        }
    }

    func unlockFromPrivacyCover() async -> Bool {
        guard isEnabled else { return false }
        guard isLocked else { return true }
        let generation = authenticationGeneration
        let succeeded = await authenticate(reason: "Open protected content")
        guard generation == authenticationGeneration, isEnabled else { return false }
        if succeeded {
            isLocked = false
        }
        return succeeded
    }

    func authorizePrivacyCoverChange() async -> Bool {
        await authenticate(reason: "Change Privacy Cover settings")
    }

    func authorizeProtectedVaultCreation() async -> Bool {
        await authenticate(reason: "Confirm creation of this Protected Vault")
    }

    func authorizeProtectedVaultFunding() async -> Bool {
        await authenticate(reason: "Confirm funding this Protected Vault")
    }

    func authorizeTransactionBroadcast() async -> Bool {
        await authenticate(reason: "Authenticate to broadcast this transaction.")
    }

    func suspendPrivacyCoverForCurrentSession() {
        isPrivacyCoverSuspendedForSession = true
    }

    /// Also protects the first foreground frame after a delayed lock expires.
    var requiresForegroundAuthentication: Bool {
        guard isEnabled else { return false }
        if isLocked { return true }
        guard let backgroundedAt else { return false }
        return now().timeIntervalSince(backgroundedAt) >= lockDelay.interval
    }

    static func shouldCoverContent(needsAuthentication: Bool, hidePreview: Bool, phase: ScenePhase) -> Bool {
        (hidePreview && phase != .active) || (needsAuthentication && phase != .background)
    }

    func sceneDidEnterBackground() {
        authenticationGeneration &+= 1
        isPrivacyCoverSuspendedForSession = false
        backgroundedAt = now()
        if isEnabled, lockDelay == .immediately {
            isLocked = true
        }
    }

    func sceneDidBecomeActive() {
        guard isEnabled, let backgroundedAt else {
            backgroundedAt = nil
            return
        }
        if now().timeIntervalSince(backgroundedAt) >= lockDelay.interval {
            isLocked = true
        }
        self.backgroundedAt = nil
    }

    private func authenticate(
        policy: LAPolicy = .deviceOwnerAuthentication,
        reason: String
    ) async -> Bool {
        guard !isAuthenticating else { return false }
        isAuthenticating = true
        authenticationError = nil
        defer { isAuthenticating = false }

        if let authenticationEvaluator { return await authenticationEvaluator(reason) }
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"

        var error: NSError?
        guard context.canEvaluatePolicy(policy, error: &error) else {
            authenticationError = error?.localizedDescription ?? (
                policy == .deviceOwnerAuthenticationWithBiometrics
                    ? "Face ID or Touch ID is not available."
                    : "\(biometricName) or a device passcode is not available."
            )
            return false
        }

        do {
            return try await context.evaluatePolicy(
                policy,
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
