import SwiftData
import SwiftUI

struct PortfolioView: View {
    private enum TimeRange: String, CaseIterable, Identifiable {
        case day = "24H"
        case week = "7D"
        case month = "30D"
        case quarter = "90D"
        case all = "All"

        var id: Self { self }
    }

    private enum PortfolioSection: String, CaseIterable, Identifiable {
        case holdings = "Overview"
        case transactions = "Transactions"

        var id: Self { self }
    }

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var priceService: PriceService
    @Query(sort: \PortfolioAccount.createdAt) private var accounts: [PortfolioAccount]
    @Query(sort: \PortfolioTransaction.timestamp, order: .reverse)
    private var transactions: [PortfolioTransaction]

    @AppStorage("kassigner.portfolio.selectedID.v1")
    private var selectedPortfolioID = ""
    @State private var selectedSection: PortfolioSection = .holdings
    @State private var selectedRange: TimeRange = .day
    @State private var accountBeingEdited: PortfolioAccount?
    @State private var accountPendingDeletion: PortfolioAccount?
    @State private var showingAccountEditor = false
    @State private var showingTransactionEditor = false
    @State private var selectedTransaction: PortfolioTransaction?
    @State private var transactionBeingEdited: PortfolioTransaction?
    @State private var transactionPendingDeletion: PortfolioTransaction?
    @State private var openEditorAfterDetailDismisses = false
    @State private var showingHoldingDetail = false

    private let teal = Color(red: 0.20, green: 0.62, blue: 0.57)

    var body: some View {
        NavigationStack {
            Group {
                if accounts.isEmpty {
                    emptyState
                } else {
                    portfolioContent
                }
            }
            .navigationTitle(accounts.isEmpty ? "Portfolio" : "")
            .navigationBarTitleDisplayMode(accounts.isEmpty ? .large : .inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        beginAddingAccount()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .tint(activePortfolioColor)
                    .accessibilityLabel("Add Portfolio Account")
                }

                if let selectedAccount {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button {
                                beginEditing(selectedAccount)
                            } label: {
                                Label("Edit Account", systemImage: "pencil")
                            }

                            Button(role: .destructive) {
                                accountPendingDeletion = selectedAccount
                            } label: {
                                Label("Delete Account", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .tint(activePortfolioColor)
                        .accessibilityLabel("Portfolio Account Actions")
                    }
                }
            }
        }
        .sheet(isPresented: $showingAccountEditor) {
            PortfolioAccountEditor(account: accountBeingEdited) { draft in
                saveAccount(draft)
            }
        }
        .sheet(isPresented: $showingTransactionEditor) {
            PortfolioTransactionEditor(
                accounts: accounts,
                initialPortfolioID: transactionBeingEdited?.portfolioID ?? selectedPortfolioUUID,
                transaction: transactionBeingEdited,
                accentColor: activePortfolioColor
            ) { draft in
                saveTransaction(draft)
            }
            .presentationDetents([.fraction(0.9)])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $selectedTransaction, onDismiss: {
            if openEditorAfterDetailDismisses {
                openEditorAfterDetailDismisses = false
                showingTransactionEditor = true
            }
        }) { transaction in
            PortfolioTransactionDetail(
                transaction: transaction,
                portfolioName: accountName(for: transaction.portfolioID) ?? "Unknown Portfolio",
                accentColor: activePortfolioColor,
                onEdit: {
                    transactionBeingEdited = transaction
                    openEditorAfterDetailDismisses = true
                    selectedTransaction = nil
                },
                onDelete: {
                    selectedTransaction = nil
                    transactionPendingDeletion = transaction
                }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingHoldingDetail) {
            PortfolioHoldingDetail(
                summary: holdingSummary,
                kasPriceUSD: priceService.price(for: .usd),
                accentColor: activePortfolioColor
            )
            .presentationDetents([.fraction(0.9)])
            .presentationDragIndicator(.visible)
        }
        .alert(
            "Delete Portfolio Account?",
            isPresented: Binding(
                get: { accountPendingDeletion != nil },
                set: { if !$0 { accountPendingDeletion = nil } }
            ),
            presenting: accountPendingDeletion
        ) { account in
            Button("Delete", role: .destructive) {
                deleteAccount(account)
            }
            Button("Cancel", role: .cancel) {}
        } message: { account in
            Text("“\(account.name)” and its future portfolio transactions will be removed from this device.")
        }
        .alert(
            "Delete Transaction?",
            isPresented: Binding(
                get: { transactionPendingDeletion != nil },
                set: { if !$0 { transactionPendingDeletion = nil } }
            ),
            presenting: transactionPendingDeletion
        ) { transaction in
            Button("Delete", role: .destructive) {
                deleteTransaction(transaction)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This transaction will be permanently removed from this device.")
        }
        .onChange(of: accounts.map(\.id)) { _, accountIDs in
            guard let selectedPortfolioUUID else { return }
            if !accountIDs.contains(selectedPortfolioUUID) {
                selectedPortfolioID = ""
            }
        }
        .task {
            migrateLegacyPortfolioIcons()
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Portfolios", systemImage: "briefcase.fill")
        } description: {
            Text("Create an account to start tracking KAS buys, sells, and transfers.")
        } actions: {
            Button("New Portfolio") {
                beginAddingAccount()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var portfolioContent: some View {
        ScrollView {
            VStack(spacing: 16) {
                largePortfolioMenu
                valueCard

                if selectedSection == .holdings {
                    chartCard
                    holdingsSection
                } else {
                    transactionsSection
                }
            }
            .padding()
        }
    }

    private var largePortfolioMenu: some View {
        Menu {
            Button {
                selectedPortfolioID = ""
            } label: {
                if selectedPortfolioID.isEmpty {
                    Label("All Portfolios", systemImage: "checkmark")
                } else {
                    Text("All Portfolios")
                }
            }

            Divider()

            ForEach(accounts) { account in
                Button {
                    selectedPortfolioID = account.id.uuidString
                } label: {
                    if selectedPortfolioID == account.id.uuidString {
                        Label(account.name, systemImage: "checkmark")
                    } else {
                        Text(account.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                Text(selectedAccount?.name ?? "All Portfolios")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Image(systemName: "chevron.down")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(activePortfolioColor)

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Select Portfolio")
        .accessibilityValue(selectedAccount?.name ?? "All Portfolios")
    }

    private var valueCard: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Portfolio Value")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text("$0.00")
                    .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            sectionSelector
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sectionSelector: some View {
        HStack(spacing: 0) {
            ForEach(PortfolioSection.allCases) { section in
                sectionButton(section)
            }
        }
        .padding(.top, 2)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func sectionButton(_ section: PortfolioSection) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                selectedSection = section
            }
        } label: {
            VStack(spacing: 9) {
                Text(section.rawValue)
                    .font(.subheadline.weight(selectedSection == section ? .semibold : .regular))
                    .foregroundStyle(selectedSection == section ? .primary : .secondary)

                Capsule()
                    .fill(selectedSection == section ? activePortfolioColor : .clear)
                    .frame(height: 3)
                    .padding(.horizontal, 18)
            }
            .padding(.top, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityAddTraits(selectedSection == section ? .isSelected : [])
    }

    private var chartCard: some View {
        VStack(spacing: 16) {
            HStack(spacing: 4) {
                ForEach(TimeRange.allCases) { range in
                    Button {
                        selectedRange = range
                    } label: {
                        Text(range.rawValue)
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(
                                selectedRange == range ? activePortfolioColor.opacity(0.18) : .clear,
                                in: Capsule()
                            )
                            .foregroundStyle(selectedRange == range ? activePortfolioColor : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            ContentUnavailableView {
                Label("No Chart Data", systemImage: "chart.xyaxis.line")
            } description: {
                Text("Portfolio history will appear here after transactions and historical prices are added.")
            }
            .frame(minHeight: 185)
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var holdingsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button {
                showingHoldingDetail = true
                Task {
                    await priceService.refresh(preferences: preferences)
                }
            } label: {
                HStack(spacing: 12) {
                    Image("KaspaLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 38, height: 38)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Kaspa")
                            .font(.subheadline.weight(.semibold))
                        Text("KAS")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(holdingAmountText)
                            .font(.subheadline.weight(.semibold))
                        Text(holdingValueText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)

            Divider()
            newTransactionButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
        .padding(.vertical, 6)
    }

    private var transactionsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Transactions")
                    .font(.headline)

                Spacer()
            }

            if visibleTransactions.isEmpty {
                HStack(spacing: 12) {
                    themedIcon("arrow.left.arrow.right")
                    Text("No Transactions")
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 24)
            } else {
                ForEach(visibleTransactions) { transaction in
                    transactionRow(transaction)
                    if transaction.id != visibleTransactions.last?.id {
                        Divider()
                    }
                }
            }

            newTransactionButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
        .padding(.top, 4)
    }

    private var newTransactionButton: some View {
        Button {
            transactionBeingEdited = nil
            showingTransactionEditor = true
        } label: {
            Label("New Transaction", systemImage: "plus")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
        }
        .buttonStyle(.borderedProminent)
        .tint(activePortfolioColor)
        .accessibilityLabel("New Portfolio Transaction")
    }

    private func transactionRow(_ transaction: PortfolioTransaction) -> some View {
        Button {
            selectedTransaction = transaction
        } label: {
            HStack(spacing: 12) {
                themedIcon(transactionIcon(for: transaction.type))

                VStack(alignment: .leading, spacing: 3) {
                    Text(transaction.type)
                        .font(.subheadline.weight(.semibold))
                    HStack(spacing: 5) {
                        if selectedAccount == nil,
                           let accountName = accountName(for: transaction.portfolioID) {
                            Text(accountName)
                            Text("•")
                        }
                        Text(transaction.timestamp.formatted(date: .abbreviated, time: .shortened))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 3) {
                    Text(transaction.kasAmount.formatted(.number.grouping(.automatic)) + " KAS")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text((transaction.kasAmount * transaction.kasPriceUSD).formatted(.currency(code: "USD")))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .padding(.vertical, 8)
    }

    private func themedIcon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.title2)
            .foregroundStyle(activePortfolioColor)
            .frame(width: 38, height: 38)
            .background(activePortfolioColor.opacity(0.12), in: Circle())
    }

    private var selectedAccount: PortfolioAccount? {
        guard let selectedPortfolioUUID else { return nil }
        return accounts.first(where: { $0.id == selectedPortfolioUUID })
    }

    private var selectedPortfolioUUID: UUID? {
        UUID(uuidString: selectedPortfolioID)
    }

    private var visibleTransactions: [PortfolioTransaction] {
        guard let selectedPortfolioUUID else { return transactions }
        return transactions.filter { $0.portfolioID == selectedPortfolioUUID }
    }

    private var holdingSummary: PortfolioHoldingSummary {
        PortfolioHoldingSummary(transactions: visibleTransactions)
    }

    private var holdingAmountText: String {
        holdingSummary.holdings.formatted(
            .number.grouping(.automatic).precision(.fractionLength(0...8))
        ) + " KAS"
    }

    private var holdingValueText: String {
        guard let kasPriceUSD = priceService.price(for: .usd) else { return "—" }
        return (holdingSummary.holdings * kasPriceUSD).formatted(.currency(code: "USD"))
    }

    private var activePortfolioColor: Color {
        selectedAccount.map(accountColor) ?? teal
    }

    private func beginAddingAccount() {
        accountBeingEdited = nil
        showingAccountEditor = true
    }

    private func beginEditing(_ account: PortfolioAccount) {
        accountBeingEdited = account
        showingAccountEditor = true
    }

    private func saveAccount(_ draft: PortfolioAccountDraft) {
        if let accountBeingEdited {
            accountBeingEdited.name = draft.name
            accountBeingEdited.iconName = draft.iconName
            accountBeingEdited.accentName = draft.accentName
        } else {
            let account = PortfolioAccount(
                name: draft.name,
                iconName: draft.iconName,
                accentName: draft.accentName
            )
            modelContext.insert(account)
            selectedPortfolioID = account.id.uuidString
        }

        try? modelContext.save()
        self.accountBeingEdited = nil
    }

    private func saveTransaction(_ draft: PortfolioTransactionDraft) {
        if let transactionBeingEdited {
            transactionBeingEdited.portfolioID = draft.portfolioID
            transactionBeingEdited.type = draft.type.rawValue
            transactionBeingEdited.kasAmount = draft.kasAmount
            transactionBeingEdited.kasPriceUSD = draft.kasPriceUSD
            transactionBeingEdited.timestamp = draft.timestamp
            transactionBeingEdited.notes = draft.notes
        } else {
            modelContext.insert(PortfolioTransaction(
                portfolioID: draft.portfolioID,
                type: draft.type.rawValue,
                kasAmount: draft.kasAmount,
                kasPriceUSD: draft.kasPriceUSD,
                timestamp: draft.timestamp,
                notes: draft.notes
            ))
        }
        try? modelContext.save()
        transactionBeingEdited = nil
    }

    private func deleteTransaction(_ transaction: PortfolioTransaction) {
        modelContext.delete(transaction)
        try? modelContext.save()
        transactionPendingDeletion = nil
    }

    private func deleteAccount(_ account: PortfolioAccount) {
        if selectedPortfolioID == account.id.uuidString {
            selectedPortfolioID = ""
        }
        for transaction in transactions where transaction.portfolioID == account.id {
            modelContext.delete(transaction)
        }
        modelContext.delete(account)
        try? modelContext.save()
        accountPendingDeletion = nil
    }

    private func accountName(for id: UUID) -> String? {
        accounts.first(where: { $0.id == id })?.name
    }

    private func transactionIcon(for type: String) -> String {
        switch type {
        case PortfolioTransactionType.buy.rawValue: "plus.circle"
        case PortfolioTransactionType.sell.rawValue: "minus.circle"
        case PortfolioTransactionType.transferIn.rawValue: "arrow.down.circle"
        case PortfolioTransactionType.transferOut.rawValue: "arrow.up.circle"
        default: "arrow.left.arrow.right.circle"
        }
    }

    private func migrateLegacyPortfolioIcons() {
        let legacyAccounts = accounts.filter { $0.iconName == "chart.pie.fill" }
        guard !legacyAccounts.isEmpty else { return }
        legacyAccounts.forEach { $0.iconName = "briefcase.fill" }
        try? modelContext.save()
    }

    private func accountColor(_ account: PortfolioAccount) -> Color {
        switch account.accentName {
        case "blue": .blue
        case "indigo": .indigo
        case "orange": .orange
        case "red", "purple": .red
        default: teal
        }
    }
}

private struct PortfolioHoldingSummary {
    let holdings: Double
    let costBasis: Double
    let totalBought: Double
    let totalSold: Double
    let totalTransferredIn: Double
    let totalTransferredOut: Double

    init(transactions: [PortfolioTransaction]) {
        var holdings = 0.0
        var costBasis = 0.0
        var totalBought = 0.0
        var totalSold = 0.0
        var totalTransferredIn = 0.0
        var totalTransferredOut = 0.0

        for transaction in transactions.sorted(by: { $0.timestamp < $1.timestamp }) {
            switch transaction.type {
            case PortfolioTransactionType.buy.rawValue:
                holdings += transaction.kasAmount
                costBasis += transaction.kasAmount * transaction.kasPriceUSD
                totalBought += transaction.kasAmount
            case PortfolioTransactionType.sell.rawValue:
                let averageCost = holdings > 0 ? costBasis / holdings : 0
                let disposedAmount = min(transaction.kasAmount, max(holdings, 0))
                holdings -= transaction.kasAmount
                costBasis = max(0, costBasis - (disposedAmount * averageCost))
                totalSold += transaction.kasAmount
            case PortfolioTransactionType.transferIn.rawValue:
                holdings += transaction.kasAmount
                totalTransferredIn += transaction.kasAmount
            case PortfolioTransactionType.transferOut.rawValue:
                holdings -= transaction.kasAmount
                totalTransferredOut += transaction.kasAmount
            default:
                continue
            }
        }

        self.holdings = max(0, holdings)
        self.costBasis = costBasis
        self.totalBought = totalBought
        self.totalSold = totalSold
        self.totalTransferredIn = totalTransferredIn
        self.totalTransferredOut = totalTransferredOut
    }

    var averageCost: Double? {
        guard holdings > 0, costBasis > 0 else { return nil }
        return costBasis / holdings
    }
}

private struct PortfolioHoldingDetail: View {
    @Environment(\.dismiss) private var dismiss

    let summary: PortfolioHoldingSummary
    let kasPriceUSD: Double?
    let accentColor: Color

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Image("KaspaLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 48, height: 48)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(kasAmount(summary.holdings))
                                .font(.title2.weight(.semibold))
                            Text(marketValueText)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Market") {
                    LabeledContent("KAS Price", value: kasPriceText)
                    LabeledContent("Market Value", value: marketValueText)
                    LabeledContent("Unrealized P/L") {
                        Text(unrealizedProfitLossText)
                            .foregroundStyle(unrealizedProfitLossColor)
                    }
                }

                Section("Cost") {
                    LabeledContent("Average Cost", value: averageCostText)
                    LabeledContent("Cost Basis", value: currency(summary.costBasis))
                }

                Section("Activity") {
                    LabeledContent("Bought", value: kasAmount(summary.totalBought))
                    LabeledContent("Sold", value: kasAmount(summary.totalSold))
                    LabeledContent("Transferred In", value: kasAmount(summary.totalTransferredIn))
                    LabeledContent("Transferred Out", value: kasAmount(summary.totalTransferredOut))
                }
            }
            .navigationTitle("Kaspa")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .tint(accentColor)
        }
    }

    private var kasPriceText: String {
        guard let kasPriceUSD else { return "—" }
        return kasPriceUSD.formatted(
            .currency(code: "USD").precision(.fractionLength(0...8))
        )
    }

    private var marketValueText: String {
        guard let kasPriceUSD else { return "—" }
        return currency(summary.holdings * kasPriceUSD)
    }

    private var averageCostText: String {
        guard let averageCost = summary.averageCost else { return "—" }
        return averageCost.formatted(
            .currency(code: "USD").precision(.fractionLength(0...8))
        )
    }

    private var unrealizedProfitLossText: String {
        guard let unrealizedProfitLoss else { return "—" }
        return currency(unrealizedProfitLoss)
    }

    private var unrealizedProfitLoss: Double? {
        guard let kasPriceUSD else { return nil }
        return (summary.holdings * kasPriceUSD) - summary.costBasis
    }

    private var unrealizedProfitLossColor: Color {
        guard let unrealizedProfitLoss else { return .secondary }
        if unrealizedProfitLoss > 0 { return .green }
        if unrealizedProfitLoss < 0 { return .red }
        return .secondary
    }

    private func kasAmount(_ value: Double) -> String {
        value.formatted(
            .number.grouping(.automatic).precision(.fractionLength(0...8))
        ) + " KAS"
    }

    private func currency(_ value: Double) -> String {
        value.formatted(.currency(code: "USD"))
    }
}

private enum PortfolioTransactionType: String, CaseIterable, Identifiable {
    case buy = "Buy"
    case sell = "Sell"
    case transferIn = "Transfer In"
    case transferOut = "Transfer Out"

    var id: Self { self }
}

private struct PortfolioTransactionDraft {
    let portfolioID: UUID
    let type: PortfolioTransactionType
    let kasAmount: Double
    let kasPriceUSD: Double
    let timestamp: Date
    let notes: String
}

private struct PortfolioTransactionDetail: View {
    @Environment(\.dismiss) private var dismiss

    let transaction: PortfolioTransaction
    let portfolioName: String
    let accentColor: Color
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Portfolio", value: portfolioName)
                    LabeledContent("Type", value: transaction.type)
                    LabeledContent("KAS Amount", value: kasAmountText)
                    LabeledContent("Price per KAS", value: kasPriceText)
                    LabeledContent("Total Value", value: totalValueText)
                    LabeledContent(
                        "Date & Time",
                        value: transaction.timestamp.formatted(date: .abbreviated, time: .shortened)
                    )
                }

                if !transaction.notes.isEmpty {
                    Section("Notes") {
                        Text(transaction.notes)
                    }
                }

                Section {
                    Button("Edit Transaction") {
                        onEdit()
                    }
                    .foregroundStyle(accentColor)

                    Button("Delete Transaction", role: .destructive) {
                        onDelete()
                    }
                }
            }
            .navigationTitle("Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .tint(accentColor)
        }
    }

    private var kasAmountText: String {
        transaction.kasAmount.formatted(.number.grouping(.automatic)) + " KAS"
    }

    private var kasPriceText: String {
        transaction.kasPriceUSD.formatted(
            .currency(code: "USD").precision(.fractionLength(0...8))
        )
    }

    private var totalValueText: String {
        (transaction.kasAmount * transaction.kasPriceUSD).formatted(.currency(code: "USD"))
    }
}

private struct PortfolioTransactionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var priceService: PriceService

    let accounts: [PortfolioAccount]
    let initialPortfolioID: UUID?
    let transaction: PortfolioTransaction?
    let accentColor: Color
    let onSave: (PortfolioTransactionDraft) -> Void

    @State private var portfolioID: UUID?
    @State private var transactionType: PortfolioTransactionType = .buy
    @State private var kasAmount: Double?
    @State private var kasPriceUSD: Double?
    @State private var timestamp = Date()
    @State private var notes = ""
    @State private var hasEditedPrice = false

    init(
        accounts: [PortfolioAccount],
        initialPortfolioID: UUID?,
        transaction: PortfolioTransaction? = nil,
        accentColor: Color,
        onSave: @escaping (PortfolioTransactionDraft) -> Void
    ) {
        self.accounts = accounts
        self.initialPortfolioID = initialPortfolioID
        self.transaction = transaction
        self.accentColor = accentColor
        self.onSave = onSave
        _portfolioID = State(initialValue: transaction?.portfolioID ?? initialPortfolioID ?? accounts.first?.id)
        _transactionType = State(
            initialValue: transaction.flatMap { PortfolioTransactionType(rawValue: $0.type) } ?? .buy
        )
        _kasAmount = State(initialValue: transaction?.kasAmount)
        _kasPriceUSD = State(initialValue: transaction?.kasPriceUSD)
        _timestamp = State(initialValue: transaction?.timestamp ?? Date())
        _notes = State(initialValue: transaction?.notes ?? "")
        _hasEditedPrice = State(initialValue: transaction != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Transaction") {
                    if initialPortfolioID == nil {
                        Picker("Portfolio", selection: $portfolioID) {
                            ForEach(accounts) { account in
                                Text(account.name).tag(account.id as UUID?)
                            }
                        }
                    }

                    Picker("Type", selection: $transactionType) {
                        ForEach(PortfolioTransactionType.allCases) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }

                    TextField(
                        "KAS Amount",
                        value: $kasAmount,
                        format: .number
                            .grouping(.automatic)
                            .precision(.fractionLength(0...8))
                    )
                        .keyboardType(.decimalPad)

                    TextField(
                        "Price per KAS (USD)",
                        value: $kasPriceUSD,
                        format: .number
                            .grouping(.automatic)
                            .precision(.fractionLength(0...8))
                    )
                    .keyboardType(.decimalPad)
                    .onChange(of: kasPriceUSD) { _, _ in
                        hasEditedPrice = true
                    }

                    LabeledContent("Total Value", value: totalValueText)
                }

                Section("Date & Time") {
                    DatePicker("Date", selection: $timestamp, displayedComponents: .date)
                    DatePicker("Time", selection: $timestamp, displayedComponents: .hourAndMinute)
                }

                Section("Notes") {
                    TextField("Optional notes", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle(transaction == nil ? "New Transaction" : "Edit Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let portfolioID, let kasAmount, let kasPriceUSD else { return }
                        onSave(
                            PortfolioTransactionDraft(
                                portfolioID: portfolioID,
                                type: transactionType,
                                kasAmount: kasAmount,
                                kasPriceUSD: kasPriceUSD,
                                timestamp: timestamp,
                                notes: notes.trimmingCharacters(in: .whitespacesAndNewlines)
                            )
                        )
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
            .tint(accentColor)
            .task {
                await priceService.refresh(preferences: preferences)
                populateLivePriceIfNeeded()
            }
            .onChange(of: priceService.prices) { _, _ in
                populateLivePriceIfNeeded()
            }
        }
    }

    private var canSave: Bool {
        guard portfolioID != nil, let kasAmount, let kasPriceUSD else { return false }
        return kasAmount > 0 && kasPriceUSD > 0
    }

    private var totalValueText: String {
        guard let kasAmount, let kasPriceUSD else { return "$0.00" }
        return (kasAmount * kasPriceUSD).formatted(.currency(code: "USD"))
    }

    private func populateLivePriceIfNeeded() {
        guard !hasEditedPrice,
              let livePrice = priceService.price(for: .usd) else { return }
        kasPriceUSD = livePrice
        hasEditedPrice = false
    }
}

private struct PortfolioAccountDraft {
    let name: String
    let iconName: String
    let accentName: String
}

private struct PortfolioAccountEditor: View {
    private static let icons = [
        "briefcase.fill",
        "creditcard.fill",
        "building.columns.fill",
        "lock.shield.fill",
        "tray.full.fill"
    ]
    private static let colors = ["teal", "blue", "indigo", "orange", "red"]

    @Environment(\.dismiss) private var dismiss

    let account: PortfolioAccount?
    let onSave: (PortfolioAccountDraft) -> Void

    @State private var name: String
    @State private var iconName: String
    @State private var accentName: String

    init(account: PortfolioAccount?, onSave: @escaping (PortfolioAccountDraft) -> Void) {
        self.account = account
        self.onSave = onSave
        _name = State(initialValue: account?.name ?? "")
        _iconName = State(initialValue: account?.iconName ?? "briefcase.fill")
        _accentName = State(initialValue: account?.accentName == "purple" ? "red" : account?.accentName ?? "teal")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                }

                Section("Icon") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 14) {
                        ForEach(Self.icons, id: \.self) { icon in
                            Button {
                                iconName = icon
                            } label: {
                                Image(systemName: icon)
                                    .font(.title2)
                                    .foregroundStyle(iconName == icon ? selectedColor : .secondary)
                                    .frame(width: 46, height: 46)
                                    .background(
                                        iconName == icon ? selectedColor.opacity(0.14) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(icon)
                            .accessibilityAddTraits(iconName == icon ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Color") {
                    HStack {
                        ForEach(Self.colors, id: \.self) { colorName in
                            Button {
                                accentName = colorName
                            } label: {
                                Circle()
                                    .fill(color(for: colorName))
                                    .frame(width: 30, height: 30)
                                    .overlay {
                                        if accentName == colorName {
                                            Image(systemName: "checkmark")
                                                .font(.caption.bold())
                                                .foregroundStyle(.white)
                                        }
                                    }
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(colorName.capitalized)
                            .accessibilityAddTraits(accentName == colorName ? .isSelected : [])
                        }
                    }
                }
            }
            .navigationTitle(account == nil ? "New Portfolio" : "Edit Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(
                            PortfolioAccountDraft(
                                name: trimmedName,
                                iconName: iconName,
                                accentName: accentName
                            )
                        )
                        dismiss()
                    }
                    .disabled(trimmedName.isEmpty)
                }
            }
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var selectedColor: Color {
        color(for: accentName)
    }

    private func color(for name: String) -> Color {
        switch name {
        case "blue": .blue
        case "indigo": .indigo
        case "orange": .orange
        case "red", "purple": .red
        default: Color(red: 0.20, green: 0.62, blue: 0.57)
        }
    }
}
