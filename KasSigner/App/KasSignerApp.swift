import SwiftUI
import SwiftData

@main
struct KasSignerApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var walletStore = WalletStore()
    @StateObject private var engine = KasSignerEngine()
    @StateObject private var preferences = AppPreferences()
    @StateObject private var syncService = WalletSyncService()
    @StateObject private var liveRPCService = KaspaLiveRPCService()
    @StateObject private var coinControlStore = UTXOCoinControlStore()
    @StateObject private var priceService = PriceService.shared
    @StateObject private var appLockService = AppLockService()
    @StateObject private var copyFeedbackCenter = CopyFeedbackCenter()
    @StateObject private var protectedVaultStore = ProtectedVaultStore()

    var body: some Scene {
        WindowGroup {
            ZStack {
                AppSecurityContainer {
                    RootView()
                }

                if priceService.isPreparingInitialHistory {
                    HistoricalPricePreparationView(
                        startedAt: priceService.historicalPreparationStartedAt ?? Date()
                    )
                    .transition(.opacity)
                    .zIndex(3)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: priceService.isPreparingInitialHistory)
            .preferredColorScheme(preferredColorScheme)
            .environmentObject(walletStore)
            .environmentObject(engine)
            .environmentObject(preferences)
            .environmentObject(syncService)
            .environmentObject(liveRPCService)
            .environmentObject(coinControlStore)
            .environmentObject(priceService)
            .environmentObject(appLockService)
            .environmentObject(copyFeedbackCenter)
            .environmentObject(protectedVaultStore)
            .modelContainer(for: [PortfolioAccount.self, PortfolioTransaction.self])
            .alert("Wallet Settings", isPresented: Binding(
                get: { preferences.persistenceAlert != nil },
                set: { if !$0 { preferences.persistenceAlert = nil } }
            )) {
                Button("OK", role: .cancel) { preferences.persistenceAlert = nil }
            } message: {
                Text(preferences.persistenceAlert ?? "")
            }
            .task {
                coinControlStore.migrateExistingWallets(walletStore.profiles)
                _ = walletStore.resumePendingAccountDeletions { profileID in
                    WalletSnapshotCache.shared.remove(profileID: profileID)
                    coinControlStore.removeProfileSession(profileID: profileID)
                }
                for profile in walletStore.profiles {
                    _ = protectedVaultStore.registerWallet(profile)
                }
                await priceService.prepareHistoricalPrices()
                await priceService.refreshHistoricalPricesIfNeeded()
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                _ = walletStore.resumePendingAccountDeletions { profileID in
                    WalletSnapshotCache.shared.remove(profileID: profileID)
                    coinControlStore.removeProfileSession(profileID: profileID)
                }
            }
            .onChange(of: walletStore.profiles) { _, profiles in
                preferences.migrateExistingWallets(profiles)
                preferences.activate(walletStore.selectedProfile)
                for profile in profiles {
                    _ = protectedVaultStore.registerWallet(profile)
                }
            }
        }
    }

    private var preferredColorScheme: ColorScheme? {
        switch preferences.appearanceTheme {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

private struct HistoricalPricePreparationView: View {
    let startedAt: Date
    private let teal = Color(red: 0.20, green: 0.62, blue: 0.57)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { timeline in
            let fraction = min(1, max(0, timeline.date.timeIntervalSince(startedAt) / 5))
            ZStack {
                Color(uiColor: .systemBackground).ignoresSafeArea()
                VStack(spacing: 18) {
                    Text("Preparing Price History")
                        .font(.headline)
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(teal)
                        .frame(maxWidth: 240)
                    Text("Building the local portfolio chart cache")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(28)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Preparing local portfolio price history")
            .accessibilityValue(fraction.formatted(.percent.precision(.fractionLength(0))))
        }
    }
}

private struct AppSecurityContainer<Content: View>: View {
    @EnvironmentObject private var appLockService: AppLockService
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var syncService: WalletSyncService
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("kassigner.security.decoyLaunchScreenEnabled")
    private var decoyLaunchScreenEnabled = false
    @State private var privacyCoverUnlocked = false
    @State private var didAttemptAutomaticUnlock = false

    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            if appLockService.isEnabled &&
                decoyLaunchScreenEnabled &&
                !privacyCoverUnlocked &&
                !appLockService.isPrivacyCoverSuspendedForSession {
                WeatherCoverView {
                    if await appLockService.unlockFromPrivacyCover() {
                        privacyCoverUnlocked = true
                    }
                }
                .zIndex(2)
            } else {
                content
                    .allowsHitTesting(!appLockService.requiresForegroundAuthentication)
                    .accessibilityHidden(appLockService.requiresForegroundAuthentication)

                if shouldCoverContent {
                    Color(uiColor: .systemBackground)
                        .ignoresSafeArea()
                        .overlay {
                            if scenePhase == .active, appLockService.isLocked,
                               didAttemptAutomaticUnlock, !appLockService.isAuthenticating {
                                unlockRetryButton
                            }
                        }
                        .transaction { $0.animation = nil }
                        .zIndex(1)
                }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                syncService.persistObservedVirtualBlueScore()
                privacyCoverUnlocked = false
                didAttemptAutomaticUnlock = false
                appLockService.sceneDidEnterBackground()
            case .active:
                appLockService.sceneDidBecomeActive()
                Task { await automaticallyUnlockIfNeeded() }
            default:
                break
            }
        }
        .task {
            await automaticallyUnlockIfNeeded()
        }
        .onChange(of: appLockService.isAuthenticating) { _, authenticating in
            if !authenticating {
                // A backgrounded authentication may finish after reactivation.
                // Start the new session's prompt without reopening protected content.
                Task { await automaticallyUnlockIfNeeded() }
            }
        }
        .onChange(of: decoyLaunchScreenEnabled) { _, _ in
            // Enabling the cover from Security settings must not hide those
            // settings before the user finishes choosing the unlock gesture.
            // The cover takes effect after the app backgrounds or relaunches.
            privacyCoverUnlocked = true
        }
    }

    private func automaticallyUnlockIfNeeded() async {
        guard scenePhase == .active, appLockService.isLocked,
              !decoyLaunchScreenEnabled, !didAttemptAutomaticUnlock,
              !appLockService.isAuthenticating else { return }
        didAttemptAutomaticUnlock = true
        await appLockService.unlock()
    }

    private var shouldCoverContent: Bool {
        AppLockService.shouldCoverContent(
            needsAuthentication: appLockService.requiresForegroundAuthentication,
            hidePreview: preferences.hideAppSwitcherPreview, phase: scenePhase)
    }

    private var unlockRetryButton: some View {
        Button {
            Task { await appLockService.unlock() }
        } label: {
            Text("Unlock KasSigner")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(appLockService.isAuthenticating)
        .frame(maxWidth: 280)
        .padding()
    }
}
