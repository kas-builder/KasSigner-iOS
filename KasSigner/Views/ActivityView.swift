import SwiftUI

struct ActivityView: View {
    @EnvironmentObject private var walletStore: WalletStore
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var syncService: WalletSyncService
    @EnvironmentObject private var coinControlStore: UTXOCoinControlStore
    @Environment(\.openURL) private var openURL

    @State private var editingLabelTransactionID: String?
    @State private var draftLabel = ""
    @State private var isLabelEditorPresented = false

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

    private func refreshHistory(force: Bool) async {
        guard let profile = walletStore.selectedProfile else { return }
        await syncService.refreshTransactionHistory(
            profile: profile,
            walletStore: walletStore,
            force: force
        )
        walletStore.reloadCachedTransactions(profileID: profile.id)
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
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(amountText(transaction))
                        .font(.body.weight(.regular).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .allowsTightening(true)
                        .foregroundStyle(.primary)

                    Spacer()

                    statusLabel(transaction.status)
                        .font(.body.weight(.semibold))
                }

                Text(transaction.broadcastAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                            .lineLimit(2)
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

    private func formatKas(_ sompi: UInt64) -> String {
        KasBalanceFormatter.string(
            fromSompi: sompi,
            decimalPlaces: preferences.kasBalanceDecimalPlaces
        ) + " KAS"
    }
}
