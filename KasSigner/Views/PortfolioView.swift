import Charts
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct PortfolioView: View {
    private enum TimeRange: String, CaseIterable, Identifiable {
        case day = "24H"
        case week = "7D"
        case month = "30D"
        case quarter = "90D"
        case all = "All"

        var id: Self { self }

        var days: String? {
            switch self {
            case .day: "1"
            case .week: "7"
            case .month: "30"
            case .quarter: "90"
            case .all: nil
            }
        }
    }

    private enum PortfolioSection: String, CaseIterable, Identifiable {
        case holdings = "Overview"
        case transactions = "Transactions"

        var id: Self { self }
    }

    private enum AccountEditorPresentation: Identifiable {
        case create
        case edit(PortfolioAccount)

        var id: String {
            switch self {
            case .create: "create"
            case .edit(let account): account.id.uuidString
            }
        }

        var account: PortfolioAccount? {
            switch self {
            case .create: nil
            case .edit(let account): account
            }
        }
    }

    private struct CSVImportAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
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
    @State private var accountPendingDeletion: PortfolioAccount?
    @State private var accountEditorPresentation: AccountEditorPresentation?
    @State private var showingTransactionEditor = false
    @State private var transactionEditorDetent: PresentationDetent = .fraction(0.9)
    @State private var selectedTransaction: PortfolioTransaction?
    @State private var transactionBeingEdited: PortfolioTransaction?
    @State private var transactionPendingDeletion: PortfolioTransaction?
    @State private var openEditorAfterDetailDismisses = false
    @State private var showingHoldingDetail = false
    @State private var chartPoints: [PortfolioChartPoint] = []
    @State private var selectionChartPoints: [PortfolioChartPoint] = []
    @State private var chartValueDomain: ClosedRange<Double> = 0...1
    @State private var isLoadingChart = false
    @State private var chartLoadFailed = false
    @State private var selectedChartPoint: PortfolioChartPoint?
    @State private var showingCSVFileImporter = false
    @State private var csvImportPreview: PortfolioCSVImportPreview?
    @State private var csvImportAlert: CSVImportAlert?
    @State private var showingCSVFileExporter = false
    @State private var csvExportDocument: PortfolioCSVDocument?
    @State private var csvExportFileName = "KasSigner-Portfolio-Transactions"

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

                            Button {
                                showingCSVFileImporter = true
                            } label: {
                                Label("Import CSV", systemImage: "square.and.arrow.down")
                            }

                            Button {
                                beginCSVExport(for: selectedAccount)
                            } label: {
                                Label("Export CSV", systemImage: "square.and.arrow.up")
                            }
                            .disabled(transactionsForSelectedAccount.isEmpty)

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
        .sheet(item: $accountEditorPresentation) { presentation in
            PortfolioAccountEditor(account: presentation.account) { draft in
                saveAccount(draft, editing: presentation.account)
            }
        }
        .sheet(isPresented: $showingTransactionEditor) {
            PortfolioTransactionEditor(
                accounts: accounts,
                initialPortfolioID: transactionBeingEdited?.portfolioID ?? selectedPortfolioUUID,
                transaction: transactionBeingEdited,
                availableHoldingsByPortfolio: availableHoldingsByPortfolio,
                accentColor: activePortfolioColor
            ) { draft in
                saveTransaction(draft)
            }
            .id(transactionBeingEdited?.id.uuidString ?? "new-transaction")
            .presentationDetents([.fraction(0.9)], selection: $transactionEditorDetent)
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $selectedTransaction, onDismiss: {
            if openEditorAfterDetailDismisses {
                openEditorAfterDetailDismisses = false
                transactionEditorDetent = .fraction(0.9)
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
            .presentationDetents([.fraction(0.9)])
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
        .fileImporter(
            isPresented: $showingCSVFileImporter,
            allowedContentTypes: [.commaSeparatedText, .plainText]
        ) { result in
            handleCSVSelection(result)
        }
        .fileExporter(
            isPresented: $showingCSVFileExporter,
            document: csvExportDocument,
            contentType: .commaSeparatedText,
            defaultFilename: csvExportFileName
        ) { result in
            handleCSVExport(result)
        }
        .sheet(item: $csvImportPreview) { preview in
            PortfolioCSVImportPreviewView(
                preview: preview,
                portfolioName: accountName(for: preview.portfolioID) ?? "Unknown Portfolio",
                accentColor: activePortfolioColor,
                onCancel: { csvImportPreview = nil },
                onImport: { importCSVTransactions(preview) }
            )
            .presentationDetents([.fraction(0.9)])
            .presentationDragIndicator(.visible)
        }
        .alert(item: $csvImportAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
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
            await priceService.refresh(preferences: preferences)
        }
        .task(id: chartRequestID) {
            await loadChartHistory()
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

    @ViewBuilder
    private var portfolioContent: some View {
        if selectedSection == .holdings {
            ScrollView {
                VStack(spacing: 16) {
                    largePortfolioMenu
                    valueCard
                    chartCard
                    holdingsSection
                }
                .padding()
            }
        } else {
            VStack(spacing: 0) {
                VStack(spacing: 16) {
                    largePortfolioMenu
                    valueCard
                }
                .padding(.horizontal)
                .padding(.top)

                ScrollView {
                    transactionsSection
                        .padding(.horizontal)
                        .padding(.top, 16)
                        .padding(.bottom)
                }
            }
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

                Text(displayedPortfolioValueText)
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
                        selectedChartPoint = nil
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

            Group {
                if isLoadingChart && chartPoints.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 230)
                } else if chartLoadFailed && chartPoints.isEmpty {
                    ContentUnavailableView {
                        Label("Chart Unavailable", systemImage: "wifi.exclamationmark")
                    } actions: {
                        Button("Try Again") {
                            Task { await loadChartHistory() }
                        }
                    }
                    .frame(minHeight: 230)
                } else if chartPoints.isEmpty {
                    ContentUnavailableView("No Chart Data", systemImage: "chart.xyaxis.line")
                        .frame(minHeight: 230)
                } else {
                    portfolioChart
                }
            }
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var portfolioChart: some View {
        Chart {
            ForEach(chartPoints) { point in
                AreaMark(
                    x: .value("Time", point.timestamp),
                    yStart: .value("Baseline", chartValueDomain.lowerBound),
                    yEnd: .value("Portfolio Value", point.valueUSD)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [activePortfolioColor.opacity(0.28), activePortfolioColor.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                LineMark(
                    x: .value("Time", point.timestamp),
                    y: .value("Portfolio Value", point.valueUSD)
                )
                .foregroundStyle(activePortfolioColor)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            }

            if let selectedChartPoint {
                RuleMark(x: .value("Selected Time", selectedChartPoint.timestamp))
                    .foregroundStyle(activePortfolioColor)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

                PointMark(
                    x: .value("Selected Time", selectedChartPoint.timestamp),
                    y: .value("Selected Value", selectedChartPoint.valueUSD)
                )
                .foregroundStyle(activePortfolioColor)
                .symbolSize(55)
                .annotation(
                    position: .top,
                    spacing: 10,
                    overflowResolution: AnnotationOverflowResolution(
                        x: .fit(to: .chart),
                        y: .disabled
                    )
                ) {
                    Text(chartSelectionTime(selectedChartPoint.timestamp))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
                        .overlay {
                            Capsule()
                                .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                        }
                }
            }
        }
        .chartYScale(domain: chartValueDomain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    .foregroundStyle(.secondary.opacity(0.25))
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(chartAxisDate(date))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    .foregroundStyle(.secondary.opacity(0.25))
                AxisValueLabel {
                    if let amount = value.as(Double.self) {
                        Text(compactCurrency(amount))
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { gesture in
                                guard let plotFrameAnchor = proxy.plotFrame else { return }
                                let plotFrame = geometry[plotFrameAnchor]
                                let xPosition = gesture.location.x - plotFrame.origin.x
                                guard xPosition >= 0,
                                      xPosition <= plotFrame.width,
                                      let date: Date = proxy.value(atX: xPosition) else {
                                    return
                                }
                                let nearestPoint = nearestChartPoint(to: date)
                                if nearestPoint != selectedChartPoint {
                                    selectedChartPoint = nearestPoint
                                }
                            }
                            .onEnded { _ in
                                selectedChartPoint = nil
                            }
                    )
            }
        }
        .frame(height: 250)
        .animation(.easeInOut(duration: 0.2), value: selectedRange)
        .accessibilityLabel("Portfolio value chart")
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
        let displayedTransactions = visibleTransactions
        let lastTransactionID = displayedTransactions.last?.id

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Transactions")
                    .font(.headline)

                Spacer()

                Button(action: presentNewTransactionEditor) {
                    Image(systemName: "plus")
                        .font(.headline)
                }
                .buttonStyle(.plain)
                .foregroundStyle(activePortfolioColor)
                .accessibilityLabel("New Portfolio Transaction")
            }

            if displayedTransactions.isEmpty {
                HStack(spacing: 12) {
                    themedIcon("arrow.left.arrow.right")
                    Text("No Transactions")
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 24)
            } else {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(displayedTransactions) { transaction in
                        transactionRow(transaction)
                        if transaction.id != lastTransactionID {
                            Divider()
                        }
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
        Button(action: presentNewTransactionEditor) {
            Label("New Transaction", systemImage: "plus")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
        }
        .buttonStyle(.borderedProminent)
        .tint(activePortfolioColor)
        .accessibilityLabel("New Portfolio Transaction")
    }

    private func presentNewTransactionEditor() {
        transactionBeingEdited = nil
        transactionEditorDetent = .fraction(0.9)
        showingTransactionEditor = true
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

    private var availableHoldingsByPortfolio: [UUID: Double] {
        Dictionary(uniqueKeysWithValues: accounts.map { account in
            let applicableTransactions = transactions.filter {
                $0.portfolioID == account.id && $0.id != transactionBeingEdited?.id
            }
            return (
                account.id,
                PortfolioHoldingSummary(transactions: applicableTransactions).holdings
            )
        })
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

    private var displayedPortfolioValueText: String {
        guard let selectedChartPoint else { return holdingValueText }
        return selectedChartPoint.valueUSD.formatted(.currency(code: "USD"))
    }

    private func chartYDomain(for points: [PortfolioChartPoint]) -> ClosedRange<Double> {
        let values = points.map(\.valueUSD)
        guard let minimum = values.min(), let maximum = values.max() else { return 0...1 }
        let spread = maximum - minimum
        let reference = max(abs(maximum), 1)
        let padding = max(spread * 0.12, reference * 0.04)
        let lower = max(0, minimum - padding)
        let upper = max(lower + 1, maximum + padding)
        return lower...upper
    }

    private var chartRequestID: String {
        let transactionState = visibleTransactions.map {
            "\($0.id.uuidString):\($0.timestamp.timeIntervalSince1970):\($0.type):\($0.kasAmount)"
        }.joined(separator: "|")
        return "\(selectedRange.rawValue):\(selectedPortfolioID):\(priceService.historyRevision):\(transactionState)"
    }

    private func loadChartHistory() async {
        isLoadingChart = true
        chartLoadFailed = false
        selectedChartPoint = nil

        do {
            let days = selectedRange.days ?? allHistoryDays
            let prices = try await priceService.historicalUSDPrices(days: days)
            guard !Task.isCancelled else { return }
            let applicableTransactions = visibleTransactions.sorted(
                by: PortfolioTransactionOrder.ascending
            )
            guard let firstTransactionDate = applicableTransactions.first?.timestamp else {
                chartPoints = []
                selectionChartPoints = []
                chartValueDomain = 0...1
                chartLoadFailed = false
                isLoadingChart = false
                return
            }

            let fullResolutionPoints = PortfolioChartBuilder.points(
                transactions: applicableTransactions,
                prices: prices
            )
            selectionChartPoints = fullResolutionPoints
            chartPoints = PortfolioChartBuilder.downsampled(
                fullResolutionPoints,
                maximumCount: 280
            )
            chartValueDomain = chartYDomain(for: fullResolutionPoints)
            chartLoadFailed = false
        } catch {
            guard !Task.isCancelled else { return }
            chartPoints = []
            selectionChartPoints = []
            chartValueDomain = 0...1
            chartLoadFailed = true
        }
        isLoadingChart = false
    }

    private var allHistoryDays: String {
        guard let earliest = visibleTransactions.map(\.timestamp).min() else { return "1" }
        let elapsedDays = Calendar.current.dateComponents([.day], from: earliest, to: Date()).day ?? 1
        return String(max(1, elapsedDays + 1))
    }

    private func nearestChartPoint(to date: Date) -> PortfolioChartPoint? {
        guard !selectionChartPoints.isEmpty else { return nil }

        var lowerBound = 0
        var upperBound = selectionChartPoints.count
        while lowerBound < upperBound {
            let middle = (lowerBound + upperBound) / 2
            if selectionChartPoints[middle].timestamp < date {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }

        if lowerBound == 0 { return selectionChartPoints[0] }
        if lowerBound == selectionChartPoints.count { return selectionChartPoints.last }

        let previous = selectionChartPoints[lowerBound - 1]
        let next = selectionChartPoints[lowerBound]
        if abs(previous.timestamp.timeIntervalSince(date)) <= abs(next.timestamp.timeIntervalSince(date)) {
            return previous
        }
        return next
    }

    private func chartSelectionTime(_ date: Date) -> String {
        switch selectedRange {
        case .day:
            date.formatted(date: .omitted, time: .shortened)
        default:
            date.formatted(date: .abbreviated, time: .shortened)
        }
    }

    private func chartAxisDate(_ date: Date) -> String {
        switch selectedRange {
        case .day:
            date.formatted(.dateTime.hour().minute())
        case .week, .month:
            date.formatted(.dateTime.month(.abbreviated).day())
        case .quarter, .all:
            date.formatted(.dateTime.month(.abbreviated).year(.twoDigits))
        }
    }

    private func compactCurrency(_ value: Double) -> String {
        let magnitude = abs(value)
        if magnitude >= 1_000_000_000 {
            return "$" + (value / 1_000_000_000).formatted(.number.precision(.fractionLength(0...1))) + "B"
        }
        if magnitude >= 1_000_000 {
            return "$" + (value / 1_000_000).formatted(.number.precision(.fractionLength(0...1))) + "M"
        }
        if magnitude >= 1_000 {
            return "$" + (value / 1_000).formatted(.number.precision(.fractionLength(0...1))) + "K"
        }
        return value.formatted(.currency(code: "USD").precision(.fractionLength(0...2)))
    }

    private var activePortfolioColor: Color {
        selectedAccount.map(accountColor) ?? teal
    }

    private func beginAddingAccount() {
        accountEditorPresentation = .create
    }

    private func beginEditing(_ account: PortfolioAccount) {
        accountEditorPresentation = .edit(account)
    }

    private func saveAccount(_ draft: PortfolioAccountDraft, editing account: PortfolioAccount?) {
        if let account {
            account.name = draft.name
            account.accentName = draft.accentName
        } else {
            let account = PortfolioAccount(
                name: draft.name,
                accentName: draft.accentName
            )
            modelContext.insert(account)
            selectedPortfolioID = account.id.uuidString
        }

        try? modelContext.save()
    }

    private func saveTransaction(_ draft: PortfolioTransactionDraft) {
        if let transactionBeingEdited {
            transactionBeingEdited.portfolioID = draft.portfolioID
            transactionBeingEdited.type = draft.type.rawValue
            transactionBeingEdited.kasAmount = draft.kasAmount
            transactionBeingEdited.kasPriceUSD = draft.kasPriceUSD
            transactionBeingEdited.feeUSD = draft.feeUSD
            transactionBeingEdited.timestamp = draft.timestamp
            transactionBeingEdited.notes = draft.notes
        } else {
            modelContext.insert(PortfolioTransaction(
                portfolioID: draft.portfolioID,
                type: draft.type.rawValue,
                kasAmount: draft.kasAmount,
                kasPriceUSD: draft.kasPriceUSD,
                timestamp: draft.timestamp,
                notes: draft.notes,
                feeUSD: draft.feeUSD
            ))
        }
        try? modelContext.save()
        transactionBeingEdited = nil
    }

    private func handleCSVSelection(_ result: Result<URL, Error>) {
        guard let account = selectedAccount else {
            csvImportAlert = CSVImportAlert(
                title: "Select a Portfolio",
                message: "Choose one portfolio before importing transactions."
            )
            return
        }

        switch result {
        case .success(let url):
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer {
                if hasAccess { url.stopAccessingSecurityScopedResource() }
            }

            do {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                csvImportPreview = try PortfolioCSVImporter.preview(
                    data: data,
                    fileName: url.lastPathComponent,
                    portfolioID: account.id,
                    existingTransactions: transactions
                )
            } catch {
                csvImportAlert = CSVImportAlert(
                    title: "Unable to Import CSV",
                    message: error.localizedDescription
                )
            }
        case .failure(let error):
            if (error as NSError).code != NSUserCancelledError {
                csvImportAlert = CSVImportAlert(
                    title: "Unable to Open CSV",
                    message: error.localizedDescription
                )
            }
        }
    }

    private var transactionsForSelectedAccount: [PortfolioTransaction] {
        guard let selectedPortfolioUUID else { return [] }
        return transactions.filter { $0.portfolioID == selectedPortfolioUUID }
    }

    private func beginCSVExport(for account: PortfolioAccount) {
        let portfolioTransactions = transactions.filter { $0.portfolioID == account.id }
        guard !portfolioTransactions.isEmpty else {
            csvImportAlert = CSVImportAlert(
                title: "Nothing to Export",
                message: "Add a transaction to this portfolio before exporting a CSV."
            )
            return
        }

        csvExportDocument = PortfolioCSVExporter.document(transactions: portfolioTransactions)
        csvExportFileName = PortfolioCSVExporter.suggestedFileName(portfolioName: account.name)
        showingCSVFileExporter = true
    }

    private func handleCSVExport(_ result: Result<URL, Error>) {
        defer { csvExportDocument = nil }
        switch result {
        case .success(let url):
            csvImportAlert = CSVImportAlert(
                title: "Export Complete",
                message: "Saved \(url.lastPathComponent) to Files."
            )
        case .failure(let error):
            if (error as NSError).code != NSUserCancelledError {
                csvImportAlert = CSVImportAlert(
                    title: "Unable to Export CSV",
                    message: error.localizedDescription
                )
            }
        }
    }

    private func importCSVTransactions(_ preview: PortfolioCSVImportPreview) {
        guard accounts.contains(where: { $0.id == preview.portfolioID }) else {
            csvImportPreview = nil
            csvImportAlert = CSVImportAlert(
                title: "Portfolio Unavailable",
                message: "The selected portfolio no longer exists."
            )
            return
        }

        let createdAt = Date()
        for (index, transaction) in preview.transactions.enumerated() {
            modelContext.insert(PortfolioTransaction(
                portfolioID: preview.portfolioID,
                type: transaction.type.rawValue,
                kasAmount: transaction.kasAmount,
                kasPriceUSD: transaction.kasPriceUSD,
                timestamp: transaction.timestamp,
                notes: transaction.notes,
                createdAt: createdAt.addingTimeInterval(Double(index) / 1_000),
                feeUSD: transaction.feeUSD
            ))
        }

        do {
            try modelContext.save()
            csvImportPreview = nil
            csvImportAlert = CSVImportAlert(
                title: "Import Complete",
                message: "Imported \(preview.transactions.count) transactions."
            )
        } catch {
            modelContext.rollback()
            csvImportPreview = nil
            csvImportAlert = CSVImportAlert(
                title: "Import Failed",
                message: "No transactions were imported."
            )
        }
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
                    LabeledContent("Average Buy Price", value: averageCostText)
                    LabeledContent("Cost Basis", value: currency(summary.costBasis))
                }

                Section("Activity") {
                    LabeledContent("Bought", value: kasAmount(summary.totalBought))
                    LabeledContent("Sold", value: kasAmount(summary.totalSold))
                    LabeledContent("Transferred In", value: kasAmount(summary.totalTransferredIn))
                    LabeledContent("Transferred Out", value: kasAmount(summary.totalTransferredOut))
                }
            }
            .navigationTitle("Summary")
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
            .currency(code: "USD").precision(.fractionLength(4))
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
        return (summary.holdings * kasPriceUSD) - summary.remainingCostBasis
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

private struct PortfolioTransactionDraft {
    let portfolioID: UUID
    let type: PortfolioTransactionType
    let kasAmount: Double
    let kasPriceUSD: Double
    let feeUSD: Double
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
                Section("Transaction") {
                    LabeledContent("Portfolio", value: portfolioName)
                    LabeledContent("Type", value: transaction.type)
                    LabeledContent("Amount", value: kasAmountText)
                    if transactionType == .buy || transactionType == .sell {
                        LabeledContent("Price", value: kasPriceText)
                    }
                    LabeledContent("Fee", value: feeText)
                    LabeledContent("Total Value", value: totalValueText)
                }

                Section("Date & Time") {
                    LabeledContent(
                        "Date",
                        value: transaction.timestamp.formatted(date: .abbreviated, time: .omitted)
                    )
                    LabeledContent(
                        "Time",
                        value: transaction.timestamp.formatted(date: .omitted, time: .shortened)
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
            .currency(code: "USD").precision(.fractionLength(4))
        )
    }

    private var totalValueText: String {
        (transaction.kasAmount * transaction.kasPriceUSD).formatted(.currency(code: "USD"))
    }

    private var transactionType: PortfolioTransactionType? {
        PortfolioTransactionType(rawValue: transaction.type)
    }

    private var feeText: String {
        transaction.feeUSD.formatted(.currency(code: "USD"))
    }
}

private struct PortfolioCSVImportPreviewView: View {
    let preview: PortfolioCSVImportPreview
    let portfolioName: String
    let accentColor: Color
    let onCancel: () -> Void
    let onImport: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Portfolio", value: portfolioName)
                    LabeledContent("File", value: preview.fileName)
                }

                Section("Import Summary") {
                    LabeledContent("Ready", value: preview.transactions.count.formatted())
                    LabeledContent("Duplicates", value: preview.duplicateCount.formatted())
                    LabeledContent("Rejected", value: preview.issues.count.formatted())
                }

                if !preview.issues.isEmpty {
                    Section("Rejected Rows") {
                        ForEach(preview.issues) { issue in
                            LabeledContent("Row \(issue.lineNumber)") {
                                Text(issue.message)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Import Transactions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Import", action: onImport)
                        .disabled(preview.transactions.isEmpty)
                }
            }
            .tint(accentColor)
        }
    }
}

private struct PortfolioTransactionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var priceService: PriceService

    let accounts: [PortfolioAccount]
    let initialPortfolioID: UUID?
    let transaction: PortfolioTransaction?
    let availableHoldingsByPortfolio: [UUID: Double]
    let accentColor: Color
    let onSave: (PortfolioTransactionDraft) -> Void

    @State private var portfolioID: UUID?
    @State private var transactionType: PortfolioTransactionType = .buy
    @State private var kasAmount: Double?
    @State private var kasPriceUSD: Double?
    @State private var feeUSD: Double
    @State private var timestamp = Date()
    @State private var notes = ""
    @State private var hasEditedPrice = false

    init(
        accounts: [PortfolioAccount],
        initialPortfolioID: UUID?,
        transaction: PortfolioTransaction? = nil,
        availableHoldingsByPortfolio: [UUID: Double],
        accentColor: Color,
        onSave: @escaping (PortfolioTransactionDraft) -> Void
    ) {
        self.accounts = accounts
        self.initialPortfolioID = initialPortfolioID
        self.transaction = transaction
        self.availableHoldingsByPortfolio = availableHoldingsByPortfolio
        self.accentColor = accentColor
        self.onSave = onSave
        _portfolioID = State(initialValue: transaction?.portfolioID ?? initialPortfolioID ?? accounts.first?.id)
        _transactionType = State(
            initialValue: transaction.flatMap { PortfolioTransactionType(rawValue: $0.type) } ?? .buy
        )
        _kasAmount = State(initialValue: transaction?.kasAmount)
        _kasPriceUSD = State(initialValue: transaction?.kasPriceUSD)
        _feeUSD = State(initialValue: transaction?.feeUSD ?? 0)
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

                    LabeledContent("Amount") {
                        TextField(
                            "0",
                            value: $kasAmount,
                            format: .number
                                .grouping(.automatic)
                                .precision(.fractionLength(0...8))
                        )
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.decimalPad)
                    }

                    if transactionType == .buy || transactionType == .sell {
                        LabeledContent("Price") {
                            TextField(
                                "$0.0000",
                                value: editablePrice,
                                format: .currency(code: "USD")
                                    .precision(.fractionLength(4))
                            )
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.decimalPad)
                        }
                    }

                    LabeledContent("Fee") {
                        TextField(
                            "$0.00",
                            value: $feeUSD,
                            format: .currency(code: "USD")
                                .precision(.fractionLength(2))
                        )
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.decimalPad)
                    }

                    LabeledContent("Total Value", value: totalValueText)

                    if exceedsAvailableHoldings {
                        Text("Amount exceeds available holdings.")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section("Date & Time") {
                    DatePicker(
                        "Date",
                        selection: $timestamp,
                        in: transactionDateRange,
                        displayedComponents: .date
                    )
                    DatePicker(
                        "Time",
                        selection: $timestamp,
                        in: transactionDateRange,
                        displayedComponents: .hourAndMinute
                    )
                }

                Section("Notes") {
                    TextField("Optional notes", text: $notes, axis: .vertical)
                        .lineLimit(1...6)
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
                        guard let portfolioID, let kasAmount else { return }
                        let savedPrice = kasPriceUSD ?? 0
                        onSave(
                            PortfolioTransactionDraft(
                                portfolioID: portfolioID,
                                type: transactionType,
                                kasAmount: kasAmount,
                                kasPriceUSD: savedPrice,
                                feeUSD: max(0, feeUSD),
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
            }
            .onChange(of: priceService.prices) { _, _ in
                populateCurrentPriceIfNeeded()
            }
            .onChange(of: timestamp) { oldValue, newValue in
                if oldValue != newValue {
                    hasEditedPrice = false
                }
            }
            .onChange(of: transactionType) { oldValue, newValue in
                if oldValue != newValue {
                    hasEditedPrice = false
                }
            }
            .task(id: automaticPriceRequestID) {
                await populateAutomaticPriceIfNeeded()
            }
        }
    }

    private var canSave: Bool {
        guard portfolioID != nil, let kasAmount else { return false }
        let hasValidPrice = transactionType == .transferIn || transactionType == .transferOut ||
            (kasPriceUSD ?? 0) > 0
        return kasAmount > 0 && hasValidPrice && !exceedsAvailableHoldings
    }

    private var transactionDateRange: ClosedRange<Date> {
        let calendar = Calendar.current
        let earliestDate = calendar.date(
            from: DateComponents(year: 2022, month: 6, day: 1)
        ) ?? .distantPast
        return earliestDate...Date()
    }

    private var exceedsAvailableHoldings: Bool {
        guard transactionType == .sell || transactionType == .transferOut,
              let portfolioID,
              let kasAmount else { return false }
        return kasAmount > (availableHoldingsByPortfolio[portfolioID] ?? 0)
    }

    private var totalValueText: String {
        guard let kasAmount, let kasPriceUSD else { return "$0.00" }
        return (kasAmount * kasPriceUSD).formatted(.currency(code: "USD"))
    }

    private var editablePrice: Binding<Double?> {
        Binding(
            get: { kasPriceUSD },
            set: { newValue in
                kasPriceUSD = newValue
                hasEditedPrice = true
            }
        )
    }

    private func populateCurrentPriceIfNeeded() {
        guard !hasEditedPrice,
              Calendar.current.isDate(timestamp, inSameDayAs: Date()),
              let livePrice = priceService.price(for: .usd) else { return }
        kasPriceUSD = livePrice
    }

    private var automaticPriceRequestID: String {
        return "\(transactionType.rawValue):\(timestamp.timeIntervalSince1970)"
    }

    private func populateAutomaticPriceIfNeeded() async {
        guard !hasEditedPrice else { return }

        let requestedTimestamp = timestamp
        let now = Date()
        if Calendar.current.isDate(requestedTimestamp, inSameDayAs: now) {
            populateCurrentPriceIfNeeded()
            return
        }

        let elapsedDays = Calendar.current.dateComponents(
            [.day],
            from: requestedTimestamp,
            to: now
        ).day ?? 1
        let prices = try? await priceService.historicalUSDPrices(
            days: String(max(1, elapsedDays + 1))
        )

        guard !Task.isCancelled,
              !hasEditedPrice,
              timestamp == requestedTimestamp else { return }

        let historicalPrice = PortfolioTransactionPriceResolver.automaticPrice(
            at: requestedTimestamp,
            now: now,
            livePrice: priceService.price(for: .usd),
            historicalPrices: prices ?? []
        )
        if let historicalPrice {
            kasPriceUSD = historicalPrice
        } else {
            kasPriceUSD = transactionType == .buy || transactionType == .sell ? nil : 0
        }
    }
}

private struct PortfolioAccountDraft {
    let name: String
    let accentName: String
}

private struct PortfolioAccountEditor: View {
    private static let colors = ["teal", "blue", "indigo", "orange", "red"]

    @Environment(\.dismiss) private var dismiss

    let account: PortfolioAccount?
    let onSave: (PortfolioAccountDraft) -> Void

    @State private var name: String
    @State private var accentName: String

    init(account: PortfolioAccount?, onSave: @escaping (PortfolioAccountDraft) -> Void) {
        self.account = account
        self.onSave = onSave
        _name = State(initialValue: account?.name ?? "")
        _accentName = State(initialValue: account?.accentName == "purple" ? "red" : account?.accentName ?? "teal")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
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
