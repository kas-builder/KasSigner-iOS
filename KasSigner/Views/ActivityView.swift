import SwiftUI
import UniformTypeIdentifiers

struct ActivityView: View {
    private struct ExportAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    @EnvironmentObject private var walletStore: WalletStore
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var syncService: WalletSyncService
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
                            if transactions.isEmpty {
                                ContentUnavailableView {
                                    Label("No Transactions", systemImage: "clock.arrow.circlepath")
                                } description: {
                                    Text(emptyDescription)
                                }
                                .frame(
                                    maxWidth: .infinity,
                                    minHeight: proxy.size.height
                                )
                            } else {
                                LazyVStack(spacing: 12) {
                                    if let error = syncService.transactionHistoryError {
                                        historyMessage(error)
                                    }

                                    ForEach(transactions) { transaction in
                                        transactionCard(transaction)
                                    }
                                }
                                .padding(.horizontal, 14)
                                .padding(.top, 8)
                                .padding(.bottom, 24)
                            }
                        }
                        .refreshable {
                            await refreshHistory(force: true)
                        }
                        .id(walletStore.transactionRevision)
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

                if syncService.isRefreshingTransactionHistory {
                    ToolbarItem(placement: .topBarTrailing) {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Synchronizing transactions")
                    }
                }
            }
            .task(id: walletStore.selectedProfileID) {
                await refreshHistory(force: false)
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
        await syncService.refreshTransactionHistory(
            profile: profile,
            walletStore: walletStore,
            force: force
        )
        walletStore.reloadCachedTransactions(profileID: profile.id)
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
                    type: transaction.direction,
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

    private func historyMessage(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }

    private func transactionCard(_ transaction: WalletTransaction) -> some View {
        let label = coinControlStore.label(forTransactionID: transaction.transactionID)

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(amountText(transaction))
                        .font(.body.weight(.regular).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .allowsTightening(true)
                        .foregroundStyle(.primary)

                    if let usdValue = usdValueText(transaction) {
                        Text(usdValue)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 3) {
                    statusLabel(transaction.status)
                        .font(.body.weight(.semibold))

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

            Divider()

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

    private func statusLabel(_ status: WalletTransactionStatus) -> some View {
        Text(status == .confirmed ? "Confirmed" : "Pending")
            .foregroundStyle(
                status == .confirmed
                    ? Color(red: 0.18, green: 0.68, blue: 0.62)
                    : .orange
            )
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

    private func directionColor(_ direction: WalletTransactionDirection) -> Color {
        direction == .sent ? .orange : .green
    }

    private func amountText(_ transaction: WalletTransaction) -> String {
        let prefix = transaction.direction == .sent ? "−" : "+"
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
                .precision(.fractionLength(0...2))
        )
    }

    private func formatKas(_ sompi: UInt64) -> String {
        KasBalanceFormatter.string(
            fromSompi: sompi,
            decimalPlaces: preferences.kasBalanceDecimalPlaces
        ) + " KAS"
    }
}
