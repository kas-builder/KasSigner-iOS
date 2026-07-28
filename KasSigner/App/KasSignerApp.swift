import SwiftUI

@main
struct KasSignerApp: App {
    @StateObject private var walletStore = WalletStore()
    @StateObject private var engine = KasSignerEngine()
    @StateObject private var preferences = AppPreferences()
    @StateObject private var syncService = WalletSyncService()
    @StateObject private var coinControlStore = UTXOCoinControlStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(walletStore)
                .environmentObject(engine)
                .environmentObject(preferences)
                .environmentObject(syncService)
                .environmentObject(coinControlStore)
        }
    }
}
