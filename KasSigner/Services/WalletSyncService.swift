import Foundation
import Network

@MainActor
final class WalletSnapshotCache {

    static let shared = WalletSnapshotCache()

    private let prefix = "kassigner.walletSnapshot.v1."

    private init() {}

    func load(profileID: UUID) -> WalletSyncPayload? {
        let key = prefix + profileID.uuidString

        guard
            let data = UserDefaults.standard.data(forKey: key),
            let snapshot = try? JSONDecoder().decode(WalletSyncPayload.self, from: data)
        else {
            return nil
        }

        return snapshot
    }

    func save(_ snapshot: WalletSyncPayload, profileID: UUID) {
        guard let data = try? JSONEncoder().encode(snapshot) else {
            return
        }

        UserDefaults.standard.set(
            data,
            forKey: prefix + profileID.uuidString
        )
    }

    func remove(profileID: UUID) {
        UserDefaults.standard.removeObject(
            forKey: prefix + profileID.uuidString
        )
    }
}

@MainActor
final class WalletSyncService: ObservableObject {
    enum State: Equatable {
        case idle
        case syncing
        case connected
        case failed(String)

        var title: String {
            switch self {
            case .idle: "Ready"
            case .syncing: "Connecting..."
            case .connected: "Connected"
            case .failed: "No connection"
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var snapshot: WalletSyncPayload?
    @Published private(set) var feeEstimate: FeeEstimate?
    @Published private(set) var isNetworkAvailable = true

    private var activeProfileID: UUID?
    private var lastRefreshAttempt: Date?
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "org.kassigner.KasSigner.network-monitor")

    func preload(profile: WalletProfile) {
        guard activeProfileID != profile.id else { return }

        activeProfileID = profile.id
        lastRefreshAttempt = nil
        state = isNetworkAvailable ? .idle : .failed("No internet connection.")

        snapshot = WalletSnapshotCache.shared.load(profileID: profile.id)
    }

    init() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wasAvailable = self.isNetworkAvailable
                self.isNetworkAvailable = path.status == .satisfied
                if path.status != .satisfied {
                    self.state = .failed("No internet connection.")
                } else if !wasAvailable {
                    self.state = .idle
                }
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    func refresh(
        profile: WalletProfile,
        walletStore: WalletStore,
        engine: KasSignerEngine,
        preferences: AppPreferences,
        force: Bool = true,
        minimumInterval: TimeInterval = 9
    ) async {
        guard isNetworkAvailable else {
            state = .failed("No internet connection.")
            return
        }

        if case .syncing = state { return }

        if !force,
           activeProfileID == profile.id,
           let lastRefreshAttempt,
           Date().timeIntervalSince(lastRefreshAttempt) < minimumInterval {
            return
        }

        activeProfileID = profile.id

        if snapshot == nil,
           let cached = WalletSnapshotCache.shared.load(profileID: profile.id) {
            snapshot = cached
        }

        lastRefreshAttempt = Date()
        state = .syncing

        do {
            let (result, discoveredProfile) = try await syncWithAddressDiscovery(
                profile: walletStore.profiles.first(where: { $0.id == profile.id })
                    ?? profile,
                walletStore: walletStore,
                engine: engine,
                preferences: preferences
            )
            guard activeProfileID == profile.id else { return }
            if discoveredProfile != profile {
                walletStore.update(discoveredProfile)
                walletStore.setLastViewedReceiveIndex(
                    discoveredProfile.nextReceiveIndex,
                    for: discoveredProfile.id,
                    addressCount: discoveredProfile.receiveAddresses.count
                )
            }
            snapshot = result
            do {
                feeEstimate = try await engine.getFeeEstimate(
                    nodeConfiguration: preferences.nodeConfiguration
                )
            } catch {
                // Preserve the last valid estimate if a refresh temporarily fails.
            }

            WalletSnapshotCache.shared.save(
                result,
                profileID: profile.id
            )
            state = .connected
        } catch {
            guard activeProfileID == profile.id else { return }
            state = .failed(friendlyMessage(for: error, preferences: preferences))
        }
    }

    private func syncWithAddressDiscovery(
        profile: WalletProfile,
        walletStore: WalletStore,
        engine: KasSignerEngine,
        preferences: AppPreferences
    ) async throws -> (WalletSyncPayload, WalletProfile) {
        let gapLimit = 8
        let derivationBatch = 8
        let maximumAddressesPerChain = 512
        var current = profile

        for _ in 0..<64 {
            try Task.checkCancellation()

            let result = try await engine.syncWallet(
                current,
                nodeConfiguration: preferences.nodeConfiguration
            )

            if let lastFundedReceive = result.balance.fundedReceiveIndices.max() {
                current.nextReceiveIndex = max(
                    current.nextReceiveIndex,
                    lastFundedReceive + 1
                )
            }
            if let lastFundedChange = result.balance.fundedChangeIndices.max() {
                current.nextChangeIndex = max(
                    current.nextChangeIndex,
                    lastFundedChange + 1
                )
            }

            let receiveBoundary = max(
                0,
                current.receiveAddresses.count - gapLimit
            )
            let changeBoundary = max(
                0,
                current.changeAddresses.count - gapLimit
            )
            let receiveNeedsExtension =
                current.receiveAddresses.count < maximumAddressesPerChain
                && (
                    current.nextReceiveIndex >= receiveBoundary
                    || result.balance.fundedReceiveIndices.contains {
                        $0 >= receiveBoundary
                    }
                )
            let changeNeedsExtension =
                current.changeAddresses.count < maximumAddressesPerChain
                && (
                    current.nextChangeIndex >= changeBoundary
                    || result.balance.fundedChangeIndices.contains {
                        $0 >= changeBoundary
                    }
                )

            if !receiveNeedsExtension && !changeNeedsExtension {
                return (result, current)
            }

            let receiveCount = receiveNeedsExtension
                ? min(
                    derivationBatch,
                    maximumAddressesPerChain - current.receiveAddresses.count
                )
                : 0
            let changeCount = changeNeedsExtension
                ? min(
                    derivationBatch,
                    maximumAddressesPerChain - current.changeAddresses.count
                )
                : 0

            guard receiveCount > 0 || changeCount > 0 else {
                return (result, current)
            }

            let derived = try await engine.extendAddresses(
                for: current,
                receiveCount: receiveCount,
                changeCount: changeCount
            )
            current.receiveAddresses = derived.receiveAddresses
            current.changeAddresses = derived.changeAddresses
            walletStore.update(current)
            walletStore.setLastViewedReceiveIndex(
                current.nextReceiveIndex,
                for: current.id,
                addressCount: current.receiveAddresses.count
            )

            await Task.yield()
        }

        throw KasSignerEngine.EngineError.javascript(
            "Address discovery exceeded its safety limit."
        )
    }

    func reset() {
        activeProfileID = nil
        lastRefreshAttempt = nil
        snapshot = nil
        feeEstimate = nil
        state = isNetworkAvailable ? .idle : .failed("No internet connection.")
    }

    private func friendlyMessage(for error: Error, preferences: AppPreferences) -> String {
        let message = error.localizedDescription.lowercased()

        if !isNetworkAvailable {
            return "No internet connection."
        }

        if preferences.nodeMode == .custom {
            if preferences.customNodeURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Enter a custom Kaspa node URL in Settings."
            }
            if message.contains("wss://") || message.contains("ws://") {
                return "The custom node URL is invalid. Use a ws:// or wss:// address."
            }
            return "Unable to connect to your custom Kaspa node. Check its address and availability."
        }

        return "Unable to reach the Kaspa network. Check your internet connection and try again."
    }
}
