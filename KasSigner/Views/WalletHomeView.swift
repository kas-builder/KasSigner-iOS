import SwiftUI
import UIKit

struct WalletHomeView: View {
    private enum WalletRoute: Hashable {
        case receive(UUID)
    }

    @State private var navigationPath = NavigationPath()
    @State private var showingSendFlow = false
    @Environment(\.legibilityWeight) private var legibilityWeight
    @EnvironmentObject private var walletStore: WalletStore
    @EnvironmentObject private var engine: KasSignerEngine
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var syncService: WalletSyncService
    @EnvironmentObject private var priceService: PriceService
    @EnvironmentObject private var coinControlStore: UTXOCoinControlStore
    @EnvironmentObject private var copyFeedbackCenter: CopyFeedbackCenter
    @State private var showingAddWallet = false
    @State private var showingSecondaryCurrency = false

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if let profile = walletStore.selectedProfile {
                    walletContent(profile)
                } else {
                    ContentUnavailableView {
                        Label("No Account", systemImage: "wallet.pass")
                    } description: {
                        Text("Import the public wallet data exported by KasSigner. Private keys remain on the M5 device.")
                    } actions: {
                        Button("Add KasSigner Account") { showingAddWallet = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle(walletStore.selectedProfile == nil ? "KasSigner" : "")
            .navigationBarTitleDisplayMode(walletStore.selectedProfile == nil ? .large : .inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingAddWallet = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddWallet) {
                AddWalletView()
            }
            .task {
                async let walletRefresh: Void = refreshSelectedWallet(force: false)
                async let priceRefresh: Void = priceService.refresh(preferences: preferences)
                _ = await (walletRefresh, priceRefresh)
            }
            .navigationDestination(for: WalletRoute.self) { route in
                switch route {
                case .receive(let profileID):
                    if let profile = walletStore.profiles.first(where: { $0.id == profileID }) {
                        ReceiveView(profile: profile)
                    } else {
                        ContentUnavailableView(
                            "Account Unavailable",
                            systemImage: "wallet.pass",
                            description: Text("Return to the Wallet screen and select an account.")
                        )
                    }
                }
            }
        }
        .onChange(of: walletStore.selectedProfileID) { oldValue, newValue in
            guard oldValue != newValue else { return }
            showingSendFlow = false
            navigationPath = NavigationPath()
        }
    }

    private func walletContent(_ profile: WalletProfile) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 0) {
                    Text("Kas")
                        .foregroundStyle(.primary)
                    Text("Signer")
                        .foregroundStyle(.primary)
                }
                .font(.largeTitle.weight(.bold))
                    .offset(y: -12)
                    .padding(.bottom, -10)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 5) {
                        Text(profile.name)
                            .font(.headline)

                        Spacer()
                    }

                    Button {
                        showingSecondaryCurrency.toggle()
                        if showingSecondaryCurrency {
                            Task {
                                await priceService.refresh(preferences: preferences)
                            }
                        }
                    } label: {
                        HStack(alignment: .center, spacing: 9) {
                            Text(balanceDisplayText)
                                .font(
                                    .system(
                                        size: 42,
                                        weight: legibilityWeight == .bold ? .medium : .semibold,
                                        design: .rounded
                                    )
                                )
                                .lineLimit(1)
                                .minimumScaleFactor(0.48)
                                .allowsTightening(true)
                                .layoutPriority(1)

                            if !balanceUnitText.isEmpty {
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
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(1)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(SubtlePressButtonStyle())
                    .contentTransition(.numericText())
                    .sensoryFeedback(.selection, trigger: showingSecondaryCurrency)
                    .accessibilityLabel(balanceAccessibilityLabel)
                    .accessibilityHint("Double tap to switch between KAS and \(preferences.secondaryCurrency.displayName).")
                    Button {
                        copyWalletHomeReceiveAddress(for: profile)
                    } label: {
                        Text(walletHomeReceiveAddress(for: profile))
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(SubtlePressButtonStyle())
                    .disabled(profile.receiveAddresses.isEmpty)
                    .accessibilityHint("Copies the full receive address")
                }

                HStack(spacing: 10) {
                    NavigationLink(value: WalletRoute.receive(profile.id)) {
                        compactActionLabel("Receive", systemImage: "arrow.down")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        showingSendFlow = true
                    } label: {
                        compactActionLabel("Send", systemImage: "arrow.up")
                    }
                    .buttonStyle(.bordered)
                }

                if let snapshot = syncService.snapshot {
                    VStack(alignment: .leading, spacing: 12) {
                        LabeledContent("UTXOs", value: "\(snapshot.balance.utxoCount)")
                        TimelineView(.periodic(from: .now, by: 9)) { context in
                            LabeledContent("Last refreshed", value: relativeAge(from: snapshot.syncedAt, now: context.date))
                        }
                    }
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                } else if syncService.state == .syncing {
                    HStack(spacing: 8) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)

                        Text("Connecting...")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            .padding()
        }
        .refreshable {
            async let walletRefresh: Void = refreshSelectedWallet(force: true)
            async let priceRefresh: Void = priceService.refresh(
                preferences: preferences,
                force: true
            )
            _ = await (walletRefresh, priceRefresh)
        }
        .navigationDestination(isPresented: $showingSendFlow) {
            SendUTXOSelectionView(
                profile: profile,
                clearSelectionOnAppear: true,
                showingSendFlow: $showingSendFlow
            )
        }
    }

    private func walletHomeReceiveAddress(for profile: WalletProfile) -> String {
        guard !profile.receiveAddresses.isEmpty else {
            return "No receive address"
        }

        let index = walletStore.lastViewedReceiveIndex(
            for: profile.id,
            addressCount: profile.receiveAddresses.count
        )

        return profile.receiveAddresses[index]
    }

    private func copyWalletHomeReceiveAddress(for profile: WalletProfile) {
        guard !profile.receiveAddresses.isEmpty else { return }
        let address = walletHomeReceiveAddress(for: profile)
        UIPasteboard.general.string = address
        copyFeedbackCenter.showCopied(address)
    }

    private var balanceAmountText: String {
        guard let balance = syncService.snapshot?.balance.totalKas else { return "" }
        guard showingSecondaryCurrency else {
            return KasBalanceFormatter.string(
                from: balance,
                decimalPlaces: preferences.kasBalanceDecimalPlaces
            )
        }
        guard let converted = priceService.convertedBalance(
            kas: balance,
            currency: preferences.secondaryCurrency
        ) else {
            return "—"
        }

        switch preferences.secondaryCurrency {
        case .btc:
            return converted.formatted(.number.precision(.fractionLength(0...8)))
        case .usd:
            return converted.formatted(.number.precision(.fractionLength(2)))
        }
    }

    private var balanceUnitText: String {
        guard syncService.snapshot?.balance.totalKas != nil else { return "" }
        return showingSecondaryCurrency ? preferences.secondaryCurrency.rawValue.uppercased() : "KAS"
    }

    private var balanceDisplayText: String {
        guard !balanceAmountText.isEmpty else { return "" }
        return "\(balanceAmountText) \(balanceUnitText)"
    }

    private var balanceAccessibilityLabel: String {
        guard !balanceAmountText.isEmpty else { return "Balance unavailable" }
        return "\(balanceAmountText) \(balanceUnitText)"
    }

    private func refreshSelectedWallet(force: Bool) async {
        guard let profile = walletStore.selectedProfile else { return }
        if !force, syncService.snapshot != nil { return }
        await syncService.refresh(
            profile: profile,
            walletStore: walletStore,
            engine: engine,
            preferences: preferences,
            force: true
        )
    }

    private func compactActionLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
    }

    private func relativeAge(from timestamp: TimeInterval, now: Date) -> String {
        let elapsed = max(0, Int(now.timeIntervalSince1970 - timestamp))
        if elapsed < 60 { return "\(elapsed) sec ago" }
        let minutes = elapsed / 60
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        return "\(hours) hr ago"
    }
}

struct SendUTXOSelectionView: View {
    let profile: WalletProfile
    let clearSelectionOnAppear: Bool
    @Binding var showingSendFlow: Bool

    @EnvironmentObject private var syncService: WalletSyncService
    @EnvironmentObject private var coinControlStore: UTXOCoinControlStore
    @State private var showingUTXOSelectionLimit = false

    private let accentColor = Color(red: 0.20, green: 0.62, blue: 0.57)

    var body: some View {
        Group {
            if utxos.isEmpty {
                ContentUnavailableView(
                    "No Spendable UTXOs",
                    systemImage: "square.stack.3d.up.slash",
                    description: Text("Refresh the wallet before creating a transaction.")
                )
            } else {
                VStack(spacing: 0) {
                    selectionHeader
                        .padding(.horizontal, 14)
                        .padding(.top, 8)
                        .padding(.bottom, 10)
                        .background(Color(.systemGroupedBackground))

                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(utxos) { utxo in
                                sendUTXOCard(utxo)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 20)
                    }
                    .background(Color(.systemGroupedBackground))

                    NavigationLink {
                        SendDestinationView(
                            profile: profile,
                            selectedUTXOs: selectedUTXOs,
                            showingSendFlow: $showingSendFlow
                        )
                    } label: {
                        Text(selectedUTXOs.count == 1 ? "Send UTXO" : "Send UTXOs")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedUTXOs.isEmpty)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial)
                }
            }
        }
        .navigationTitle("Select UTXOs")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground))
        .onAppear {
            coinControlStore.activate(profileID: profile.id)
            if clearSelectionOnAppear {
                coinControlStore.clearSelection()
            }
        }
        .alert("Eight-UTXO limit", isPresented: $showingUTXOSelectionLimit) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("KasSigner supports at most 8 selected UTXOs in one transaction. Additional UTXOs were not selected.")
        }
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

    private var selectedUTXOs: [WalletUTXO] {
        coinControlStore.selectedUTXOs(from: utxos)
    }

    private var maximumSelectableCount: Int {
        min(utxos.count, UTXOCoinControlStore.maximumSelectedUTXOs)
    }

    private var selectedTotalSompi: UInt64? {
        selectedUTXOs.reduce(into: UInt64?.some(0)) { total, utxo in
            guard let current = total else { return }
            let addition = current.addingReportingOverflow(utxo.amount)
            total = addition.overflow ? nil : addition.partialValue
        }
    }

    private var selectionHeader: some View {
        VStack(spacing: 11) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Selected")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(selectedUTXOs.count) UTXO\(selectedUTXOs.count == 1 ? "" : "s")")
                        .font(.system(size: 16, weight: .semibold))
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("Input total")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(
                        selectedTotalSompi.map {
                            formatKas(sompi: $0)
                        } ?? "Invalid total"
                    )
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                }
            }

            HStack(spacing: 10) {
                Button(selectedUTXOs.count == maximumSelectableCount
                    ? "Clear All"
                    : (utxos.count > UTXOCoinControlStore.maximumSelectedUTXOs
                        ? "Select First 8"
                        : "Select All")) {
                    if selectedUTXOs.count == maximumSelectableCount {
                        coinControlStore.clearSelection()
                    } else {
                        if coinControlStore.selectAll(utxos) > 0 {
                            showingUTXOSelectionLimit = true
                        }
                    }
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.bordered)

                if !selectedUTXOs.isEmpty && selectedUTXOs.count != maximumSelectableCount {
                    Button("Clear") {
                        coinControlStore.clearSelection()
                    }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.bordered)
                }

                Spacer()
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    private func sendUTXOCard(_ utxo: WalletUTXO) -> some View {
        let selected = coinControlStore.isSelected(utxo)
        let label = coinControlStore.label(for: utxo)

        return Button {
            if !coinControlStore.toggle(utxo) {
                showingUTXOSelectionLimit = true
            }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    Text(formatKas(sompi: utxo.amount))
                        .font(.body.weight(.regular).monospacedDigit())
                        .foregroundStyle(.primary)

                    Spacer()

                    Text(utxo.blockDAAScore > 0 ? "Confirmed" : "Not confirmed")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(
                            utxo.blockDAAScore > 0
                                ? Color(red: 0.18, green: 0.68, blue: 0.62)
                                : Color.orange
                        )
                }

                Divider()

                VStack(alignment: .leading, spacing: 5) {
                    Text("Transaction ID")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text(utxo.txID)
                        .font(.caption.monospaced())
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Divider()

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Label")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 46, alignment: .leading)

                    if !label.isEmpty {
                        Text(label)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
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
                        selected ? accentColor.opacity(0.78) : Color.primary.opacity(0.05),
                        lineWidth: selected ? 2 : 1
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(SubtlePressButtonStyle())
    }

    private func formatKas(sompi: UInt64) -> String {
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
