import SwiftUI

struct ActivityView: View {
    @EnvironmentObject private var walletStore: WalletStore
    @EnvironmentObject private var preferences: AppPreferences
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            Group {
                if walletStore.selectedProfile == nil {
                    ContentUnavailableView(
                        "No Account",
                        systemImage: "wallet.pass",
                        description: Text("Add and select an account before viewing transactions.")
                    )
                } else if transactions.isEmpty {
                    ContentUnavailableView(
                        "No Transactions",
                        systemImage: "clock.arrow.circlepath"
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(transactions) { transaction in
                                transactionCard(transaction)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 20)
                    }
                    .background(Color(.systemGroupedBackground))
                }
            }
            .navigationTitle("Transactions")
        }
    }

    private var transactions: [WalletTransaction] {
        guard let profileID = walletStore.selectedProfile?.id else { return [] }
        return walletStore.transactions
            .filter { $0.profileID == profileID }
            .sorted { $0.broadcastAt > $1.broadcastAt }
    }

    private func transactionCard(_ transaction: WalletTransaction) -> some View {
        Button {
            openURL(preferences.explorer.transactionURL(transaction.transactionID))
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(formatKas(transaction.amountSompi))
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)

                    Spacer()

                    Label("Broadcasted", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.green)
                }

                Divider()

                VStack(alignment: .leading, spacing: 5) {
                    Text("Destination")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(transaction.destination)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(alignment: .firstTextBaseline) {
                    Text("Network Fee")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(formatKas(transaction.feeSompi))
                        .font(.body.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.primary)
                }

                HStack(alignment: .firstTextBaseline) {
                    Text("Broadcasted")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(transaction.broadcastAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                }

                Divider()

                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Transaction ID")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(transaction.transactionID)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Image(systemName: "arrow.up.right.square")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                        .padding(.top, 4)
                }
            }
            .padding(16)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 15, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(SubtlePressButtonStyle())
        .accessibilityHint("Opens this transaction in the selected block explorer")
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
