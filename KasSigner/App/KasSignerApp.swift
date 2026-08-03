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

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(preferredColorScheme)
                .environmentObject(walletStore)
                .environmentObject(engine)
                .environmentObject(preferences)
                .environmentObject(syncService)
                .environmentObject(liveRPCService)
                .environmentObject(coinControlStore)
                .environmentObject(priceService)
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
