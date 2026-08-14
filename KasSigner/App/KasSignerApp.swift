import SwiftUI
import SwiftData

@main
struct KasSignerApp: App {
    @StateObject private var walletStore = WalletStore()
    @StateObject private var engine = KasSignerEngine()
    @StateObject private var preferences = AppPreferences()
    @StateObject private var syncService = WalletSyncService()
    @StateObject private var liveRPCService = KaspaLiveRPCService()
    @StateObject private var coinControlStore = UTXOCoinControlStore()
    @StateObject private var priceService = PriceService.shared
    @StateObject private var appLockService = AppLockService()
    @StateObject private var copyFeedbackCenter = CopyFeedbackCenter()

    var body: some Scene {
        WindowGroup {
            ZStack {
                AppSecurityContainer {
                    RootView()
                }

                if priceService.isPreparingInitialHistory {
                    HistoricalPricePreparationView(
                        progress: priceService.historicalPreparationProgress
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
            .modelContainer(for: [PortfolioAccount.self, PortfolioTransaction.self])
            .task {
                await priceService.prepareHistoricalPrices()
                await priceService.refreshHistoricalPricesIfNeeded()
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
    let progress: Double

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Text("Preparing Price History")
                    .font(.headline)

                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 240)

                Text("Building the local portfolio chart cache")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preparing local portfolio price history")
        .accessibilityValue(progress.formatted(.percent.precision(.fractionLength(0))))
    }
}

private struct AppSecurityContainer<Content: View>: View {
    @EnvironmentObject private var appLockService: AppLockService
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("kassigner.security.decoyLaunchScreenEnabled")
    private var decoyLaunchScreenEnabled = false
    @State private var privacyCoverUnlocked = false

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

                if shouldCoverContent {
                    Color(uiColor: .systemBackground)
                        .ignoresSafeArea()
                        .overlay {
                            if scenePhase == .active, appLockService.isLocked {
                                lockedView
                            }
                        }
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                privacyCoverUnlocked = false
                appLockService.sceneDidEnterBackground()
            case .active:
                appLockService.sceneDidBecomeActive()
                if appLockService.isLocked && !decoyLaunchScreenEnabled {
                    Task { await appLockService.unlock() }
                }
            default:
                break
            }
        }
        .task {
            if appLockService.isLocked && !decoyLaunchScreenEnabled {
                await appLockService.unlock()
            }
        }
        .onChange(of: decoyLaunchScreenEnabled) { _, _ in
            // Enabling the cover from Security settings must not hide those
            // settings before the user finishes choosing the unlock gesture.
            // The cover takes effect after the app backgrounds or relaunches.
            privacyCoverUnlocked = true
        }
    }

    private var shouldCoverContent: Bool {
        appLockService.isLocked ||
            (appLockService.hideAppSwitcherPreview && scenePhase != .active)
    }

    private var lockedView: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            Text("KasSigner Locked")
                .font(.title2.weight(.semibold))

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
        }
        .padding()
    }
}
