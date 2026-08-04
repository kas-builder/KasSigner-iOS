import SwiftUI

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
            AppSecurityContainer {
                RootView()
            }
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

private struct AppSecurityContainer<Content: View>: View {
    @EnvironmentObject private var appLockService: AppLockService
    @Environment(\.scenePhase) private var scenePhase

    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
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
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                appLockService.sceneDidEnterBackground()
            case .active:
                appLockService.sceneDidBecomeActive()
                if appLockService.isLocked {
                    Task { await appLockService.unlock() }
                }
            default:
                break
            }
        }
        .task {
            if appLockService.isLocked {
                await appLockService.unlock()
            }
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
