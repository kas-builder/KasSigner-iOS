import SwiftUI

struct KasSignerLoadingView: View {
    var size: CGFloat = 22
    var lineWidth: CGFloat = 3

    @State private var isRotating = false

    private let teal = Color(red: 0.18, green: 0.68, blue: 0.62)

    var body: some View {
        Circle()
            .trim(from: 0.08, to: 0.82)
            .stroke(
                teal,
                style: StrokeStyle(
                    lineWidth: lineWidth,
                    lineCap: .round
                )
            )
            .frame(width: size, height: size)
            .rotationEffect(.degrees(isRotating ? 360 : 0))
            .animation(
                .linear(duration: 0.7)
                    .repeatForever(autoreverses: false),
                value: isRotating
            )
            .onAppear {
                isRotating = true
            }
            .accessibilityLabel("Loading")
    }
}

struct RootView: View {
    private enum Tab: Hashable {
        case wallet
        case activity
        case utxos
        case settings
    }

    @EnvironmentObject private var walletStore: WalletStore
    @EnvironmentObject private var engine: KasSignerEngine
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var syncService: WalletSyncService
    @Environment(\.scenePhase) private var scenePhase

    @State private var selectedTab: Tab = .wallet

    var body: some View {
        TabView(selection: $selectedTab) {
            WalletHomeView()
                .tag(Tab.wallet)
                .tabItem { Label("Wallet", systemImage: "wallet.pass") }

            ActivityView()
                .tag(Tab.activity)
                .tabItem { Label("Activity", systemImage: "clock.arrow.circlepath") }

            UTXOsView()
                .tag(Tab.utxos)
                .tabItem { Label("UTXOs", systemImage: "square.stack.3d.up") }

            SettingsView {
                selectedTab = .wallet
            }
                .tag(Tab.settings)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(Color(red: 0.20, green: 0.62, blue: 0.57))
        .task(id: launchRefreshTaskID) {
            await refreshAfterLaunchOrActivation()
        }
    }

    private var launchRefreshTaskID: String {
        let profileID = walletStore.selectedProfileID?.uuidString ?? "no-profile"
        let phase = scenePhase == .active ? "active" : "inactive"
        return "\(profileID)-\(phase)"
    }

    private func refreshAfterLaunchOrActivation() async {
        guard scenePhase == .active,
              let profile = walletStore.selectedProfile else { return }

        engine.startIfNeeded()

        // Let the first frame and tab bar become interactive before any
        // WebKit or network synchronization work begins under Xcode.
        try? await Task.sleep(for: .milliseconds(0))
        guard !Task.isCancelled else { return }

        await syncService.refresh(
            profile: profile,
            engine: engine,
            preferences: preferences,
            force: false,
            minimumInterval: 9
        )
    }
}

struct UTXOsView: View {
    @EnvironmentObject private var walletStore: WalletStore
    @EnvironmentObject private var engine: KasSignerEngine
    @EnvironmentObject private var syncService: WalletSyncService
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var coinControlStore: UTXOCoinControlStore
    @Environment(\.openURL) private var openURL

    @StateObject private var confirmationStore = UTXOConfirmationStore()
    @State private var editingLabelUTXOID: String?
    @State private var draftLabel = ""
    @State private var isLabelEditorPresented = false
    @State private var knownUTXOIDs: Set<String> = []
    @State private var newlyArrivedUTXOIDs: Set<String> = []

    @FocusState private var labelEditorFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if walletStore.selectedProfile == nil {
                    ContentUnavailableView(
                        "No Account",
                        systemImage: "wallet.pass",
                        description: Text("Add and select an account before viewing UTXOs.")
                    )
                } else if syncService.snapshot == nil {
                    ContentUnavailableView(
                        "No UTXO Data",
                        systemImage: "square.stack.3d.up.slash",
                        description: Text("Refresh the wallet to load its current UTXOs.")
                    )
                } else if utxos.isEmpty {
                    ContentUnavailableView(
                        "No UTXOs",
                        systemImage: "square.stack.3d.up",
                        description: Text("This account currently has no spendable outputs.")
                    )
                } else {
                    VStack(spacing: 0) {
                        ScrollView {
                            LazyVStack(spacing: 10) {
                                ForEach(utxos) { utxo in
                                    utxoCard(utxo, isNew: newlyArrivedUTXOIDs.contains(utxo.id))
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.bottom, 20)
                        }
                        .refreshable {
                            await refreshUTXOs()
                        }
                        .scrollDismissesKeyboard(.interactively)
                    }
                    .background(Color(.systemGroupedBackground))
                }
            }
            .navigationTitle("UTXOs")
            .onAppear {
                coinControlStore.activate(profileID: walletStore.selectedProfile?.id)
                knownUTXOIDs = Set(utxos.map(\.id))
            }
            .onChange(of: utxos.map(\.id)) { _, ids in
                let current = Set(ids)

                if !knownUTXOIDs.isEmpty {
                    newlyArrivedUTXOIDs = current.subtracting(knownUTXOIDs)
                }

                knownUTXOIDs = current
            }
            .onChange(of: walletStore.selectedProfileID) { _, newValue in
                dismissLabelEditor()
                confirmationStore.reset()
                coinControlStore.activate(profileID: newValue)
            }
            .onChange(of: engine.rpcNotificationVersion) { _, _ in
                handleRPCNotifications()
            }
            .overlay {
                if isLabelEditorPresented,
                   let utxoID = editingLabelUTXOID,
                   let utxo = utxos.first(where: { $0.id == utxoID }) {
                    labelEditorOverlay(for: utxo)
                }
            }
        }
    }


    private func handleRPCNotifications() {
        guard !engine.rpcNotifications.isEmpty else { return }

        Task {
            await refreshUTXOs()
        }
    }

    private func refreshUTXOs() async {
        guard let profile = walletStore.selectedProfile else { return }
        await syncService.refresh(
            profile: profile,
            engine: engine,
            preferences: preferences,
            force: true
        )
        confirmationStore.reset()
    }

    private var utxos: [WalletUTXO] {
        (syncService.snapshot?.utxos ?? []).sorted {
            if $0.blockDAAScore != $1.blockDAAScore {
                return $0.blockDAAScore > $1.blockDAAScore
            }

            if $0.txID != $1.txID {
                return $0.txID < $1.txID
            }

            return $0.index < $1.index
        }
    }

    private func utxoCard(_ utxo: WalletUTXO, isNew: Bool) -> some View {
        let label = coinControlStore.label(for: utxo)
        let confirmation = confirmationStore.state(for: utxo)

        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .top, spacing: 12) {
                        Text(formatKas(utxo.amountKas))
                            .font(.body.weight(.regular).monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .allowsTightening(true)
                            .foregroundStyle(.primary)

                        Spacer()

                        VStack(alignment: .trailing, spacing: 3) {
                            statusRow(for: utxo, confirmation: confirmation)
                                .font(.subheadline.weight(.semibold))

                        }
                    }

                    Divider()
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Transaction ID")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Spacer()

                    if case .confirmed(let date) = confirmation {
                        Text(Self.confirmationFormatter.string(from: date))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    openURL(preferences.explorer.transactionURL(utxo.txID))
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Text(utxo.txID)
                            .font(.caption.monospaced())
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Image(systemName: "arrow.up.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }
                }
                .buttonStyle(.plain)
            }

            Divider()

            HStack(alignment: .center, spacing: 12) {
                Text("Label")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .leading)

                Button {
                    beginEditingLabel(for: utxo)
                } label: {
                    HStack(spacing: 8) {
                        if label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Color.clear
                                .frame(height: 18)
                        } else {
                            Text(label)
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label.isEmpty ? "Add label" : "Edit label")
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(
                    Color.primary.opacity(0.05),
                    lineWidth: 1
                )
        }
        .task(id: utxo.txID, priority: .background) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await confirmationStore.load(transactionID: utxo.txID)
        }
    }

    @ViewBuilder
    private func statusRow(
        for utxo: WalletUTXO,
        confirmation: UTXOConfirmationStore.State
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Spacer(minLength: 14)

            switch confirmation {
            case .confirmed:
                Text("Confirmed")
                    .foregroundStyle(
                        Color(red: 0.18, green: 0.68, blue: 0.62)
                    )
            case .notConfirmed:
                Text("Not confirmed")
                    .foregroundStyle(.red)
            case .loading:
                Text(utxo.blockDAAScore > 0 ? "Confirmed" : "Not confirmed")
                    .foregroundStyle(
                        utxo.blockDAAScore > 0
                            ? Color(red: 0.18, green: 0.68, blue: 0.62)
                            : Color.orange
                    )
            case .unavailable:
                Text(utxo.blockDAAScore > 0 ? "Confirmed" : "Not confirmed")
                    .foregroundStyle(
    utxo.blockDAAScore > 0
        ? Color(red: 0.18, green: 0.68, blue: 0.62)
        : Color.orange
)
            }
        }
    }

    private func beginEditingLabel(for utxo: WalletUTXO) {
        draftLabel = coinControlStore.label(for: utxo)
        editingLabelUTXOID = utxo.id
        isLabelEditorPresented = true

        Task { @MainActor in
            await Task.yield()
            labelEditorFocused = true
        }
    }

    private func dismissLabelEditor() {
        labelEditorFocused = false
        isLabelEditorPresented = false
        editingLabelUTXOID = nil
        draftLabel = ""
    }

    private func saveLabel(for utxo: WalletUTXO) {
        coinControlStore.setLabel(
            draftLabel.trimmingCharacters(in: .whitespacesAndNewlines),
            for: utxo
        )
        dismissLabelEditor()
    }

    private func labelEditorOverlay(for utxo: WalletUTXO) -> some View {
        ZStack {
            Color.black.opacity(0.30)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                Text(coinControlStore.label(for: utxo).isEmpty ? "Add Label" : "Edit Label")
                    .font(.headline)

                TextField("", text: $draftLabel, axis: .vertical)
                    .focused($labelEditorFocused)
                    .font(.body)
                    .lineLimit(1...5)
                    .textInputAutocapitalization(.sentences)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        Color(.tertiarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )

                HStack(spacing: 12) {
                    Button("Cancel") {
                        dismissLabelEditor()
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)

                    Button("Save") {
                        saveLabel(for: utxo)
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(20)
            .frame(maxWidth: 350)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .shadow(color: .black.opacity(0.16), radius: 18, y: 6)
            .padding(.horizontal, 24)
            .offset(y: -50)
        }
        .ignoresSafeArea(.keyboard)
        .zIndex(100)
    }

    private func detailRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 14)
            Text(value)
                .multilineTextAlignment(.trailing)
        }
    }

    private func formatKas(_ amount: Double) -> String {
        amount.formatted(.number.precision(.fractionLength(0...8))) + "\u{00A0}KAS"
    }

    private func shortTransactionID(_ transactionID: String) -> String {
        guard transactionID.count > 18 else { return transactionID }
        return "\(transactionID.prefix(14))…\(transactionID.suffix(10))"
    }

    private var accentColor: Color {
        Color(red: 0.20, green: 0.62, blue: 0.57)
    }

    private static let confirmationFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd-MM-yyyy HH:mm"
        formatter.timeZone = .current
        return formatter
    }()
}

@MainActor
private final class UTXOConfirmationStore: ObservableObject {
    enum State: Equatable {
        case loading
        case confirmed(Date)
        case notConfirmed
        case unavailable
    }

    @Published private var states: [String: State] = [:]

    func state(for utxo: WalletUTXO) -> State {
        states[utxo.txID] ?? .unavailable
    }

    func reset() {
        states = states.filter { _, state in
            if case .confirmed = state {
                return true
            }
            return false
        }
    }

    func load(transactionID: String) async {
        guard states[transactionID] == nil else { return }

        guard let encodedID = transactionID.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ), let url = URL(string: "https://api.kaspa.org/transactions/\(encodedID)") else {
            states[transactionID] = .unavailable
            return
        }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            request.cachePolicy = .reloadRevalidatingCacheData

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                states[transactionID] = .unavailable
                return
            }

            let model = try JSONDecoder().decode(TransactionResponse.self, from: data)
            guard model.isAccepted == true else {
                states[transactionID] = .notConfirmed
                return
            }

            guard let rawTimestamp = model.acceptingBlockTime ?? model.blockTime else {
                states[transactionID] = .unavailable
                return
            }

            let seconds = rawTimestamp > 10_000_000_000
                ? Double(rawTimestamp) / 1_000.0
                : Double(rawTimestamp)
            states[transactionID] = .confirmed(Date(timeIntervalSince1970: seconds))
        } catch {
            states[transactionID] = .unavailable
        }
    }

    private struct TransactionResponse: Decodable {
        let isAccepted: Bool?
        let acceptingBlockTime: Int64?
        let blockTime: Int64?

        enum CodingKeys: String, CodingKey {
            case isAccepted = "is_accepted"
            case acceptingBlockTime = "accepting_block_time"
            case blockTime = "block_time"
        }
    }
}
