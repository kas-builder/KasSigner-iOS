import Foundation

enum KaspaNetwork: String, CaseIterable, Identifiable {
    case mainnet
    case testnet10 = "testnet-10"

    var id: String { rawValue }
    var title: String { self == .mainnet ? "Mainnet" : "Testnet 10" }
    var addressPrefix: String { self == .mainnet ? "kaspa:" : "kaspatest:" }
    var currencySymbol: String { self == .mainnet ? "KAS" : "TKAS" }
}

enum AppearanceTheme: String, Codable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

enum KasBalanceDecimalPlaces: Int, Codable, CaseIterable, Identifiable {
    case zero = 0
    case one = 1
    case two = 2
    case three = 3
    case four = 4

    var id: Int { rawValue }
    var title: String { String(rawValue) }
}

enum KasBalanceFormatter {
    static func string(
        from amount: Double,
        decimalPlaces: KasBalanceDecimalPlaces
    ) -> String {
        amount.formatted(
            .number.precision(.fractionLength(decimalPlaces.rawValue))
        )
    }

    static func string(
        fromSompi sompi: UInt64,
        decimalPlaces: KasBalanceDecimalPlaces
    ) -> String {
        string(
            from: Double(sompi) / 100_000_000,
            decimalPlaces: decimalPlaces
        )
    }
}

enum ExplorerChoice: String, Codable, CaseIterable, Identifiable {
    case kaspaStream
    case kaspaExplorer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .kaspaStream: "Kaspa.stream"
        case .kaspaExplorer: "Kaspa Explorer"
        }
    }

    var baseURL: URL {
        switch self {
        case .kaspaStream: URL(string: "https://kaspa.stream")!
        case .kaspaExplorer: URL(string: "https://explorer.kaspa.org")!
        }
    }

    func addressURL(_ address: String, network: KaspaNetwork = .mainnet) -> URL {
        explorerURL(for: network).appending(path: "addresses").appending(path: address)
    }

    func transactionURL(_ transactionID: String, network: KaspaNetwork = .mainnet) -> URL {
        switch self {
        case .kaspaStream:
            return explorerURL(for: network).appending(path: "transactions").appending(path: transactionID)
        case .kaspaExplorer:
            return explorerURL(for: network).appending(path: "txs").appending(path: transactionID)
        }
    }

    private func explorerURL(for network: KaspaNetwork) -> URL {
        guard network == .testnet10 else { return baseURL }
        switch self {
        case .kaspaStream: return URL(string: "https://tn10.kaspa.stream")!
        case .kaspaExplorer: return URL(string: "https://explorer-tn10.kaspa.org")!
        }
    }
}

enum AddressStatusDisplayMode: String, Codable, CaseIterable, Identifiable {
    case off
    case iconOnly
    case iconAndText

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .iconOnly: "Icon Only"
        case .iconAndText: "Icon and Text"
        }
    }

    var isEnabled: Bool {
        self != .off
    }
}

enum NodeConnectionMode: String, CaseIterable, Identifiable {
    case automatic
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic Nodes"
        case .custom: "Custom Node"
        }
    }
}

enum SecondaryCurrency: String, Codable, CaseIterable, Identifiable {
    case usd
    case btc

    var id: String { rawValue }

    var title: String {
        rawValue.uppercased()
    }

    var displayName: String {
        switch self {
        case .usd: "US Dollar"
        case .btc: "Bitcoin"
        }
    }
}

enum PriceProviderChoice: String, Codable, CaseIterable, Identifiable {
    case automatic
    case coinGecko
    case coinPaprika

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .coinGecko: "CoinGecko"
        case .coinPaprika: "CoinPaprika"
        }
    }
}

enum UTXOCardDefault: String, Codable, CaseIterable, Identifiable {
    case off
    case kyc
    case nonKYC

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .kyc: "KYC"
        case .nonKYC: "Non-KYC"
        }
    }

    var badgeStatus: UTXOKYCStatus? {
        switch self {
        case .off: nil
        case .kyc: .kyc
        case .nonKYC: .nonKYC
        }
    }
}

struct WalletPreferences: Codable, Equatable {
    var appearanceTheme: AppearanceTheme = .dark
    var kasBalanceDecimalPlaces: KasBalanceDecimalPlaces = .three
    var explorer: ExplorerChoice = .kaspaStream
    var showsGraphColors = true
    var utxoCardDefault: UTXOCardDefault = .off
    var addressStatusDisplayMode: AddressStatusDisplayMode = .iconAndText
    var secondaryCurrency: SecondaryCurrency = .usd
    var priceProvider: PriceProviderChoice = .automatic
    var showsCurrencyConverterInWallet = false
    var opensToFreshAddress = true
    // Optional for records written before preview privacy became wallet-specific.
    var hideAppSwitcherPreview: Bool? = true
}

struct SavedWalletPreferences: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    let network: String
    var preferences: WalletPreferences
}

private struct WalletPreferencesDocument: Codable {
    var migrated = false
    var wallets: [String: SavedWalletPreferences] = [:]
}

@MainActor
final class AppPreferences: ObservableObject {
    @Published var network: KaspaNetwork { didSet { saveGlobal() } }
    @Published var appearanceTheme: AppearanceTheme { didSet { saveWallet() } }
    @Published var kasBalanceDecimalPlaces: KasBalanceDecimalPlaces { didSet { saveWallet() } }
    @Published var explorer: ExplorerChoice { didSet { saveWallet() } }
    @Published var showsGraphColors: Bool { didSet { saveWallet() } }
    @Published var utxoCardDefault: UTXOCardDefault { didSet { saveWallet() } }
    @Published var addressStatusDisplayMode: AddressStatusDisplayMode { didSet { saveWallet() } }
    @Published var nodeMode: NodeConnectionMode { didSet { saveGlobal() } }
    @Published var customNodeURL: String { didSet { saveGlobal() } }
    @Published var secondaryCurrency: SecondaryCurrency { didSet { saveWallet() } }
    @Published var priceProvider: PriceProviderChoice { didSet { saveWallet() } }
    @Published var showsCurrencyConverterInWallet: Bool { didSet { saveWallet() } }

    @Published var opensToFreshAddress = true { didSet { saveWallet() } }
    @Published var hideAppSwitcherPreview = true { didSet { saveWallet() } }
    @Published var persistenceAlert: String?
    @Published private(set) var savedWallets: [SavedWalletPreferences] = []
    private(set) var activeWalletIdentity: String?
    private let defaults: UserDefaults
    private let storage: ProtectedWalletStorage
    private let fileName = "wallet-preferences-v1.json"
    private var document = WalletPreferencesDocument()
    private var storageAvailable = true
    private var applying = false
    private var legacyPreferences = WalletPreferences()

    private enum Key {
        static let network = "kassigner.network.v1"
        static let appearanceTheme = "kassigner.appearanceTheme.v1"
        static let kasBalanceDecimalPlaces = "kassigner.kasBalanceDecimalPlaces.v1"
        static let explorer = "kassigner.explorer.v1"
        static let showsGraphColors = "kassigner.showsGraphColors.v1"
        static let utxoCardDefault = "kassigner.utxoCardDefault.v1"
        static let addressStatusEnabled = "kassigner.addressStatusEnabled.v1"
        static let addressStatusDisplayMode = "kassigner.addressStatusDisplayMode.v2"
        static let nodeMode = "kassigner.nodeMode.v1"
        static let customNode = "kassigner.customNode.v1"
        static let secondaryCurrency = "kassigner.secondaryCurrency.v1"
        static let priceProvider = "kassigner.priceProvider.v1"
        static let showsCurrencyConverterInWallet = "kassigner.showsCurrencyConverterInWallet.v1"
    }

    init(defaults: UserDefaults = .standard, storage: ProtectedWalletStorage = .shared) {
        self.defaults = defaults
        self.storage = storage
        network = KaspaNetwork(rawValue: defaults.string(forKey: Key.network) ?? "") ?? .mainnet
        appearanceTheme = AppearanceTheme(
            rawValue: defaults.string(forKey: Key.appearanceTheme) ?? ""
        ) ?? .system
        kasBalanceDecimalPlaces = KasBalanceDecimalPlaces(
            rawValue: defaults.object(forKey: Key.kasBalanceDecimalPlaces) as? Int ?? 4
        ) ?? .four
        explorer = ExplorerChoice(rawValue: defaults.string(forKey: Key.explorer) ?? "") ?? .kaspaStream
        showsGraphColors = defaults.object(forKey: Key.showsGraphColors) as? Bool ?? true
        utxoCardDefault = UTXOCardDefault(
            rawValue: defaults.string(forKey: Key.utxoCardDefault) ?? ""
        ) ?? .off
        if let storedMode = defaults.string(forKey: Key.addressStatusDisplayMode),
           let displayMode = AddressStatusDisplayMode(rawValue: storedMode) {
            addressStatusDisplayMode = displayMode
        } else {
            let wasEnabled = defaults.object(forKey: Key.addressStatusEnabled) as? Bool ?? true
            addressStatusDisplayMode = wasEnabled ? .iconAndText : .off
        }
        nodeMode = NodeConnectionMode(rawValue: defaults.string(forKey: Key.nodeMode) ?? "") ?? .automatic
        customNodeURL = defaults.string(forKey: Key.customNode) ?? ""
        secondaryCurrency = SecondaryCurrency(
            rawValue: defaults.string(forKey: Key.secondaryCurrency) ?? ""
        ) ?? .usd
        priceProvider = PriceProviderChoice(
            rawValue: defaults.string(forKey: Key.priceProvider) ?? ""
        ) ?? .automatic
        showsCurrencyConverterInWallet = defaults.object(
            forKey: Key.showsCurrencyConverterInWallet
        ) as? Bool ?? false
        opensToFreshAddress = defaults.object(forKey: "kassigner.receive.openToFreshAddress.v1") as? Bool ?? true
        hideAppSwitcherPreview = defaults.object(forKey: "kassigner.security.hideAppSwitcherPreview") as? Bool ?? true
        legacyPreferences = currentWalletPreferences
        do {
            document = try storage.loadIfPresent(WalletPreferencesDocument.self, fileName: fileName)
                ?? WalletPreferencesDocument()
            publishSavedWallets()
        } catch {
            storageAvailable = false
            persistenceAlert = "Saved wallet settings could not be read. Changes are disabled to protect your saved settings. Reopen the app after checking device storage."
        }
        apply(WalletPreferences())
    }

    var nodeConfiguration: [String: Any] {
        [
            "network": network.rawValue,
            "mode": activeNodeMode.rawValue,
            "customURL": activeCustomNodeURL
        ]
    }

    // Mainnet's saved custom node must never be reused for Testnet 10.
    var activeNodeMode: NodeConnectionMode {
        network == .testnet10 ? .automatic : nodeMode
    }

    var activeCustomNodeURL: String {
        network == .testnet10 ? "" : customNodeURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Run once against all existing profiles, before activating a pending import.
    func migrateExistingWallets(_ profiles: [WalletProfile]) {
        guard storageAvailable, !document.migrated else { return }
        var updated = document
        for profile in profiles where updated.wallets[profile.stableIdentity] == nil {
            updated.wallets[profile.stableIdentity] = SavedWalletPreferences(
                id: profile.stableIdentity, name: profile.name, network: profile.network,
                preferences: legacyPreferences
            )
        }
        updated.migrated = true
        _ = commit(updated)
    }

    func activate(_ profile: WalletProfile?) {
        activeWalletIdentity = profile?.stableIdentity
        guard let profile else {
            apply(WalletPreferences())
            return
        }
        guard storageAvailable, document.migrated else {
            apply(document.wallets[profile.stableIdentity]?.preferences ?? legacyPreferences)
            return
        }
        if var record = document.wallets[profile.stableIdentity] {
            apply(record.preferences)
            if record.name != profile.name {
                record.name = profile.name
                var updated = document
                updated.wallets[record.id] = record
                _ = commit(updated)
            }
        } else {
            apply(WalletPreferences())
            var updated = document
            updated.wallets[profile.stableIdentity] = SavedWalletPreferences(
                id: profile.stableIdentity, name: profile.name, network: profile.network,
                preferences: currentWalletPreferences
            )
            _ = commit(updated)
        }
    }

    @discardableResult
    func forgetSavedSettings(identity: String) -> Bool {
        guard storageAvailable, document.migrated else { return false }
        var updated = document
        updated.wallets.removeValue(forKey: identity)
        guard commit(updated) else { return false }
        if activeWalletIdentity == identity { apply(WalletPreferences()) }
        return true
    }

    private var currentWalletPreferences: WalletPreferences {
        WalletPreferences(
            appearanceTheme: appearanceTheme, kasBalanceDecimalPlaces: kasBalanceDecimalPlaces,
            explorer: explorer, showsGraphColors: showsGraphColors, utxoCardDefault: utxoCardDefault,
            addressStatusDisplayMode: addressStatusDisplayMode, secondaryCurrency: secondaryCurrency,
            priceProvider: priceProvider, showsCurrencyConverterInWallet: showsCurrencyConverterInWallet,
            opensToFreshAddress: opensToFreshAddress,
            hideAppSwitcherPreview: hideAppSwitcherPreview
        )
    }

    private func apply(_ value: WalletPreferences) {
        applying = true
        defer { applying = false }
        appearanceTheme = value.appearanceTheme
        kasBalanceDecimalPlaces = value.kasBalanceDecimalPlaces
        explorer = value.explorer
        showsGraphColors = value.showsGraphColors
        utxoCardDefault = value.utxoCardDefault
        addressStatusDisplayMode = value.addressStatusDisplayMode
        secondaryCurrency = value.secondaryCurrency
        priceProvider = value.priceProvider
        showsCurrencyConverterInWallet = value.showsCurrencyConverterInWallet
        opensToFreshAddress = value.opensToFreshAddress
        hideAppSwitcherPreview = value.hideAppSwitcherPreview
            ?? legacyPreferences.hideAppSwitcherPreview ?? true
    }

    private func saveWallet() {
        guard !applying, let identity = activeWalletIdentity else { return }
        guard storageAvailable, document.migrated, var record = document.wallets[identity] else {
            apply(document.wallets[identity]?.preferences ?? WalletPreferences())
            persistenceAlert = "Your wallet settings could not be saved. Reopen the app after checking device storage."
            return
        }
        let previous = record.preferences
        record.preferences = currentWalletPreferences
        var updated = document
        updated.wallets[identity] = record
        if !commit(updated) { apply(previous) }
    }

    private func commit(_ updated: WalletPreferencesDocument) -> Bool {
        guard storageAvailable, storage.save(updated, fileName: fileName) else {
            persistenceAlert = "Your wallet settings could not be saved. The previous settings remain selected. Check device storage and try again."
            return false
        }
        document = updated
        publishSavedWallets()
        return true
    }

    private func publishSavedWallets() {
        savedWallets = document.wallets.values.sorted {
            if $0.name == $1.name { return $0.id < $1.id }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func saveGlobal() {
        defaults.set(network.rawValue, forKey: Key.network)
        defaults.set(nodeMode.rawValue, forKey: Key.nodeMode)
        defaults.set(customNodeURL, forKey: Key.customNode)
    }
}
