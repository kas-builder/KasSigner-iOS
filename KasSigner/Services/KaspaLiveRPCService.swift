import Foundation

@MainActor
final class KaspaLiveRPCService: ObservableObject {
    enum State: Equatable {
        case idle
        case connecting
        case connected
        case reconnecting
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var notificationVersion = 0

    private struct Configuration: Equatable {
        let profileID: UUID
        let nodeURL: URL
        let addresses: [String]
    }

    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var notificationTask: Task<Void, Never>?
    private var configuration: Configuration?
    private var generation = UUID()
    private var reconnectAttempt = 0
    private var runtimeActive = true
    private var networkAvailable = true

    func configure(
        profile: WalletProfile,
        nodeURL: String,
        engine: KasSignerEngine
    ) async {
        let addresses = Array(Set(
            profile.receiveAddresses + profile.changeAddresses
        )).sorted()

        guard let url = URL(string: nodeURL),
              ["ws", "wss"].contains(url.scheme?.lowercased() ?? ""),
              !addresses.isEmpty
        else {
            stop(state: .failed("The resolved Kaspa node URL is invalid."))
            return
        }

        let next = Configuration(
            profileID: profile.id,
            nodeURL: url,
            addresses: addresses
        )

        guard next != configuration || socket == nil else { return }
        debugLog(
            "Configuring \(addresses.count) addresses on \(url.absoluteString)"
        )
        configuration = next
        reconnectAttempt = 0
        await connect(engine: engine, isReconnect: false)
    }

    func setRuntimeActive(_ active: Bool, engine: KasSignerEngine) async {
        runtimeActive = active

        if active {
            guard configuration != nil, socket == nil else { return }
            await connect(engine: engine, isReconnect: true)
        } else {
            disconnect(preservingConfiguration: true)
            state = .idle
        }
    }

    func setNetworkAvailable(_ available: Bool, engine: KasSignerEngine) async {
        guard networkAvailable != available else { return }
        networkAvailable = available

        if available {
            guard runtimeActive, configuration != nil else { return }
            debugLog("Network restored; reconnecting immediately")
            disconnect(preservingConfiguration: true)
            await connect(engine: engine, isReconnect: true)
        } else {
            debugLog("Network unavailable; suspending reconnect attempts")
            disconnect(preservingConfiguration: true)
            state = .failed("No internet connection.")
        }
    }

    func reset() {
        configuration = nil
        reconnectAttempt = 0
        stop(state: .idle)
    }

    private func connect(engine: KasSignerEngine, isReconnect: Bool) async {
        guard runtimeActive, networkAvailable, let configuration else { return }

        disconnect(preservingConfiguration: true)
        state = isReconnect ? .reconnecting : .connecting

        let connectionGeneration = generation
        let socket = URLSession.shared.webSocketTask(with: configuration.nodeURL)
        self.socket = socket
        debugLog(
            "\(isReconnect ? "Reconnecting" : "Connecting") to "
                + configuration.nodeURL.absoluteString
        )
        socket.resume()

        do {
            for (offset, address) in configuration.addresses.enumerated() {
                try Task.checkCancellation()
                guard generation == connectionGeneration else { return }

                let request = try await engine.buildUTXOSubscriptionRequest(
                    address: address,
                    requestID: UInt64(offset + 1)
                )
                try await socket.send(.data(request))
                debugLog(
                    "Sent subscription \(offset + 1)/"
                        + "\(configuration.addresses.count) (\(request.count) bytes)"
                )
            }

            guard generation == connectionGeneration else { return }
            reconnectAttempt = 0
            state = .connected
            debugLog("Native RPC stream connected and subscriptions sent")
            startReceiving(
                from: socket,
                generation: connectionGeneration,
                engine: engine
            )
        } catch is CancellationError {
            return
        } catch {
            guard generation == connectionGeneration else { return }
            handleDisconnect(error, engine: engine)
        }
    }

    private func startReceiving(
        from socket: URLSessionWebSocketTask,
        generation connectionGeneration: UUID,
        engine: KasSignerEngine
    ) {
        receiveTask?.cancel()
        receiveTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                while !Task.isCancelled,
                      self.generation == connectionGeneration {
                    let message = try await socket.receive()
                    guard self.generation == connectionGeneration else { return }
                    switch message {
                    case .data(let data):
                        self.debugLog("Received binary RPC frame (\(data.count) bytes)")
                    case .string(let text):
                        self.debugLog("Received text RPC frame (\(text.utf8.count) bytes)")
                    @unknown default:
                        self.debugLog("Received unknown RPC frame")
                    }
                    self.scheduleNotification()
                }
            } catch is CancellationError {
                return
            } catch {
                guard self.generation == connectionGeneration else { return }
                self.handleDisconnect(error, engine: engine)
            }
        }
    }

    private func handleDisconnect(_ error: Error, engine: KasSignerEngine) {
        disconnect(preservingConfiguration: true)

        guard runtimeActive, networkAvailable, configuration != nil else {
            state = .idle
            return
        }

        reconnectAttempt += 1
        state = .failed(error.localizedDescription)
        let delay = min(pow(2.0, Double(reconnectAttempt - 1)), 30.0)
        debugLog(
            "RPC stream failed: \(error.localizedDescription); retrying in \(delay)s"
        )

        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self,
                  !Task.isCancelled,
                  self.runtimeActive,
                  self.networkAvailable else { return }
            self.reconnectTask = nil
            await self.connect(engine: engine, isReconnect: true)
        }
    }

    private func scheduleNotification() {
        notificationTask?.cancel()
        notificationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled else { return }
            self.notificationVersion &+= 1
        }
    }

    private func stop(state: State) {
        disconnect(preservingConfiguration: false)
        self.state = state
    }

    private func disconnect(preservingConfiguration: Bool) {
        generation = UUID()
        receiveTask?.cancel()
        receiveTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        notificationTask?.cancel()
        notificationTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil

        if !preservingConfiguration {
            configuration = nil
        }
    }

    private func debugLog(_ message: String) {
#if DEBUG
        print("[KasSigner Live RPC] \(message)")
#endif
    }
}
