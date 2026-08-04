import Foundation

enum AppearanceTheme: String, CaseIterable, Identifiable {
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

enum KasBalanceDecimalPlaces: Int, CaseIterable, Identifiable {
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
}

enum ExplorerChoice: String, CaseIterable, Identifiable {
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

    func addressURL(_ address: String) -> URL {
        baseURL.appending(path: "addresses").appending(path: address)
    }

    func transactionURL(_ transactionID: String) -> URL {
        switch self {
        case .kaspaStream:
            return baseURL.appending(path: "transactions").appending(path: transactionID)
        case .kaspaExplorer:
            return baseURL.appending(path: "txs").appending(path: transactionID)
        }
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

enum SecondaryCurrency: String, CaseIterable, Identifiable {
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

enum PriceProviderChoice: String, CaseIterable, Identifiable {
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

@MainActor
final class AppPreferences: ObservableObject {
    @Published var appearanceTheme: AppearanceTheme { didSet { save() } }
    @Published var kasBalanceDecimalPlaces: KasBalanceDecimalPlaces { didSet { save() } }
    @Published var explorer: ExplorerChoice { didSet { save() } }
    @Published var nodeMode: NodeConnectionMode { didSet { save() } }
    @Published var customNodeURL: String { didSet { save() } }
    @Published var secondaryCurrency: SecondaryCurrency { didSet { save() } }
    @Published var priceProvider: PriceProviderChoice { didSet { save() } }

    private enum Key {
        static let appearanceTheme = "kassigner.appearanceTheme.v1"
        static let kasBalanceDecimalPlaces = "kassigner.kasBalanceDecimalPlaces.v1"
        static let explorer = "kassigner.explorer.v1"
        static let nodeMode = "kassigner.nodeMode.v1"
        static let customNode = "kassigner.customNode.v1"
        static let secondaryCurrency = "kassigner.secondaryCurrency.v1"
        static let priceProvider = "kassigner.priceProvider.v1"
    }

    init() {
        let defaults = UserDefaults.standard
        appearanceTheme = AppearanceTheme(
            rawValue: defaults.string(forKey: Key.appearanceTheme) ?? ""
        ) ?? .system
        kasBalanceDecimalPlaces = KasBalanceDecimalPlaces(
            rawValue: defaults.object(forKey: Key.kasBalanceDecimalPlaces) as? Int ?? 4
        ) ?? .four
        explorer = ExplorerChoice(rawValue: defaults.string(forKey: Key.explorer) ?? "") ?? .kaspaStream
        nodeMode = NodeConnectionMode(rawValue: defaults.string(forKey: Key.nodeMode) ?? "") ?? .automatic
        customNodeURL = defaults.string(forKey: Key.customNode) ?? ""
        secondaryCurrency = SecondaryCurrency(
            rawValue: defaults.string(forKey: Key.secondaryCurrency) ?? ""
        ) ?? .usd
        priceProvider = PriceProviderChoice(
            rawValue: defaults.string(forKey: Key.priceProvider) ?? ""
        ) ?? .automatic
    }

    var nodeConfiguration: [String: Any] {
        [
            "mode": nodeMode.rawValue,
            "customURL": customNodeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        ]
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(appearanceTheme.rawValue, forKey: Key.appearanceTheme)
        defaults.set(kasBalanceDecimalPlaces.rawValue, forKey: Key.kasBalanceDecimalPlaces)
        defaults.set(explorer.rawValue, forKey: Key.explorer)
        defaults.set(nodeMode.rawValue, forKey: Key.nodeMode)
        defaults.set(customNodeURL, forKey: Key.customNode)
        defaults.set(secondaryCurrency.rawValue, forKey: Key.secondaryCurrency)
        defaults.set(priceProvider.rawValue, forKey: Key.priceProvider)
    }
}
