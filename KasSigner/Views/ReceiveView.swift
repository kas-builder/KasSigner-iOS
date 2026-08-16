import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

private enum AddressUsageStatus: Equatable {
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

private actor AddressUsageChecker {
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
                        Text("Address #\(selectedAddressIndex + 1)")
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
                                copyReceiveAddress()
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
                                .id(receiveAddress)
                                .transition(.opacity)
                                .accessibilityLabel("Receive address QR code")
                            }
                            .buttonStyle(SubtlePressButtonStyle())
                            .accessibilityHint("Copies the full receive address")
                        }

                        Button {
                            withAnimation(.easeInOut(duration: 0.22)) {
                                selectedAddressIndex = min(
                                    activeProfile.receiveAddresses.count - 1,
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
                        .disabled(selectedAddressIndex >= activeProfile.receiveAddresses.count - 1)
                        .opacity(
                            selectedAddressIndex >= activeProfile.receiveAddresses.count - 1
                                ? 0.25
                                : 1
                        )
                        .accessibilityLabel("Next address")
                    }
                }

                Button {
                    copyReceiveAddress()
                } label: {
                    Text(twoLineReceiveAddress)
                        .font(.system(size: 12.35, weight: .regular, design: .monospaced))
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
                    Task {
                        await generateNextReceiveAddress()
                    }
                } label: {
                    Text(isGeneratingAddress ? "Generating Address…" : "Generate New Address")
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 13)
                        .background(
                            .thinMaterial,
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                        )
                }
                .buttonStyle(SubtlePressButtonStyle())
                .disabled(isGeneratingAddress)

            }
            .padding()
        }
        .navigationTitle("Receive")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            engine.startIfNeeded()
        }
        .task(id: addressUsageTaskID) {
            guard preferences.addressStatusDisplayMode.isEnabled else { return }
            await checkAddressUsage(receiveAddress)
        }
        .onAppear {
            selectedAddressIndex = min(
                max(
                    activeProfile.nextReceiveIndex,
                    walletStore.lastViewedReceiveIndex(
                        for: profile.id,
                        addressCount: activeProfile.receiveAddresses.count
                    )
                ),
                max(0, activeProfile.receiveAddresses.count - 1)
            )
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
    }

    private var activeProfile: WalletProfile {
        walletStore.profiles.first(where: { $0.id == profile.id }) ?? profile
    }

    private var receiveAddress: String {
        guard !activeProfile.receiveAddresses.isEmpty else { return "" }

        let safeIndex = min(
            max(0, selectedAddressIndex),
            activeProfile.receiveAddresses.count - 1
        )

        return activeProfile.receiveAddresses[safeIndex]
    }

    private var twoLineReceiveAddress: String {
        guard !receiveAddress.isEmpty else { return "" }
        let midpoint = receiveAddress.index(
            receiveAddress.startIndex,
            offsetBy: receiveAddress.count / 2
        )
        return String(receiveAddress[..<midpoint]) + "\n" + String(receiveAddress[midpoint...])
    }

    private var addressUsageTaskID: String {
        "\(preferences.addressStatusDisplayMode.rawValue):\(receiveAddress)"
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
                    await checkAddressUsage(receiveAddress, forceRefresh: true)
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
                    await checkAddressUsage(receiveAddress, forceRefresh: true)
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
        walletStore.setLastViewedReceiveIndex(
            selectedAddressIndex,
            for: profile.id,
            addressCount: addressCount ?? activeProfile.receiveAddresses.count
        )
    }

    private var balanceText: String {
        guard let balance = syncService.snapshot?.balance.totalKas else { return "— KAS" }
        return KasBalanceFormatter.string(
            from: balance,
            decimalPlaces: preferences.kasBalanceDecimalPlaces
        ) + " KAS"
    }

    private var qrImage: UIImage? {
        guard !receiveAddress.isEmpty else { return nil }
        filter.setValue(Data(receiveAddress.utf8), forKey: "inputMessage")
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }
        let transformed = outputImage.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private func generateNextReceiveAddress() async {
        guard !isGeneratingAddress else { return }

        isGeneratingAddress = true
        generationError = nil
        defer { isGeneratingAddress = false }

        do {
            var updated = activeProfile
            // Advance from whichever cursor is furthest ahead. The persisted
            // receive cursor can lag behind the address currently displayed
            // (for example after browsing with the chevrons), so using it
            // alone can move the UI backward and reuse an exposed address.
            let targetIndex = max(
                updated.nextReceiveIndex,
                selectedAddressIndex
            ) + 1

            if targetIndex >= updated.receiveAddresses.count {
                let derived = try await engine.extendAddresses(
                    for: updated,
                    receiveCount: targetIndex - updated.receiveAddresses.count + 1,
                    changeCount: 0
                )
                updated.receiveAddresses = derived.receiveAddresses
                updated.changeAddresses = derived.changeAddresses
            }

            updated.nextReceiveIndex = targetIndex
            walletStore.update(updated)

            withAnimation(.easeInOut(duration: 0.22)) {
                selectedAddressIndex = targetIndex
            }
            persistSelectedAddressIndex(addressCount: updated.receiveAddresses.count)
        } catch {
            generationError = error.localizedDescription
        }
    }

    private func copyReceiveAddress() {
        guard !receiveAddress.isEmpty else { return }
        UIPasteboard.general.string = receiveAddress
        copyFeedbackCenter.show("Address copied")
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
            guard address == receiveAddress else { return }
            addressUsageStatus = status
        } catch is CancellationError {
            return
        } catch {
            guard address == receiveAddress else { return }
            addressUsageStatus = .unavailable
        }
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
