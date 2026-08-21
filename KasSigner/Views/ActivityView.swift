import SwiftUI

struct ActivityView: View {
    @EnvironmentObject private var walletStore: WalletStore
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var syncService: WalletSyncService
    @Environment(\.openURL) private var openURL

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
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: directionIcon(transaction.direction))
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(directionColor(transaction.direction))
                    .frame(width: 38, height: 38)
                    .background(
                        directionColor(transaction.direction).opacity(0.12),
                        in: Circle()
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(transaction.direction == .sent ? "Sent" : "Received")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(transaction.broadcastAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 4) {
                    Text(amountText(transaction))
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    statusLabel(transaction.status)
                }
            }

            Divider()

            recipientRow(transaction)

            Divider()
                .opacity(0.45)

            Button {
                openURL(preferences.explorer.transactionURL(transaction.transactionID))
            } label: {
                Text("Tx ID: \(transaction.transactionID)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens this transaction in the selected block explorer")
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
        Label(
            status == .confirmed ? "Confirmed" : "Pending",
            systemImage: status == .confirmed ? "checkmark.circle.fill" : "clock.fill"
        )
        .font(.caption.weight(.semibold))
        .foregroundStyle(status == .confirmed ? .green : .orange)
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
        let whole = sompi / 100_000_000
        let fractional = sompi % 100_000_000

        guard fractional != 0 else {
            return "\(whole) KAS"
        }

        let fractionalText = String(format: "%08llu", fractional)
            .replacingOccurrences(
                of: "0+$",
                with: "",
                options: .regularExpression
            )

        return "\(whole).\(fractionalText) KAS"
    }
}
