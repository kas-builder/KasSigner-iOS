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

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PortfolioAccount.createdAt) private var accounts: [PortfolioAccount]

    @State private var selectedAccountID: UUID?
    @State private var selectedRange: TimeRange = .day
    @State private var accountBeingEdited: PortfolioAccount?
    @State private var accountPendingDeletion: PortfolioAccount?
    @State private var showingAccountEditor = false

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
            .navigationTitle("Portfolio")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        beginAddingAccount()
                    } label: {
                        Image(systemName: "plus")
                    }
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
        .onChange(of: accounts.map(\.id)) { _, accountIDs in
            guard let selectedAccountID else { return }
            if !accountIDs.contains(selectedAccountID) {
                self.selectedAccountID = nil
            }
        }
        .task {
            migrateLegacyPortfolioIcons()
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Portfolio Accounts", systemImage: "briefcase.fill")
        } description: {
            Text("Create a local account to start tracking KAS buys, sells, and transfers.")
        } actions: {
            Button("Add Account") {
                beginAddingAccount()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var portfolioContent: some View {
        ScrollView {
            VStack(spacing: 16) {
                accountSelector
                valueCard
                chartCard
                holdingsCard
                transactionsCard
            }
            .padding()
        }
    }

    private var accountSelector: some View {
        Menu {
            Button {
                selectedAccountID = nil
            } label: {
                if selectedAccountID == nil {
                    Label("All Accounts", systemImage: "checkmark")
                } else {
                    Text("All Accounts")
                }
            }

            Divider()

            ForEach(accounts) { account in
                Button {
                    selectedAccountID = account.id
                } label: {
                    if selectedAccountID == account.id {
                        Label(account.name, systemImage: "checkmark")
                    } else {
                        Text(account.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selectedAccount?.iconName ?? "square.stack.3d.up.fill")
                    .font(.headline)
                    .foregroundStyle(selectedAccount.map(accountColor) ?? teal)
                    .frame(width: 34, height: 34)
                    .background(.thinMaterial, in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text("Viewing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(selectedAccount?.name ?? "All Accounts")
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(SubtlePressButtonStyle())
    }

    private var valueCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Portfolio Value")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(0, format: .currency(code: "USD"))
                .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.65)

            Text("Add transactions to calculate performance")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
                                selectedRange == range ? teal.opacity(0.18) : .clear,
                                in: Capsule()
                            )
                            .foregroundStyle(selectedRange == range ? teal : .secondary)
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

    private var holdingsCard: some View {
        placeholderCard(
            title: "Holdings",
            message: "KAS amount, average cost, current value, and performance will appear here.",
            systemImage: "bitcoinsign.circle"
        )
    }

    private var transactionsCard: some View {
        placeholderCard(
            title: "Transactions",
            message: "Buys, sells, and transfers will appear here.",
            systemImage: "arrow.left.arrow.right"
        )
    }

    private func placeholderCard(title: String, message: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)

            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(teal)
                    .frame(width: 38, height: 38)
                    .background(teal.opacity(0.12), in: Circle())

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var selectedAccount: PortfolioAccount? {
        guard let selectedAccountID else { return nil }
        return accounts.first(where: { $0.id == selectedAccountID })
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
            accountBeingEdited.accountDescription = draft.accountDescription
            accountBeingEdited.iconName = draft.iconName
            accountBeingEdited.accentName = draft.accentName
        } else {
            let account = PortfolioAccount(
                name: draft.name,
                accountDescription: draft.accountDescription,
                iconName: draft.iconName,
                accentName: draft.accentName
            )
            modelContext.insert(account)
            selectedAccountID = account.id
        }

        try? modelContext.save()
        self.accountBeingEdited = nil
    }

    private func deleteAccount(_ account: PortfolioAccount) {
        if selectedAccountID == account.id {
            selectedAccountID = nil
        }
        modelContext.delete(account)
        try? modelContext.save()
        accountPendingDeletion = nil
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
        case "purple": .purple
        default: teal
        }
    }
}

private struct PortfolioAccountDraft {
    let name: String
    let accountDescription: String
    let iconName: String
    let accentName: String
}

private struct PortfolioAccountEditor: View {
    private static let icons = [
        "briefcase.fill",
        "wallet.pass.fill",
        "building.columns.fill",
        "lock.shield.fill",
        "tray.full.fill"
    ]
    private static let colors = ["teal", "blue", "indigo", "orange", "purple"]

    @Environment(\.dismiss) private var dismiss

    let account: PortfolioAccount?
    let onSave: (PortfolioAccountDraft) -> Void

    @State private var name: String
    @State private var accountDescription: String
    @State private var iconName: String
    @State private var accentName: String

    init(account: PortfolioAccount?, onSave: @escaping (PortfolioAccountDraft) -> Void) {
        self.account = account
        self.onSave = onSave
        _name = State(initialValue: account?.name ?? "")
        _accountDescription = State(initialValue: account?.accountDescription ?? "")
        _iconName = State(initialValue: account?.iconName ?? "briefcase.fill")
        _accentName = State(initialValue: account?.accentName ?? "teal")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)

                    TextField("Description (Optional)", text: $accountDescription, axis: .vertical)
                        .lineLimit(2...4)
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
            .navigationTitle(account == nil ? "New Account" : "Edit Account")
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
                                accountDescription: accountDescription.trimmingCharacters(in: .whitespacesAndNewlines),
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
        case "purple": .purple
        default: Color(red: 0.20, green: 0.62, blue: 0.57)
        }
    }
}
