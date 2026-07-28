import Foundation

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
        case .automatic: "Automatic Public Nodes"
        case .custom: "Custom Node"
        }
    }
}

@MainActor
final class AppPreferences: ObservableObject {
    @Published var explorer: ExplorerChoice { didSet { save() } }
    @Published var nodeMode: NodeConnectionMode { didSet { save() } }
    @Published var customNodeURL: String { didSet { save() } }

    private enum Key {
        static let explorer = "kassigner.explorer.v1"
        static let nodeMode = "kassigner.nodeMode.v1"
        static let customNode = "kassigner.customNode.v1"
    }

    init() {
        let defaults = UserDefaults.standard
        explorer = ExplorerChoice(rawValue: defaults.string(forKey: Key.explorer) ?? "") ?? .kaspaStream
        nodeMode = NodeConnectionMode(rawValue: defaults.string(forKey: Key.nodeMode) ?? "") ?? .automatic
        customNodeURL = defaults.string(forKey: Key.customNode) ?? ""
    }

    var nodeConfiguration: [String: Any] {
        [
            "mode": nodeMode.rawValue,
            "customURL": customNodeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        ]
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(explorer.rawValue, forKey: Key.explorer)
        defaults.set(nodeMode.rawValue, forKey: Key.nodeMode)
        defaults.set(customNodeURL, forKey: Key.customNode)
    }
}
