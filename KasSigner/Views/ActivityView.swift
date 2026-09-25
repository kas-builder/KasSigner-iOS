import SwiftUI
import UniformTypeIdentifiers

struct ActivityView: View {
    private struct ExportAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    @EnvironmentObject private var walletStore: WalletStore
    @EnvironmentObject private var engine: KasSignerEngine
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var syncService: WalletSyncService
    @EnvironmentObject private var liveRPCService: KaspaLiveRPCService
    @EnvironmentObject private var coinControlStore: UTXOCoinControlStore
    @EnvironmentObject private var priceService: PriceService
    @Environment(\.openURL) private var openURL

    @State private var editingLabelTransactionID: String?
    @State private var draftLabel = ""
    @State private var isLabelEditorPresented = false
    @State private var historicalUSDPrices: [HistoricalPricePoint] = []
    @State private var showingCSVFileExporter = false
    @State private var csvExportDocument: PortfolioCSVDocument?
    @State private var csvExportFileName = "KasSigner-Wallet-Transactions"
    @State private var csvExportAlert: ExportAlert?
    @State private var isPreparingCSVExport = false
    @State private var pendingInternalTransferPresentations = Set<String>()
    @State private var liveSinkBlueScore: UInt64?

    @FocusState private var labelEditorFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if walletStore.selectedProfile == nil {
                    ContentUnavailableView(
                        "No Transactions",
                        systemImage: "clock.arrow.circlepath"
                    )
                } else {
                    GeometryReader { proxy in
                        ScrollView {
                            VStack(spacing: 12) {
                                if isSynchronizingCurrentWallet {
                                    transactionHistorySyncView
                                } else if let error = syncService.transactionHistoryError {
                                    transactionHistoryErrorView(error)
                                }

                                if transactions.isEmpty,
                                   !isSynchronizingCurrentWallet {
                                    ContentUnavailableView {
                                        Label("No Transactions", systemImage: "clock.arrow.circlepath")
                                    } description: {
                                        Text(emptyDescription)
                                    }
                                    .frame(
                                        maxWidth: .infinity,
                                        minHeight: proxy.size.height
                                    )
                                } else if !transactions.isEmpty {
                                    LazyVStack(spacing: 12) {
                                        ForEach(transactions) { transaction in
                                            transactionCard(transaction)
                                        }
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.bottom, 24)
                                }
                            }
                            .padding(.top, 8)
                        }
                        .refreshable {
                            await refreshHistory(force: true)
                        }
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Transactions")
            .toolbar {
                if walletStore.selectedProfile != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button {
                                Task { await beginCSVExport() }
                            } label: {
                                Label("Export Transactions", systemImage: "square.and.arrow.down")
                            }
                            .disabled(transactions.isEmpty || isPreparingCSVExport)
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .tint(Color(red: 0.20, green: 0.62, blue: 0.57))
                        .accessibilityLabel("Transaction Actions")
                    }
                }
            }
            .task(id: walletStore.selectedProfileID) {
                guard let profileID = walletStore.selectedProfileID else { return }
                walletStore.reloadCachedTransactions(profileID: profileID)
                await syncService.refreshVirtualBlueScore(force: false)
            }
            .task {
                await priceService.refresh(preferences: preferences)
            }
            .task(id: historicalPriceRequestID) {
                await loadHistoricalUSDPrices()
            }
            .onAppear {
                coinControlStore.activate(profileID: walletStore.selectedProfile?.id)
            }
            .onChange(of: walletStore.selectedProfileID) { _, newValue in
                dismissLabelEditor()
                coinControlStore.activate(profileID: newValue)
            }
            .onReceive(liveRPCService.sinkBlueScorePublisher) { score in
                liveSinkBlueScore = score
            }
            .overlay {
                if isLabelEditorPresented,
                   let transactionID = editingLabelTransactionID {
                    labelEditorOverlay(forTransactionID: transactionID)
                }
            }
        }
        .fileExporter(
            isPresented: $showingCSVFileExporter,
            document: csvExportDocument,
            contentType: .commaSeparatedText,
            defaultFilename: csvExportFileName
        ) { result in
            handleCSVExport(result)
        }
        .alert(item: $csvExportAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var transactions: [WalletTransaction] {
        guard let profileID = walletStore.selectedProfile?.id else { return [] }
        let pending = walletStore.pendingTransactions.filter {
            $0.profileID == profileID
        }
        let pendingIDs = Set(pending.map { $0.transactionID.lowercased() })
        let history = walletStore.transactions.filter {
            $0.profileID == profileID
                && !pendingIDs.contains($0.transactionID.lowercased())
        }
        return (pending + history)
            .sorted { $0.broadcastAt > $1.broadcastAt }
    }

    private var emptyDescription: String {
        if let error = syncService.transactionHistoryError {
            return error
        }
        if syncService.isRefreshingTransactionHistory {
            return "Looking for wallet activity…"
        }
        return "Incoming and outgoing transactions will appear here after synchronization."
    }

    private var isSynchronizingCurrentWallet: Bool {
        syncService.transactionHistoryProgress?.profileID
            == walletStore.selectedProfileID
    }

    private var transactionHistorySyncView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(Color(red: 0.20, green: 0.62, blue: 0.57))
                Text("Synchronizing transactions")
                    .font(.headline)
            }

            if let fraction = syncService.transactionHistoryProgress?.fraction {
                ProgressView(value: fraction)
                    .tint(Color(red: 0.20, green: 0.62, blue: 0.57))
            } else {
                ProgressView()
                    .tint(Color(red: 0.20, green: 0.62, blue: 0.57))
            }

            Text(
                syncService.transactionHistoryProgress?.detail
                    ?? "Finding active wallet addresses…"
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 14)
        .accessibilityElement(children: .combine)
    }

    private func transactionHistoryErrorView(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Transaction synchronization paused")
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 14)
    }

    private var historicalPriceRequestID: String {
        let profileID = walletStore.selectedProfileID?.uuidString ?? "none"
        guard let oldestTimestamp = transactions.map(\.broadcastAt).min() else {
            return profileID + ":empty"
        }
        return profileID + ":" + String(Int(oldestTimestamp.timeIntervalSince1970))
    }

    private func loadHistoricalUSDPrices() async {
        guard let oldestTimestamp = transactions.map(\.broadcastAt).min() else {
            historicalUSDPrices = []
            return
        }

        let elapsedDays = Calendar.current.dateComponents(
            [.day],
            from: oldestTimestamp,
            to: Date()
        ).day ?? 1
        let prices = try? await priceService.historicalUSDPrices(
            days: String(max(1, elapsedDays + 1))
        )

        guard !Task.isCancelled else { return }
        historicalUSDPrices = prices ?? []
    }

    private func refreshHistory(force: Bool) async {
        guard let profile = walletStore.selectedProfile else { return }
        let profileID = profile.id

        // Always display this wallet's durable cache immediately. The indexed
        // history service can trail the node, especially just after broadcast.
        walletStore.reloadCachedTransactions(profileID: profileID)

        if force {
            while syncService.state == .syncing {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled,
                      walletStore.selectedProfileID == profileID else { return }
            }

            let previousUTXOs = syncService.snapshot?.utxos ?? []
            let previousOutpoints = Set(previousUTXOs.map(\.id))
            await syncService.refresh(
                profile: profile,
                walletStore: walletStore,
                engine: engine,
                preferences: preferences,
                force: true,
                includeTransactionHistory: false
            )

            guard !Task.isCancelled,
                  walletStore.selectedProfileID == profileID else { return }

            let currentUTXOs = syncService.snapshot?.utxos ?? []
            let currentOutpoints = Set(currentUTXOs.map(\.id))
            let removedOutpoints = previousOutpoints.subtracting(currentOutpoints)
            let addedUTXOs = currentUTXOs.filter {
                !previousOutpoints.contains($0.id)
            }
            if removedOutpoints.isEmpty {
                walletStore.recordObservedUTXOTransactions(
                    profileID: profileID,
                    addedUTXOs: addedUTXOs
                )
            }
            let currentProfile = walletStore.profiles.first(where: { $0.id == profileID })
                ?? profile
            await syncService.reconcilePendingTransactions(
                profile: currentProfile,
                walletStore: walletStore
            )
            await syncService.reconcileTransactionIDs(
                addedUTXOs.map(\.txID),
                profile: currentProfile,
                walletStore: walletStore
            )
            if !removedOutpoints.isEmpty,
               let spentAddresses = try? await engine.addressesOwningUTXOs(
                   previousUTXOs.filter { removedOutpoints.contains($0.id) },
                   profile: currentProfile
               ) {
                await syncService.reconcileRecentOutgoingTransactions(
                    removedOutpointIDs: removedOutpoints,
                    addresses: spentAddresses,
                    profile: currentProfile,
                    walletStore: walletStore
                )
            }
            await syncService.reconcileRecentOutgoingTransactions(
                addresses: [],
                profile: currentProfile,
                walletStore: walletStore
            )
            await syncService.reconcileTransactionsObservedByOtherWallets(
                profile: currentProfile,
                walletStore: walletStore
            )
        }

        await syncService.refreshTransactionHistory(
            profile: profile,
            walletStore: walletStore,
            force: force
        )
        guard !Task.isCancelled,
              walletStore.selectedProfileID == profileID else { return }
        await syncService.refreshVirtualBlueScore(force: force)
        walletStore.reloadCachedTransactions(profileID: profileID)
    }

    private func beginCSVExport() async {
        guard !isPreparingCSVExport,
              let profile = walletStore.selectedProfile else { return }

        let walletTransactions = transactions
        guard !walletTransactions.isEmpty else {
            csvExportAlert = ExportAlert(
                title: "Nothing to Export",
                message: "This wallet does not have any transactions to export."
            )
            return
        }

        isPreparingCSVExport = true
        defer { isPreparingCSVExport = false }

        await priceService.refresh(preferences: preferences)

        let now = Date()
        let oldestTimestamp = walletTransactions.map(\.broadcastAt).min() ?? now
        let elapsedDays = Calendar.current.dateComponents(
            [.day],
            from: oldestTimestamp,
            to: now
        ).day ?? 1
        let prices = try? await priceService.historicalUSDPrices(
            days: String(max(1, elapsedDays + 1))
        )

        guard !Task.isCancelled,
              walletStore.selectedProfile?.id == profile.id else { return }

        let historicalPrices = prices ?? historicalUSDPrices
        let livePrice = priceService.price(for: .usd)
        var records: [WalletTransactionCSVRecord] = []
        records.reserveCapacity(walletTransactions.count)

        for transaction in walletTransactions {
            guard let price = PortfolioTransactionPriceResolver.automaticPrice(
                at: transaction.broadcastAt,
                now: now,
                livePrice: livePrice,
                historicalPrices: historicalPrices
            ) else {
                csvExportAlert = ExportAlert(
                    title: "Unable to Export Transactions",
                    message: "Historical USD pricing is unavailable for one or more transactions. Please try again when price data is available."
                )
                return
            }

            records.append(
                WalletTransactionCSVRecord(
                    timestamp: transaction.broadcastAt,
                    kind: transaction.kind,
                    priceUSD: price,
                    amountKas: Double(transaction.amountSompi) / 100_000_000,
                    notes: coinControlStore.label(forTransactionID: transaction.transactionID)
                )
            )
        }

        csvExportDocument = WalletTransactionCSVExporter.document(records: records)
        csvExportFileName = WalletTransactionCSVExporter.suggestedFileName(walletName: profile.name)
        showingCSVFileExporter = true
    }

    private func handleCSVExport(_ result: Result<URL, Error>) {
        defer { csvExportDocument = nil }
        switch result {
        case .success(let url):
            csvExportAlert = ExportAlert(
                title: "Export Complete",
                message: "Saved \(url.lastPathComponent) to Files."
            )
        case .failure(let error):
            if (error as NSError).code != NSUserCancelledError {
                csvExportAlert = ExportAlert(
                    title: "Unable to Export Transactions",
                    message: error.localizedDescription
                )
            }
        }
    }

    private func transactionCard(_ transaction: WalletTransaction) -> some View {
        let label = coinControlStore.label(forTransactionID: transaction.transactionID)

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .center, spacing: 5) {
                        if transaction.kind == .internalTransfer {
                            VStack(spacing: -3) {
                                Image(systemName: "arrow.left")
                                Image(systemName: "arrow.right")
                            }
                            .font(.system(size: 14, weight: .bold))
                            .frame(width: 22, height: 28)
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: true, vertical: false)
                        }

                        Text(amountText(transaction))
                            .font(.body.weight(.regular).monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .allowsTightening(true)
                            .foregroundStyle(.primary)
                    }

                    if let usdValue = usdValueText(transaction) {
                        Text(usdValue)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 3) {
                    statusLabel(
                        transaction,
                        presentsPending: pendingInternalTransferPresentations.contains(
                            transaction.transactionID.lowercased()
                        )
                    )

                    Text(transaction.broadcastAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            recipientRow(transaction)

            Divider()
                .opacity(0.45)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Transaction ID")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Spacer()
                }

                Button {
                    openURL(preferences.explorer.transactionURL(transaction.transactionID))
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Text(transaction.transactionID)
                            .font(.caption.monospaced())
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Image(systemName: "arrow.up.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }
                }
                .buttonStyle(SubtlePressButtonStyle())
                .accessibilityHint("Opens this transaction in the selected block explorer")
            }

            VStack(spacing: 4) {
                Divider()

                NavigationLink {
                    graphDestination(for: transaction)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(width: 22)

                        Text("View transaction graph")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)

                        Spacer(minLength: 8)

                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(SubtlePressButtonStyle())
                .accessibilityHint("Opens a visual map of transaction inputs and outputs")

                Divider()
            }

            HStack(alignment: .center, spacing: 8) {
                Text("Label")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 46, alignment: .leading)

                Button {
                    beginEditingLabel(for: transaction)
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
                .buttonStyle(SubtlePressButtonStyle())
                .accessibilityLabel(label.isEmpty ? "Add label" : "Edit label")
            }
        }
        .padding(16)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .onAppear {
            presentPendingInternalTransferIfNeeded(transaction)
        }
    }

    @ViewBuilder
    private func recipientRow(_ transaction: WalletTransaction) -> some View {
        let text = "\(transaction.direction == .sent ? "To" : "From"): \(transaction.destination)"

        if isExplorerAddress(transaction.destination) {
            Button {
                openURL(preferences.explorer.addressURL(transaction.destination))
            } label: {
                recipientText(text)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens this address in the selected block explorer")
        } else {
            recipientText(text)
        }
    }

    private func recipientText(_ text: String) -> some View {
        Text(text)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func isExplorerAddress(_ value: String) -> Bool {
        let normalized = value.lowercased()
        return (normalized.hasPrefix("kaspa:") || normalized.hasPrefix("kaspatest:"))
            && !value.contains(where: \Character.isWhitespace)
    }

    private func statusLabel(
        _ transaction: WalletTransaction,
        presentsPending: Bool
    ) -> some View {
        let currentBlueScore = [
            liveSinkBlueScore,
            syncService.virtualBlueScore
        ]
            .compactMap { $0 }
            .max()
        let resolvedCount = transaction.confirmationCount(
            currentBlueScore: currentBlueScore
        )
        let count = resolvedCount ?? 0
        let isFullyConfirmed = count >= WalletTransaction.confirmationThreshold
            && resolvedCount != nil
        let isPending = presentsPending || resolvedCount == nil

        let text: String
        if isPending {
            text = "Pending"
        } else if isFullyConfirmed {
            text = "Confirmed"
        } else {
            text = "\(count) confirmations"
        }

        return Text(text)
            .font(
                isFullyConfirmed || isPending
                    ? .body.weight(.semibold)
                    : .subheadline.weight(.regular)
            )
            .monospacedDigit()
            .foregroundStyle(
                isPending
                    ? Color.yellow
                    : isFullyConfirmed
                        ? Color(red: 0.18, green: 0.68, blue: 0.62)
                        : Color.primary
            )
    }

    private func presentPendingInternalTransferIfNeeded(
        _ transaction: WalletTransaction
    ) {
        let transactionID = transaction.transactionID.lowercased()
        guard transaction.kind == .internalTransfer,
              Date().timeIntervalSince(transaction.broadcastAt) < 30,
              !pendingInternalTransferPresentations.contains(transactionID)
        else {
            return
        }

        pendingInternalTransferPresentations.insert(transactionID)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            pendingInternalTransferPresentations.remove(transactionID)
        }
    }

    private func beginEditingLabel(for transaction: WalletTransaction) {
        draftLabel = coinControlStore.label(forTransactionID: transaction.transactionID)
        editingLabelTransactionID = transaction.transactionID
        isLabelEditorPresented = true

        Task { @MainActor in
            await Task.yield()
            labelEditorFocused = true
        }
    }

    private func dismissLabelEditor() {
        labelEditorFocused = false
        isLabelEditorPresented = false
        editingLabelTransactionID = nil
        draftLabel = ""
    }

    private func saveLabel(forTransactionID transactionID: String) {
        coinControlStore.setLabel(draftLabel, forTransactionID: transactionID)
        dismissLabelEditor()
    }

    private func labelEditorOverlay(forTransactionID transactionID: String) -> some View {
        ZStack {
            Color.black.opacity(0.30)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                Text(coinControlStore.label(forTransactionID: transactionID).isEmpty ? "Add Label" : "Edit Label")
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
                        saveLabel(forTransactionID: transactionID)
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

    private func directionIcon(_ direction: WalletTransactionDirection) -> String {
        direction == .sent ? "arrow.up.right" : "arrow.down.left"
    }

    @ViewBuilder
    private func graphDestination(for transaction: WalletTransaction) -> some View {
        if let profile = walletStore.profiles.first(where: {
            $0.id == transaction.profileID
        }) {
            TransactionGraphDetailView(
                transaction: transaction,
                profile: profile
            )
        } else {
            ContentUnavailableView(
                "Wallet Unavailable",
                systemImage: "wallet.pass"
            )
        }
    }

    private func directionColor(_ direction: WalletTransactionDirection) -> Color {
        direction == .sent ? .orange : .green
    }

    private func amountText(_ transaction: WalletTransaction) -> String {
        let prefix: String
        switch transaction.kind {
        case .sent: prefix = "−"
        case .received: prefix = "+"
        case .internalTransfer: prefix = ""
        }
        return prefix + formatKas(transaction.amountSompi)
    }

    private func usdValueText(_ transaction: WalletTransaction) -> String? {
        let kas = Double(transaction.amountSompi) / 100_000_000
        guard let price = PortfolioTransactionPriceResolver.automaticPrice(
            at: transaction.broadcastAt,
            now: Date(),
            livePrice: priceService.price(for: .usd),
            historicalPrices: historicalUSDPrices
        ) else {
            return nil
        }
        let value = kas * price
        return value.formatted(
            .currency(code: "USD")
                .precision(.fractionLength(2))
        )
    }

    private func formatKas(_ sompi: UInt64) -> String {
        KasBalanceFormatter.string(
            fromSompi: sompi,
            decimalPlaces: preferences.kasBalanceDecimalPlaces
        ) + " KAS"
    }
}

private struct TransactionGraphDetailView: View {
    let transaction: WalletTransaction
    let profile: WalletProfile

    @EnvironmentObject private var syncService: WalletSyncService
    @EnvironmentObject private var preferences: AppPreferences

    @State private var graph: TransactionGraphDetails?
    @State private var loadError: String?
    @State private var isLoading = true

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                graphContent
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Transaction Graph")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: transaction.transactionID) {
            await loadGraph()
        }
    }

    @ViewBuilder
    private var graphContent: some View {
        if isLoading {
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading transaction graph…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 220)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
        } else if let graph {
            TransactionFlowGraphView(graph: graph)
        } else {
            ContentUnavailableView {
                Label("Graph Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(loadError ?? "The transaction details could not be loaded.")
            } actions: {
                Button("Try Again") {
                    Task { await loadGraph() }
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, minHeight: 220)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
        }
    }

    @MainActor
    private func loadGraph() async {
        isLoading = true
        loadError = nil
        do {
            graph = try await syncService.transactionGraph(
                transactionID: transaction.transactionID,
                profile: profile
            )
        } catch {
            graph = nil
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}

private struct TransactionFlowGraphView: View {
    let graph: TransactionGraphDetails

    private enum GraphRow: Hashable {
        case input(String)
        case output(Int)
    }

    private struct GraphAddressButtonStyle: ButtonStyle {
        let row: GraphRow
        @Binding var pressedRow: GraphRow?

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .onChange(of: configuration.isPressed) { _, isPressed in
                    if isPressed {
                        pressedRow = row
                    } else if pressedRow == row {
                        pressedRow = nil
                    }
                }
        }
    }

    @EnvironmentObject private var preferences: AppPreferences
    @Environment(\.openURL) private var openURL

    @State private var selectedRow: GraphRow?
    @State private var pressedRow: GraphRow?
    @State private var isExpanded = false

    private let accentColor = Color(red: 0.20, green: 0.62, blue: 0.57)
    private let maximumVisibleNodes = 6

    private func isHighlighted(_ row: GraphRow) -> Bool {
        (pressedRow ?? selectedRow) == row
    }

    private var visibleInputs: [TransactionGraphInput] {
        isExpanded ? graph.inputs : Array(graph.inputs.prefix(maximumVisibleNodes))
    }

    private var visibleOutputs: [TransactionGraphOutput] {
        isExpanded ? graph.outputs : Array(graph.outputs.prefix(maximumVisibleNodes))
    }

    private var rightRowCount: Int {
        visibleOutputs.count + (graph.feeSompi == nil ? 0 : 1)
    }

    private var graphHeight: CGFloat {
        CGFloat(max(3, visibleInputs.count, rightRowCount)) * 52 + 44
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Inputs · \(graph.inputs.count)")
                Spacer()
                Text("Outputs · \(graph.outputs.count)")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

            GeometryReader { proxy in
                ZStack {
                    graphLines(size: proxy.size)

                    HStack(spacing: 0) {
                        let bridgeLength = centerBridgeLength(for: proxy.size.width)
                        let curveRunway = curveRunwayLength(for: proxy.size.width)
                        let sideColumnWidth = (
                            proxy.size.width - bridgeLength - curveRunway * 2
                        ) / 2

                        inputColumn
                            .frame(width: sideColumnWidth)

                        Color.clear
                            .frame(width: curveRunway)

                        Color.clear
                            .frame(width: bridgeLength)

                        Color.clear
                            .frame(width: curveRunway)

                        outputColumn
                            .frame(width: sideColumnWidth)
                    }
                    .frame(maxHeight: .infinity)
                }
            }
            .frame(height: graphHeight)

            if hasExpandableRows {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(expandControlTitle)
                            .font(.caption.weight(.medium))

                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(SubtlePressButtonStyle())
            }
        }
        .padding(16)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .accessibilityElement(children: .contain)
    }

    private var inputColumn: some View {
        VStack(spacing: 0) {
            ForEach(visibleInputs) { input in
                graphAddressLabel(
                    address: input.address,
                    fallback: compactOutpoint(input.outpoint),
                    amount: input.amountSompi,
                    alignment: .trailing,
                    row: .input(input.id)
                )
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var outputColumn: some View {
        VStack(spacing: 0) {
            ForEach(visibleOutputs) { output in
                graphAddressLabel(
                    address: output.address,
                    fallback: "Output \(output.index)",
                    amount: output.amountSompi,
                    alignment: .leading,
                    row: .output(output.id)
                )
            }

            if let fee = graph.feeSompi {
                graphLabel(
                    title: "Fee",
                    amount: fee,
                    icon: "dollarsign.circle",
                    alignment: .leading,
                    highlighted: false
                )
            }
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func graphAddressLabel(
        address: String?,
        fallback: String,
        amount: UInt64?,
        alignment: HorizontalAlignment,
        row: GraphRow
    ) -> some View {
        let title = compactAddress(address, fallback: fallback)
        if let address, isExplorerAddress(address) {
            Button {
                selectedRow = row
                openURL(preferences.explorer.addressURL(address))
            } label: {
                graphLabel(
                    title: title,
                    amount: amount,
                    icon: nil,
                    alignment: alignment,
                    highlighted: isHighlighted(row)
                )
            }
            .buttonStyle(GraphAddressButtonStyle(row: row, pressedRow: $pressedRow))
            .accessibilityLabel("Address \(address), \(amount.map(formatKas) ?? "amount unavailable")")
            .accessibilityHint("Opens this address in the selected block explorer")
        } else {
            graphLabel(
                title: title,
                amount: amount,
                icon: nil,
                alignment: alignment,
                highlighted: false
            )
        }
    }

    private func graphLabel(
        title: String,
        amount: UInt64?,
        icon: String?,
        alignment: HorizontalAlignment,
        highlighted: Bool
    ) -> some View {
        HStack(spacing: 5) {
            if alignment == .leading, let icon {
                Image(systemName: icon)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(title == "Fee" ? .secondary : accentColor)
                    .frame(width: 14)
            }

            VStack(alignment: alignment, spacing: 2) {
                Text(title)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(highlighted ? accentColor : Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.86)
                if let amount {
                    Text(formatKas(amount))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(highlighted ? accentColor.opacity(0.82) : Color.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
            .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)

        }
        .padding(.leading, alignment == .leading ? 3 : 0)
        .padding(.trailing, alignment == .trailing ? 3 : 0)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func graphLines(size: CGSize) -> some View {
        Canvas { context, _ in
            let centerY = size.height / 2
            let bridgeLength = centerBridgeLength(for: size.width)
            let curveRunway = curveRunwayLength(for: size.width)
            let sideColumnWidth = (size.width - bridgeLength - curveRunway * 2) / 2
            let labelInset: CGFloat = 3
            let inputEndpointX = sideColumnWidth - labelInset
            let centerLeftX = sideColumnWidth + curveRunway
            let centerRightX = centerLeftX + bridgeLength
            let outputEndpointX = centerRightX + curveRunway + labelInset
            let lineColor = Color.secondary.opacity(0.48)
            let lineWidth: CGFloat = 1.25
            let inputCenters = rowCenters(count: visibleInputs.count, height: size.height)
            for (index, input) in visibleInputs.enumerated() {
                let highlighted = isHighlighted(.input(input.id))
                let y = inputCenters[index]
                var path = Path()
                path.move(to: CGPoint(x: inputEndpointX, y: y))
                path.addCurve(
                    to: CGPoint(x: centerLeftX, y: centerY),
                    control1: CGPoint(x: inputEndpointX + curveRunway * 0.72, y: y),
                    control2: CGPoint(x: centerLeftX - curveRunway * 0.72, y: centerY)
                )
                context.stroke(
                    path,
                    with: .color(highlighted ? accentColor.opacity(0.88) : lineColor),
                    lineWidth: highlighted ? 2 : lineWidth
                )
            }

            let outputCenters = rowCenters(count: rightRowCount, height: size.height)
            for (index, output) in visibleOutputs.enumerated() {
                let highlighted = isHighlighted(.output(output.id))
                let y = outputCenters[index]
                var path = Path()
                path.move(to: CGPoint(x: centerRightX, y: centerY))
                path.addCurve(
                    to: CGPoint(x: outputEndpointX, y: y),
                    control1: CGPoint(x: centerRightX + curveRunway * 0.72, y: centerY),
                    control2: CGPoint(x: outputEndpointX - curveRunway * 0.72, y: y)
                )
                context.stroke(
                    path,
                    with: .color(highlighted ? accentColor.opacity(0.88) : lineColor),
                    lineWidth: highlighted ? 2 : lineWidth
                )
            }

            if graph.feeSompi != nil {
                let y = outputCenters[visibleOutputs.count]
                var path = Path()
                path.move(to: CGPoint(x: centerRightX, y: centerY))
                path.addCurve(
                    to: CGPoint(x: outputEndpointX, y: y),
                    control1: CGPoint(x: centerRightX + curveRunway * 0.72, y: centerY),
                    control2: CGPoint(x: outputEndpointX - curveRunway * 0.72, y: y)
                )
                context.stroke(path, with: .color(lineColor), lineWidth: lineWidth)
            }

            var centerLine = Path()
            centerLine.move(to: CGPoint(x: centerLeftX, y: centerY))
            centerLine.addLine(to: CGPoint(x: centerRightX, y: centerY))
            context.stroke(centerLine, with: .color(lineColor), lineWidth: lineWidth)
        }
        .allowsHitTesting(false)
    }

    private func centerBridgeLength(for width: CGFloat) -> CGFloat {
        min(max(width * 0.055, 20), 30)
    }

    private func curveRunwayLength(for width: CGFloat) -> CGFloat {
        min(max(width * 0.085, 26), 34)
    }

    private func rowCenters(count: Int, height: CGFloat) -> [CGFloat] {
        guard count > 0 else { return [] }
        let rowHeight = height / CGFloat(count)
        return (0..<count).map { rowHeight * (CGFloat($0) + 0.5) }
    }

    private func compactAddress(_ address: String?, fallback: String) -> String {
        guard let address, !address.isEmpty else { return fallback }
        let displayAddress = address.lowercased().hasPrefix("kaspa:")
            ? String(address.dropFirst("kaspa:".count))
            : address
        guard displayAddress.count > 12 else { return displayAddress }
        return String(displayAddress.prefix(6))
            + "..."
            + String(displayAddress.suffix(6))
    }

    private func isExplorerAddress(_ address: String) -> Bool {
        let normalized = address.lowercased()
        return (normalized.hasPrefix("kaspa:") || normalized.hasPrefix("kaspatest:"))
            && !address.contains(where: \.isWhitespace)
    }

    private func compactOutpoint(_ outpoint: String) -> String {
        guard let separator = outpoint.lastIndex(of: ":") else {
            return String(outpoint.prefix(10))
        }
        return String(outpoint.prefix(8)) + "…" + outpoint[separator...]
    }

    private func formatKas(_ sompi: UInt64) -> String {
        let whole = sompi / 100_000_000
        let fractional = sompi % 100_000_000
        guard fractional != 0 else { return "\(whole) KAS" }
        let fractionalText = String(format: "%08llu", fractional)
            .replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
        return "\(whole).\(fractionalText) KAS"
    }

    private var hasExpandableRows: Bool {
        graph.inputs.count > maximumVisibleNodes || graph.outputs.count > maximumVisibleNodes
    }

    private var expandControlTitle: String {
        guard isExpanded else {
            let hiddenInputs = graph.inputs.count - visibleInputs.count
            let hiddenOutputs = graph.outputs.count - visibleOutputs.count
            if hiddenInputs > 0 && hiddenOutputs > 0 {
                return "Show \(hiddenInputs) more inputs and \(hiddenOutputs) more outputs"
            }
            if hiddenInputs > 0 { return "Show \(hiddenInputs) more inputs" }
            return "Show \(hiddenOutputs) more outputs"
        }

        return "Show fewer"
    }
}
