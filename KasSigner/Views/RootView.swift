import SwiftUI
import UIKit

struct SubtlePressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

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
        case portfolio
        case utxos
        case settings
    }

    @EnvironmentObject private var walletStore: WalletStore
    @EnvironmentObject private var engine: KasSignerEngine
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var syncService: WalletSyncService
    @EnvironmentObject private var liveRPCService: KaspaLiveRPCService
    @EnvironmentObject private var copyFeedbackCenter: CopyFeedbackCenter
    @Environment(\.scenePhase) private var scenePhase

    @State private var selectedTab: Tab = .wallet
    @State private var showingAddWallet = false
    @State private var notificationRefreshTask: Task<Void, Never>?

    var body: some View {
        TabView(selection: $selectedTab) {
            WalletHomeView()
                .tag(Tab.wallet)
                .tabItem { Label("Wallet", systemImage: "wallet.pass") }

            ActivityView()
                .tag(Tab.activity)
                .tabItem { Label("Transactions", systemImage: "clock.arrow.circlepath") }

            PortfolioView()
                .tag(Tab.portfolio)
                .tabItem { Label("Portfolio", systemImage: "briefcase.fill") }

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
        .background {
            WalletTabContextMenu(
                profiles: walletStore.profiles,
                selectedProfileID: walletStore.selectedProfileID,
                onSelect: selectWallet,
                onAddWallet: {
                    selectedTab = .wallet
                    showingAddWallet = true
                }
            )
        }
        .sheet(isPresented: $showingAddWallet) {
            AddWalletView()
        }
        .overlay {
            GeometryReader { proxy in
                if let message = copyFeedbackCenter.message {
                    VStack {
                        Spacer()
                        HStack(spacing: 7) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(message)
                                .foregroundStyle(.primary)
                        }
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.regularMaterial, in: Capsule())
                            .shadow(radius: 8, y: 3)
                            .padding(.bottom, proxy.safeAreaInsets.bottom + 58)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .accessibilityAddTraits(.isStaticText)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .allowsHitTesting(false)
        }
        .task(id: launchRefreshTaskID) {
            await refreshAfterLaunchOrActivation()
        }
        .onChange(of: liveRPCService.notificationVersion) { _, _ in
            scheduleNotificationRefresh()
        }
        .onChange(of: syncService.snapshot) { _, snapshot in
            guard let snapshot,
                  let profile = walletStore.selectedProfile else { return }
            Task {
                await liveRPCService.configure(
                    profile: profile,
                    nodeURL: snapshot.nodeURL,
                    engine: engine
                )
            }
        }
        .onChange(of: syncService.isNetworkAvailable) { wasAvailable, isAvailable in
            Task {
                await liveRPCService.setNetworkAvailable(
                    isAvailable,
                    engine: engine
                )

                guard !wasAvailable,
                      isAvailable,
                      scenePhase == .active,
                      let profile = walletStore.selectedProfile else { return }
                await syncService.refresh(
                    profile: profile,
                    walletStore: walletStore,
                    engine: engine,
                    preferences: preferences,
                    force: true
                )
            }
        }
        .onDisappear {
            notificationRefreshTask?.cancel()
            notificationRefreshTask = nil
        }
    }

    private func selectWallet(_ profile: WalletProfile) {
        walletStore.selectedProfileID = profile.id
        syncService.preload(profile: profile)
        selectedTab = .wallet
    }

    private var launchRefreshTaskID: String {
        let profileID = walletStore.selectedProfileID?.uuidString ?? "no-profile"
        let phase = scenePhase == .active ? "active" : "inactive"
        return "\(profileID)-\(phase)"
    }

    private func refreshAfterLaunchOrActivation() async {
        let isActive = scenePhase == .active
        await engine.setRuntimeActive(isActive)
        await liveRPCService.setRuntimeActive(isActive, engine: engine)

        guard isActive,
              let profile = walletStore.selectedProfile else { return }

        engine.startIfNeeded()

        // Let the first frame and tab bar become interactive before any
        // WebKit or network synchronization work begins under Xcode.
        try? await Task.sleep(for: .milliseconds(0))
        guard !Task.isCancelled else { return }

        await syncService.refresh(
            profile: profile,
            walletStore: walletStore,
            engine: engine,
            preferences: preferences,
            force: false,
            minimumInterval: 9
        )

        if let snapshot = syncService.snapshot,
           let currentProfile = walletStore.selectedProfile {
            await liveRPCService.configure(
                profile: currentProfile,
                nodeURL: snapshot.nodeURL,
                engine: engine
            )
        }
    }

    private func scheduleNotificationRefresh() {
        guard scenePhase == .active,
              let profileID = walletStore.selectedProfileID
        else {
            return
        }

        notificationRefreshTask?.cancel()
        notificationRefreshTask = Task { @MainActor in
            // Match Kaspium's UTXO notification debounce window so a burst
            // of added/removed outputs produces one wallet reconciliation.
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }

            // If another refresh is already committing a snapshot, wait for
            // it and then reconcile once more so no later notification is lost.
            while syncService.state == .syncing {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
            }

            guard scenePhase == .active,
                  walletStore.selectedProfileID == profileID,
                  let profile = walletStore.selectedProfile
            else {
                return
            }

            await syncService.refresh(
                profile: profile,
                walletStore: walletStore,
                engine: engine,
                preferences: preferences,
                force: true
            )
        }
    }
}

private struct WalletTabContextMenu: UIViewControllerRepresentable {
    let profiles: [WalletProfile]
    let selectedProfileID: UUID?
    let onSelect: (WalletProfile) -> Void
    let onAddWallet: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            profiles: profiles,
            selectedProfileID: selectedProfileID,
            onSelect: onSelect,
            onAddWallet: onAddWallet
        )
    }

    func makeUIViewController(context: Context) -> InstallerViewController {
        let controller = InstallerViewController()
        controller.onTabBarAvailable = { tabBar in
            context.coordinator.installIfNeeded(on: tabBar)
        }
        return controller
    }

    func updateUIViewController(
        _ uiViewController: InstallerViewController,
        context: Context
    ) {
        context.coordinator.profiles = profiles
        context.coordinator.selectedProfileID = selectedProfileID
        context.coordinator.onSelect = onSelect
        context.coordinator.onAddWallet = onAddWallet
        uiViewController.findTabBar()
    }

    final class InstallerViewController: UIViewController {
        var onTabBarAvailable: ((UITabBar) -> Void)?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            findTabBar()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            findTabBar()
        }

        func findTabBar() {
            guard let rootView = view.window?.rootViewController?.view,
                  let tabBar = findTabBar(in: rootView) else { return }
            onTabBarAvailable?(tabBar)
        }

        private func findTabBar(in view: UIView) -> UITabBar? {
            if let tabBar = view as? UITabBar {
                return tabBar
            }

            for subview in view.subviews {
                if let tabBar = findTabBar(in: subview) {
                    return tabBar
                }
            }

            return nil
        }
    }

    final class Coordinator: NSObject, UIContextMenuInteractionDelegate {
        var profiles: [WalletProfile]
        var selectedProfileID: UUID?
        var onSelect: (WalletProfile) -> Void
        var onAddWallet: () -> Void

        private weak var installedWalletControl: UIControl?
        private var interaction: UIContextMenuInteraction?

        init(
            profiles: [WalletProfile],
            selectedProfileID: UUID?,
            onSelect: @escaping (WalletProfile) -> Void,
            onAddWallet: @escaping () -> Void
        ) {
            self.profiles = profiles
            self.selectedProfileID = selectedProfileID
            self.onSelect = onSelect
            self.onAddWallet = onAddWallet
        }

        func installIfNeeded(on tabBar: UITabBar) {
            let itemControls = tabBar.subviews
                .compactMap { $0 as? UIControl }
                .filter { !$0.isHidden && $0.alpha > 0 }
                .sorted { $0.frame.minX < $1.frame.minX }

            guard let walletControl = itemControls.first,
                  installedWalletControl !== walletControl else { return }

            if let installedWalletControl, let interaction {
                installedWalletControl.removeInteraction(interaction)
            }

            let interaction = UIContextMenuInteraction(delegate: self)
            walletControl.addInteraction(interaction)
            installedWalletControl = walletControl
            self.interaction = interaction
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            configurationForMenuAtLocation location: CGPoint
        ) -> UIContextMenuConfiguration? {
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) {
                [weak self] _ in
                self?.walletMenu()
            }
        }

        private func walletMenu() -> UIMenu {
            let walletActions = profiles.map { profile in
                UIAction(
                    title: profile.name,
                    image: UIImage(systemName: "wallet.pass"),
                    state: profile.id == selectedProfileID ? .on : .off
                ) { [weak self] _ in
                    self?.onSelect(profile)
                }
            }

            let addAction = UIAction(
                title: "New Account",
                image: UIImage(systemName: "plus")
            ) { [weak self] _ in
                self?.onAddWallet()
            }

            let accounts = UIMenu(options: .displayInline, children: walletActions)
            let addAccount = UIMenu(options: .displayInline, children: [addAction])
            return UIMenu(children: [accounts, addAccount])
        }
    }
}

struct UTXOsView: View {
    @EnvironmentObject private var walletStore: WalletStore
    @EnvironmentObject private var engine: KasSignerEngine
    @EnvironmentObject private var syncService: WalletSyncService
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var coinControlStore: UTXOCoinControlStore
    @Environment(\.openURL) private var openURL

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
                        systemImage: "square.stack.3d.up"
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
                coinControlStore.activate(profileID: newValue)
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
    private func refreshUTXOs() async {
        guard let profile = walletStore.selectedProfile else { return }
        await syncService.refresh(
            profile: profile,
            walletStore: walletStore,
            engine: engine,
            preferences: preferences,
            force: true
        )
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
                            statusRow(for: utxo)
                                .font(.body.weight(.semibold))

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
                .buttonStyle(SubtlePressButtonStyle())
            }

            Divider()

            HStack(alignment: .center, spacing: 8) {
                Text("Label")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 46, alignment: .leading)

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
                .buttonStyle(SubtlePressButtonStyle())
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
    }

    @ViewBuilder
    private func statusRow(for utxo: WalletUTXO) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Spacer(minLength: 14)

            if utxo.blockDAAScore > 0 {
                Text("Confirmed")
                    .foregroundStyle(
                        Color(red: 0.18, green: 0.68, blue: 0.62)
                    )
            } else {
                Text("Not confirmed")
                    .foregroundStyle(.orange)
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

}
