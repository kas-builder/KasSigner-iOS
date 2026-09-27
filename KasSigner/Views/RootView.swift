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

struct AccountDiscoveryLoadingView: View {
    let progress: Double
    let detail: String

    private let teal = Color(red: 0.20, green: 0.62, blue: 0.57)

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .opacity(0.96)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Image(systemName: "wallet.pass.fill")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(teal)

                Text("Running address discovery…")
                    .font(.title3.weight(.semibold))

                ProgressView(value: progress)
                    .tint(teal)
                    .frame(maxWidth: 300)
                    .animation(.linear(duration: 0.12), value: progress)

                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }
            .padding(28)
        }
        .accessibilityElement(children: .contain)
    }
}

@MainActor
final class AccountSwitchPresentationModel: ObservableObject {
    @Published private(set) var isVisible = false
    @Published private(set) var progress = 0.0
    @Published private(set) var detail = "Preparing address discovery…"

    private var startedAt: Date?
    private var workCompleted = false
    private var presentationTask: Task<Void, Never>?

    func start() {
        presentationTask?.cancel()
        isVisible = true
        progress = 0
        detail = "Preparing address discovery…"
        startedAt = Date()
        workCompleted = false

        presentationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled,
                  let self,
                  let startedAt = self.startedAt {
                let elapsed = Date().timeIntervalSince(startedAt)
                self.progress = min(0.9, (elapsed / 3) * 0.9)

                if self.workCompleted, elapsed >= 3 {
                    withAnimation(.easeOut(duration: 0.25)) {
                        self.progress = 1
                    }
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                    self.finish()
                    return
                }

                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    func update(_ discoveryProgress: WalletSyncService.DiscoveryProgress) {
        guard isVisible else { return }
        detail = discoveryProgress.detail
    }

    func complete() {
        guard isVisible else { return }
        detail = "Account ready"
        workCompleted = true
    }

    private func finish() {
        isVisible = false
        progress = 1
        startedAt = nil
        workCompleted = false
        presentationTask = nil
    }
}

struct AccountSwitchLoadingView: View {
    let progress: Double
    let detail: String

    private let teal = Color(red: 0.20, green: 0.62, blue: 0.57)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 18) {
                ProgressView(value: progress)
                    .tint(teal)
                    .frame(maxWidth: 260)

                Text("Switching account")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)

                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.68))
            }
            .padding(28)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Switching account. \(detail)")
    }
}

@MainActor
final class AccountDiscoveryPresentationModel: ObservableObject {
    @Published private(set) var isVisible = false
    @Published private(set) var progress = 0.04
    @Published private(set) var detail = "Preparing account discovery…"

    private var startedAt: Date?
    private var workCompletedAt: Date?
    private var presentationTask: Task<Void, Never>?

    func start() {
        guard !isVisible else { return }

        isVisible = true
        progress = 0.04
        detail = "Validating account…"
        startedAt = Date()
        workCompletedAt = nil

        presentationTask?.cancel()
        presentationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled,
                  let self,
                  let startedAt = self.startedAt {
                let currentTime = Date()
                let elapsed = currentTime.timeIntervalSince(startedAt)

                if let completedAt = self.workCompletedAt {
                    let readyStart = max(
                        startedAt.addingTimeInterval(9.25),
                        completedAt
                    )
                    if currentTime >= readyStart {
                        let readyElapsed = currentTime.timeIntervalSince(readyStart)
                        self.detail = "Account ready"
                        self.progress = min(
                            1,
                            0.92 + (readyElapsed / 0.75) * 0.08
                        )

                        let minimumEnd = startedAt.addingTimeInterval(10)
                        let completionEnd = readyStart.addingTimeInterval(0.75)
                        if currentTime >= max(minimumEnd, completionEnd) {
                            self.finish()
                            return
                        }
                    } else {
                        self.progress = min(
                            0.92,
                            0.04 + (elapsed / 9.25) * 0.88
                        )
                    }
                } else {
                    self.progress = min(
                        0.92,
                        0.04 + (elapsed / 10) * 0.88
                    )
                }

                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    func updateDetail(_ detail: String) {
        guard isVisible, workCompletedAt == nil else { return }
        self.detail = detail
    }

    func complete() {
        guard isVisible, workCompletedAt == nil else { return }
        workCompletedAt = Date()
    }

    func cancel() {
        presentationTask?.cancel()
        finish()
    }

    private func finish() {
        presentationTask = nil
        isVisible = false
        progress = 1
        startedAt = nil
        workCompletedAt = nil
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
    @StateObject private var discoveryPresentation =
        AccountDiscoveryPresentationModel()
    @StateObject private var accountSwitchPresentation =
        AccountSwitchPresentationModel()

    @State private var selectedTab: Tab = .wallet
    @State private var showingAddWallet = false
    @State private var notificationRefreshTask: Task<Void, Never>?
    @State private var notificationRefreshRequested = false
    @State private var confirmationResolutionTask: Task<Void, Never>?
    @State private var automaticallyRefreshedHistoryProfileID: UUID?

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

            SettingsView { profile in
                selectWallet(profile)
            }
                .tag(Tab.settings)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .disabled(
            isInitialDiscoveryBlocking
                || discoveryPresentation.isVisible
                || accountSwitchPresentation.isVisible
        )
        .environmentObject(discoveryPresentation)
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
                .environmentObject(discoveryPresentation)
        }
        .alert(
            "Wallet Discovery Notice",
            isPresented: Binding(
                get: {
                    syncService.discoveryNotice != nil
                        && !isInitialDiscoveryBlocking
                },
                set: { isPresented in
                    if !isPresented {
                        syncService.clearDiscoveryNotice()
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                syncService.clearDiscoveryNotice()
            }
        } message: {
            Text(syncService.discoveryNotice ?? "")
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
        .overlay {
            if isInitialDiscoveryBlocking || discoveryPresentation.isVisible {
                initialDiscoveryOverlay
            }
        }
        .overlay {
            if accountSwitchPresentation.isVisible {
                AccountSwitchLoadingView(
                    progress: accountSwitchPresentation.progress,
                    detail: accountSwitchPresentation.detail
                )
                .transition(.opacity)
                .zIndex(10)
            }
        }
        .onAppear {
            if isInitialDiscoveryBlocking {
                discoveryPresentation.start()
            }
        }
        .onChange(of: isInitialDiscoveryBlocking) { wasBlocking, isBlocking in
            if isBlocking {
                discoveryPresentation.start()
            } else if wasBlocking {
                discoveryPresentation.complete()
            }
        }
        .onChange(of: syncService.initialDiscoveryProgress) { _, progress in
            guard let progress else { return }
            if isInitialDiscoveryBlocking || discoveryPresentation.isVisible {
                discoveryPresentation.updateDetail(progress.detail)
            } else {
                accountSwitchPresentation.update(progress)
            }
        }
        .task(id: launchRefreshTaskID) {
            await refreshAfterLaunchOrActivation()
        }
        .onChange(of: liveRPCService.notificationVersion) { _, _ in
            scheduleNotificationRefresh()
        }
        .onChange(of: engine.rpcNotificationVersion) { _, _ in
            scheduleNotificationRefresh()
        }
        .onChange(of: syncService.snapshot) { _, snapshot in
            guard let snapshot,
                  let profile = walletStore.selectedProfile,
                  !profile.requiresInitialDiscovery else { return }
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
                    force: true,
                    addressDiscoveryPolicy: .comprehensive
                )
            }
        }
        .onDisappear {
            notificationRefreshTask?.cancel()
            notificationRefreshTask = nil
            confirmationResolutionTask?.cancel()
            confirmationResolutionTask = nil
        }
    }

    private var isInitialDiscoveryBlocking: Bool {
        walletStore.selectedProfile?.requiresInitialDiscovery == true
    }

    @ViewBuilder
    private var initialDiscoveryOverlay: some View {
        if let error = syncService.initialDiscoveryError {
            ZStack {
                Color(.systemBackground)
                    .opacity(0.96)
                    .ignoresSafeArea()

                VStack(spacing: 18) {
                    Image(systemName: "wallet.pass.fill")
                        .font(.system(size: 42, weight: .semibold))
                        .foregroundStyle(Color(red: 0.20, green: 0.62, blue: 0.57))
                    Text("Wallet discovery paused")
                        .font(.title3.weight(.semibold))
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 340)
                    Button("Retry Discovery") {
                        retryInitialDiscovery()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.20, green: 0.62, blue: 0.57))

                    Button("Cancel Import", role: .destructive) {
                        discoveryPresentation.cancel()
                        syncService.reset()
                        walletStore.discardPendingImport()
                    }
                }
                .padding(28)
            }
            .accessibilityElement(children: .contain)
        } else {
            AccountDiscoveryLoadingView(
                progress: discoveryPresentation.progress,
                detail: discoveryPresentation.detail
            )
        }
    }

    private func retryInitialDiscovery() {
        guard let profile = walletStore.selectedProfile else { return }
        Task {
            await syncService.refresh(
                profile: profile,
                walletStore: walletStore,
                engine: engine,
                preferences: preferences,
                force: true,
                addressDiscoveryPolicy: .comprehensive
            )
        }
    }

    private func selectWallet(_ profile: WalletProfile) {
        let isChangingAccount = walletStore.selectedProfileID != profile.id
        notificationRefreshTask?.cancel()
        notificationRefreshTask = nil
        notificationRefreshRequested = false
        confirmationResolutionTask?.cancel()
        confirmationResolutionTask = nil
        walletStore.selectedProfileID = profile.id
        walletStore.reloadCachedTransactions(profileID: profile.id)
        syncService.preload(profile: profile)
        selectedTab = .wallet
        if isChangingAccount {
            accountSwitchPresentation.start()
        }
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
        let isInitialImportedWalletSync = profile.requiresInitialDiscovery
        let shouldAutomaticallyRefreshHistory =
            automaticallyRefreshedHistoryProfileID != profile.id
        let historyUpdatedAtBeforeRefresh = syncService.transactionHistoryUpdatedAt

        defer {
            syncService.completeTransactionHistoryReconciliation(profileID: profile.id)
        }

        engine.startIfNeeded()

        // Let the first frame and tab bar become interactive before any
        // WebKit or network synchronization work begins under Xcode.
        try? await Task.sleep(for: .milliseconds(0))
        guard !Task.isCancelled else { return }

        let previousUTXOs = syncService.snapshot?.utxos ?? []
        let previousOutpoints = Set(previousUTXOs.map(\.id))
        await syncService.refresh(
            profile: profile,
            walletStore: walletStore,
            engine: engine,
            preferences: preferences,
            force: false,
            minimumInterval: 9,
            includeTransactionHistory: shouldAutomaticallyRefreshHistory,
            keepTransactionProgressThroughReconciliation: isInitialImportedWalletSync,
            addressDiscoveryPolicy: .comprehensive,
            onWalletReady: {
                guard walletStore.selectedProfileID == profile.id else { return }
                accountSwitchPresentation.complete()
            }
        )
        if walletStore.selectedProfileID == profile.id {
            accountSwitchPresentation.complete()
        }

        if shouldAutomaticallyRefreshHistory,
           syncService.transactionHistoryUpdatedAt != historyUpdatedAtBeforeRefresh {
            automaticallyRefreshedHistoryProfileID = profile.id
        }

        guard !Task.isCancelled,
              walletStore.selectedProfileID == profile.id else { return }

        let currentUTXOs = syncService.snapshot?.utxos ?? []
        let currentOutpoints = Set(currentUTXOs.map(\.id))
        let removedOutpoints = previousOutpoints.subtracting(currentOutpoints)
        let addedUTXOs = currentUTXOs.filter {
            !previousOutpoints.contains($0.id)
        }
        if removedOutpoints.isEmpty {
            walletStore.recordObservedUTXOTransactions(
                profileID: profile.id,
                addedUTXOs: addedUTXOs
            )
        }
        let currentProfile = walletStore.profiles.first(where: { $0.id == profile.id })
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
        walletStore.reloadCachedTransactions(profileID: profile.id)
        await refreshConfirmationScoreIfNeeded(force: true)

        if let snapshot = syncService.snapshot,
           let currentProfile = walletStore.selectedProfile {
            await liveRPCService.configure(
                profile: currentProfile,
                nodeURL: snapshot.nodeURL,
                engine: engine
            )
            scheduleConfirmationResolution(profileID: currentProfile.id)
        }
    }

    private func refreshConfirmationScoreIfNeeded(
        force: Bool = false
    ) async {
        guard let profileID = walletStore.selectedProfileID else { return }
        let needsUpdates = walletStore.transactions.contains {
            $0.profileID == profileID
                && $0.needsConfirmationUpdates(
                    currentBlueScore: syncService.virtualBlueScore
                )
        }
        guard force || needsUpdates else { return }
        await syncService.refreshVirtualBlueScore(force: force)
    }

    private func scheduleNotificationRefresh() {
        guard scenePhase == .active,
              let profileID = walletStore.selectedProfileID
        else {
            return
        }

        notificationRefreshRequested = true
        guard notificationRefreshTask == nil else { return }

        notificationRefreshTask = Task { @MainActor in
            defer {
                notificationRefreshTask = nil
                notificationRefreshRequested = false
            }

            while !Task.isCancelled {
                // Coalesce the current burst, but never cancel reconciliation
                // that has already started. Notifications arriving during a
                // refresh request one guaranteed follow-up pass.
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                notificationRefreshRequested = false

                await performNotificationRefresh(profileID: profileID)
                guard notificationRefreshRequested else { return }
            }
        }
    }

    private func performNotificationRefresh(profileID: UUID) async {
        // If another refresh is already committing a snapshot, wait for it
        // and then reconcile once more so no notification is lost.
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
        let currentUTXOs = syncService.snapshot?.utxos ?? []
        let currentOutpoints = Set(currentUTXOs.map(\.id))
        let removedOutpoints = previousOutpoints.subtracting(currentOutpoints)
        let addedUTXOs = currentUTXOs.filter {
            !previousOutpoints.contains($0.id)
        }
        if removedOutpoints.isEmpty {
            walletStore.recordObservedUTXOTransactions(
                profileID: profile.id,
                addedUTXOs: addedUTXOs
            )
        }
        scheduleConfirmationResolution(profileID: profile.id)
        await syncService.reconcilePendingTransactions(
            profile: walletStore.profiles.first(where: { $0.id == profile.id }) ?? profile,
            walletStore: walletStore
        )
        await syncService.reconcileTransactionIDs(
            addedUTXOs.map(\.txID),
            profile: walletStore.profiles.first(where: { $0.id == profile.id }) ?? profile,
            walletStore: walletStore
        )
        if !removedOutpoints.isEmpty,
           let spentAddresses = try? await engine.addressesOwningUTXOs(
               previousUTXOs.filter { removedOutpoints.contains($0.id) },
               profile: profile
           ) {
            await syncService.reconcileRecentOutgoingTransactions(
                removedOutpointIDs: removedOutpoints,
                addresses: spentAddresses,
                profile: profile,
                walletStore: walletStore
            )
        }
        await syncService.reconcileRecentOutgoingTransactions(
            addresses: [],
            profile: profile,
            walletStore: walletStore
        )
        await syncService.reconcileTransactionsObservedByOtherWallets(
            profile: profile,
            walletStore: walletStore
        )
        await refreshConfirmationScoreIfNeeded()
        walletStore.reloadCachedTransactions(profileID: profile.id)
    }

    private func scheduleConfirmationResolution(profileID: UUID) {
        guard confirmationResolutionTask == nil else { return }

        confirmationResolutionTask = Task { @MainActor in
            defer { confirmationResolutionTask = nil }

            for _ in 0..<30 {
                guard !Task.isCancelled,
                      scenePhase == .active,
                      walletStore.selectedProfileID == profileID,
                      let profile = walletStore.selectedProfile
                else {
                    return
                }

                let hasUnresolved = walletStore.pendingTransactions.contains {
                    $0.profileID == profileID
                        && $0.acceptingBlockBlueScore == nil
                }
                guard hasUnresolved else { return }

                await syncService.reconcilePendingTransactions(
                    profile: profile,
                    walletStore: walletStore
                )

                guard walletStore.pendingTransactions.contains(where: {
                    $0.profileID == profileID
                        && $0.acceptingBlockBlueScore == nil
                }) else {
                    await refreshConfirmationScoreIfNeeded(force: true)
                    return
                }

                try? await Task.sleep(for: .seconds(1))
            }
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
    @EnvironmentObject private var priceService: PriceService
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
                        "No UTXOs",
                        systemImage: "square.stack.3d.up"
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
        let kycStatus = coinControlStore.kycStatus(for: utxo)

        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(formatKas(utxo.amountKas))
                                .font(.body.weight(.regular).monospacedDigit())
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .allowsTightening(true)
                                .foregroundStyle(.primary)

                            if let usdValue = usdValueText(for: utxo) {
                                Text(usdValue)
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 3) {
                            kycStatusMenu(for: utxo, status: kycStatus)

                            Text(utxoTypeLabel(for: utxo))
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .padding(.top, 3)
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

    private func kycStatusMenu(
        for utxo: WalletUTXO,
        status: UTXOKYCStatus?
    ) -> some View {
        Menu {
            Button {
                coinControlStore.setKYCStatus(.kyc, for: utxo)
            } label: {
                Label("KYC", systemImage: "exclamationmark.shield")
            }

            Button {
                coinControlStore.setKYCStatus(.nonKYC, for: utxo)
            } label: {
                Label("Non-KYC", systemImage: "checkmark.shield")
            }

            if status != nil {
                Divider()
                Button(role: .destructive) {
                    coinControlStore.setKYCStatus(nil, for: utxo)
                } label: {
                    Label("Clear Status", systemImage: "xmark.circle")
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: status == .kyc
                    ? "exclamationmark.shield.fill"
                    : status == .nonKYC
                        ? "checkmark.shield.fill"
                        : "shield.lefthalf.filled")
                Text(status?.title ?? "Set status")
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                (status == .kyc
                    ? Color.red
                    : status == .nonKYC ? Color.green : Color.secondary)
                    .opacity(0.14),
                in: Capsule()
            )
            .foregroundStyle(
                status == .kyc
                    ? Color.red
                    : status == .nonKYC ? Color.green : Color.secondary
            )
        }
        .fixedSize()
        .buttonStyle(.plain)
        .accessibilityLabel(
            status.map { "KYC status: \($0.title)" } ?? "Set KYC status"
        )
        .accessibilityHint("Choose whether this UTXO is KYC or Non-KYC.")
    }

    private func utxoTypeLabel(for utxo: WalletUTXO) -> String {
        switch utxo.derivationChain?.lowercased() {
        case "receive": "Receive"
        case "change": "Change"
        default: "Unknown"
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

    private func usdValueText(for utxo: WalletUTXO) -> String? {
        guard let price = priceService.price(for: .usd),
              price.isFinite,
              price > 0 else { return nil }

        return (utxo.amountKas * price).formatted(
            .currency(code: "USD")
                .precision(.fractionLength(2))
        )
    }

    private func shortTransactionID(_ transactionID: String) -> String {
        guard transactionID.count > 18 else { return transactionID }
        return "\(transactionID.prefix(14))…\(transactionID.suffix(10))"
    }

    private var accentColor: Color {
        Color(red: 0.20, green: 0.62, blue: 0.57)
    }

}
