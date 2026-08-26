import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

enum AddressUsageStatus: Equatable {
    case checking
    case fresh
    case used
    case unavailable
}

private struct AddressTransactionCountResponse: Decodable {
    let total: Int
}

private enum AddressUsageError: Error {
    case invalidAddress
    case invalidResponse
    case invalidTransactionCount
}

actor AddressUsageChecker {
    static let shared = AddressUsageChecker()

    private struct CacheEntry {
        let status: AddressUsageStatus
        let checkedAt: Date
    }

    private let freshCacheLifetime: TimeInterval = 30
    private var cachedStatuses: [String: CacheEntry] = [:]

    func status(
        for address: String,
        forceRefresh: Bool = false
    ) async throws -> AddressUsageStatus {
        if !forceRefresh, let cachedEntry = cachedStatuses[address] {
            if cachedEntry.status == .used
                || Date().timeIntervalSince(cachedEntry.checkedAt) < freshCacheLifetime {
                return cachedEntry.status
            }
        }

        guard address.hasPrefix("kaspa:") else {
            throw AddressUsageError.invalidAddress
        }

        let url = URL(string: "https://api.kaspa.org")!
            .appending(path: "addresses")
            .appending(path: address)
            .appending(path: "transactions-count")

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw AddressUsageError.invalidResponse
        }

        let result = try JSONDecoder().decode(AddressTransactionCountResponse.self, from: data)
        guard result.total >= 0 else {
            throw AddressUsageError.invalidTransactionCount
        }

        let status: AddressUsageStatus = result.total == 0 ? .fresh : .used
        cachedStatuses[address] = CacheEntry(status: status, checkedAt: Date())
        return status
    }
}

private enum AddressChain: String, CaseIterable, Identifiable {
    case receive = "Receive"
    case change = "Change"

    var id: String { rawValue }
}

struct ReceiveView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var syncService: WalletSyncService
    @EnvironmentObject private var walletStore: WalletStore
    @EnvironmentObject private var engine: KasSignerEngine
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var copyFeedbackCenter: CopyFeedbackCenter

    let profile: WalletProfile

    @State private var isGeneratingAddress = false
    @State private var generationError: String?
    @State private var selectedAddressIndex = 0
    @State private var addressUsageStatus: AddressUsageStatus = .checking
    @State private var addressWasManuallySelected = false
    @State private var addressChain: AddressChain = .receive
    @State private var showingChangeAddressWarning = false

    private let context = CIContext()
    private let filter = CIFilter.qrCodeGenerator()

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 6) {
                    Text(balanceText)
                        .font(.system(size: 36, weight: .regular, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .allowsTightening(true)
                    Text("Available balance")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Text("\(addressChain.rawValue) Address #\(selectedAddressIndex + 1)")
                            .foregroundStyle(.secondary)

                        if preferences.addressStatusDisplayMode.isEnabled {
                            addressUsageLabel(
                                showsText: preferences.addressStatusDisplayMode == .iconAndText
                            )
                        }
                    }
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .center)

                    HStack(spacing: 8) {
                        Button {
                            addressWasManuallySelected = true
                            withAnimation(.easeInOut(duration: 0.22)) {
                                selectedAddressIndex = max(0, selectedAddressIndex - 1)
                            }
                            persistSelectedAddressIndex()
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.title2.weight(.semibold))
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(SubtlePressButtonStyle())
                        .disabled(selectedAddressIndex == 0)
                        .opacity(selectedAddressIndex == 0 ? 0.25 : 1)
                        .accessibilityLabel("Previous address")

                        if let image = qrImage {
                            Button {
                                copyCurrentAddress()
                            } label: {
                                Image(uiImage: image)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .padding(0)
                                .background(Color.white)
                                .padding(10)
                                .background {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(
                                            colorScheme == .dark
                                                ? Color(red: 0.035, green: 0.05, blue: 0.055)
                                                : Color(red: 0.965, green: 0.97, blue: 0.975)
                                        )
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .stroke(
                                                    colorScheme == .dark
                                                        ? Color(red: 0.33, green: 0.93, blue: 0.86)
                                                        : Color(red: 0.18, green: 0.68, blue: 0.62),
                                                    lineWidth: 2.5
                                                )
                                        }
                                        .shadow(
                                            color: colorScheme == .dark
                                                ? .clear
                                                : .black.opacity(0.025),
                                            radius: 5,
                                            y: 2
                                        )
                                }
                                .frame(maxWidth: 304)
                                .id(currentAddress)
                                .transition(.opacity)
                                .accessibilityLabel("Receive address QR code")
                            }
                            .buttonStyle(SubtlePressButtonStyle())
                            .accessibilityHint("Copies the full receive address")
                        }

                        Button {
                            addressWasManuallySelected = true
                            withAnimation(.easeInOut(duration: 0.22)) {
                                selectedAddressIndex = min(
                                    currentAddresses.count - 1,
                                    selectedAddressIndex + 1
                                )
                            }
                            persistSelectedAddressIndex()
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.title2.weight(.semibold))
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(SubtlePressButtonStyle())
                        .disabled(selectedAddressIndex >= currentAddresses.count - 1)
                        .opacity(
                            selectedAddressIndex >= currentAddresses.count - 1
                                ? 0.25
                                : 1
                        )
                        .accessibilityLabel("Next address")
                    }
                }

                HStack(spacing: 12) {
                    Button {
                        copyCurrentAddress()
                    } label: {
                        Text(twoLineAddress)
                            .font(.system(size: 14, weight: .regular, design: .monospaced))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(SubtlePressButtonStyle())
                    .accessibilityHint("Copies the full receive address")

                    Button {
                        copyCurrentAddress()
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.title3.weight(.semibold))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(SubtlePressButtonStyle())
                    .accessibilityLabel("Copy receive address")
                }
                .padding(.leading, 16)
                .padding(.trailing, 8)
                .padding(.vertical, 10)
                .background(
                    .thinMaterial,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )

                Button {
                    addressWasManuallySelected = true
                    Task {
                        await generateNextAddress()
                    }
                } label: {
                    Label(
                        isGeneratingAddress ? "Generating Address…" : "Generate New Address",
                        systemImage: isGeneratingAddress
                            ? "arrow.triangle.2.circlepath"
                            : "plus.circle"
                    )
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .foregroundStyle(.tint)
                        .frame(minHeight: 44)
                        .padding(.horizontal, 16)
                }
                .buttonStyle(SubtlePressButtonStyle())
                .disabled(isGeneratingAddress)

            }
            .padding()
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Menu {
                    Picker("Address Type", selection: $addressChain) {
                        ForEach(AddressChain.allCases) { chain in
                            Text(chain.rawValue).tag(chain)
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(addressChain.rawValue)
                            .font(.headline)
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                    }
                }
            }
        }
        .task {
            engine.startIfNeeded()
        }
        .task(id: addressUsageTaskID) {
            guard preferences.addressStatusDisplayMode.isEnabled else { return }
            await checkAddressUsage(currentAddress)
        }
        .task(id: oldestFreshAddressTaskID) {
            guard addressChain == .receive else { return }
            await selectOldestFreshAddress()
        }
        .onAppear {
            addressWasManuallySelected = false
            selectInitialAddress()
        }
        .onChange(of: addressChain) { _, _ in
            addressWasManuallySelected = false
            selectInitialAddress()
        }
        .onDisappear {
            persistSelectedAddressIndex()
        }
        .alert(
            "Unable to Generate Address",
            isPresented: Binding(
                get: { generationError != nil },
                set: { if !$0 { generationError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                generationError = nil
            }
        } message: {
            Text(generationError ?? "")
        }
        .alert("Change Address Copied", isPresented: $showingChangeAddressWarning) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Do not use change addresses as receive addresses. Use an address from the Receive view when requesting funds.")
        }
    }

    private var activeProfile: WalletProfile {
        walletStore.profiles.first(where: { $0.id == profile.id }) ?? profile
    }

    private var currentAddresses: [String] {
        addressChain == .receive
            ? activeProfile.receiveAddresses
            : activeProfile.changeAddresses
    }

    private var currentAddress: String {
        guard !currentAddresses.isEmpty else { return "" }

        let safeIndex = min(
            max(0, selectedAddressIndex),
            currentAddresses.count - 1
        )

        return currentAddresses[safeIndex]
    }

    private var twoLineAddress: String {
        guard !currentAddress.isEmpty else { return "" }
        let midpoint = currentAddress.index(
            currentAddress.startIndex,
            offsetBy: currentAddress.count / 2
        )
        return String(currentAddress[..<midpoint]) + "\n" + String(currentAddress[midpoint...])
    }

    private var addressUsageTaskID: String {
        "\(preferences.addressStatusDisplayMode.rawValue):\(currentAddress)"
    }

    private var oldestFreshAddressTaskID: String {
        "\(profile.id.uuidString):\(addressChain.rawValue):\(currentAddresses.count)"
    }

    @ViewBuilder
    private func addressUsageLabel(showsText: Bool) -> some View {
        switch addressUsageStatus {
        case .checking:
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.mini)
                if showsText {
                    Text("Checking…")
                }
            }
            .foregroundStyle(.secondary)
            .accessibilityLabel("Checking address usage")
        case .fresh:
            Button {
                Task {
                    await checkAddressUsage(currentAddress, forceRefresh: true)
                }
            } label: {
                if showsText {
                    Label("Fresh Address", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Fresh address")
            .accessibilityHint("Checks this address again")
        case .used:
            Button {
                Task {
                    await checkAddressUsage(currentAddress, forceRefresh: true)
                }
            } label: {
                if showsText {
                    Label("Used Address", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Used address")
            .accessibilityHint("Checks this address again")
        case .unavailable:
            Group {
                if showsText {
                    Label("Status Unavailable", systemImage: "questionmark.circle.fill")
                } else {
                    Image(systemName: "questionmark.circle.fill")
                }
            }
            .foregroundStyle(.secondary)
            .accessibilityLabel("Address usage status unavailable")
        }
    }

    private func persistSelectedAddressIndex(addressCount: Int? = nil) {
        if addressChain == .receive {
            walletStore.setLastViewedReceiveIndex(
                selectedAddressIndex,
                for: profile.id,
                addressCount: addressCount ?? currentAddresses.count
            )
        } else {
            walletStore.setLastViewedChangeIndex(
                selectedAddressIndex,
                for: profile.id,
                addressCount: addressCount ?? currentAddresses.count
            )
        }
    }

    private var balanceText: String {
        guard let balance = syncService.snapshot?.balance.totalKas else { return "— KAS" }
        return KasBalanceFormatter.string(
            from: balance,
            decimalPlaces: preferences.kasBalanceDecimalPlaces
        ) + " KAS"
    }

    private var qrImage: UIImage? {
        guard !currentAddress.isEmpty else { return nil }
        filter.setValue(Data(currentAddress.utf8), forKey: "inputMessage")
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }
        let transformed = outputImage.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private func generateNextAddress() async {
        guard !isGeneratingAddress else { return }

        isGeneratingAddress = true
        generationError = nil
        defer { isGeneratingAddress = false }

        do {
            var updated = activeProfile
            let targetIndex: Int
            if addressChain == .receive {
                targetIndex = max(updated.nextReceiveIndex, selectedAddressIndex) + 1
            } else {
                targetIndex = max(selectedAddressIndex + 1, updated.changeAddresses.count)
            }

            if addressChain == .receive && targetIndex >= updated.receiveAddresses.count {
                let derived = try await engine.extendAddresses(
                    for: updated,
                    receiveCount: targetIndex - updated.receiveAddresses.count + 1,
                    changeCount: 0
                )
                updated.receiveAddresses = derived.receiveAddresses
                updated.changeAddresses = derived.changeAddresses
            } else if addressChain == .change && targetIndex >= updated.changeAddresses.count {
                let derived = try await engine.extendAddresses(
                    for: updated,
                    receiveCount: 0,
                    changeCount: targetIndex - updated.changeAddresses.count + 1
                )
                updated.receiveAddresses = derived.receiveAddresses
                updated.changeAddresses = derived.changeAddresses
            }

            if addressChain == .receive {
                updated.nextReceiveIndex = targetIndex
            }
            walletStore.update(updated)

            withAnimation(.easeInOut(duration: 0.22)) {
                selectedAddressIndex = targetIndex
            }
            persistSelectedAddressIndex(
                addressCount: addressChain == .receive
                    ? updated.receiveAddresses.count
                    : updated.changeAddresses.count
            )
        } catch {
            generationError = error.localizedDescription
        }
    }

    private func copyCurrentAddress() {
        guard !currentAddress.isEmpty else { return }
        UIPasteboard.general.string = currentAddress
        copyFeedbackCenter.showCopied(currentAddress)
        if addressChain == .change {
            showingChangeAddressWarning = true
        }
    }

    @MainActor
    private func selectOldestFreshAddress() async {
        let addresses = activeProfile.receiveAddresses
        guard !addresses.isEmpty else { return }

        for (index, address) in addresses.enumerated() {
            guard !addressWasManuallySelected else { return }
            guard !walletStore.isReceiveAddressLocallyUsed(
                address,
                profileID: profile.id
            ) else { continue }

            do {
                let status = try await AddressUsageChecker.shared.status(for: address)
                try Task.checkCancellation()

                guard !addressWasManuallySelected else { return }
                guard status == .fresh else { continue }

                withAnimation(.easeInOut(duration: 0.22)) {
                    selectedAddressIndex = index
                }
                addressUsageStatus = .fresh
                persistSelectedAddressIndex(addressCount: addresses.count)
                return
            } catch is CancellationError {
                return
            } catch {
                // Without a result for an earlier address, a later address
                // cannot be identified as the oldest fresh address safely.
                return
            }
        }
    }

    @MainActor
    private func checkAddressUsage(
        _ address: String,
        forceRefresh: Bool = false
    ) async {
        guard preferences.addressStatusDisplayMode.isEnabled, !address.isEmpty else {
            addressUsageStatus = .unavailable
            return
        }

        let isLocallyUsed = addressChain == .change
            ? walletStore.isChangeAddressLocallyUsed(address, profileID: profile.id)
            : walletStore.isReceiveAddressLocallyUsed(address, profileID: profile.id)
        if isLocallyUsed {
            addressUsageStatus = .used
            return
        }

        addressUsageStatus = .checking

        do {
            if !forceRefresh {
                try await Task.sleep(for: .milliseconds(200))
            }
            let status = try await AddressUsageChecker.shared.status(
                for: address,
                forceRefresh: forceRefresh
            )
            try Task.checkCancellation()
            guard address == currentAddress else { return }
            addressUsageStatus = status
        } catch is CancellationError {
            return
        } catch {
            guard address == currentAddress else { return }
            addressUsageStatus = .unavailable
        }
    }

    private func selectInitialAddress() {
        let addresses = currentAddresses
        guard !addresses.isEmpty else {
            selectedAddressIndex = 0
            return
        }

        let preferredIndex: Int
        if addressChain == .receive {
            preferredIndex = max(
                activeProfile.nextReceiveIndex,
                walletStore.lastViewedReceiveIndex(
                    for: profile.id,
                    addressCount: addresses.count
                )
            )
        } else {
            preferredIndex = max(
                activeProfile.nextChangeIndex,
                walletStore.lastViewedChangeIndex(
                    for: profile.id,
                    addressCount: addresses.count
                )
            )
        }
        selectedAddressIndex = min(max(0, preferredIndex), addresses.count - 1)
    }

}

struct SharedQRCodeView: View {
    let payload: String

    @Environment(\.colorScheme) private var colorScheme

    private let context = CIContext()
    private let filter = CIFilter.qrCodeGenerator()

    var body: some View {
        if let image = qrImage {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(0)
                .background(Color.white)
                .padding(10)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            colorScheme == .dark
                                ? Color(red: 0.035, green: 0.05, blue: 0.055)
                                : Color(red: 0.965, green: 0.97, blue: 0.975)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(
                                    colorScheme == .dark
                                        ? Color(red: 0.33, green: 0.93, blue: 0.86)
                                        : Color(red: 0.18, green: 0.68, blue: 0.62),
                                    lineWidth: 2.5
                                )
                        }
                }
                .frame(maxWidth: 304)
        }
    }

    private var qrImage: UIImage? {
        guard !payload.isEmpty else { return nil }
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }
        let transformed = outputImage.transformed(
            by: CGAffineTransform(scaleX: 12, y: 12)
        )
        guard let cgImage = context.createCGImage(
            transformed,
            from: transformed.extent
        ) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }
}
