import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

struct ReceiveView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var syncService: WalletSyncService
    @EnvironmentObject private var walletStore: WalletStore
    @EnvironmentObject private var engine: KasSignerEngine
    @EnvironmentObject private var copyFeedbackCenter: CopyFeedbackCenter

    let profile: WalletProfile

    @State private var isGeneratingAddress = false
    @State private var generationError: String?
    @State private var selectedAddressIndex = 0

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
                    Text("Address #\(selectedAddressIndex + 1)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
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
                                .frame(width: 30, height: 44)
                        }
                        .buttonStyle(.plain)
                        .disabled(selectedAddressIndex == 0)
                        .opacity(selectedAddressIndex == 0 ? 0.25 : 1)

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
                            .buttonStyle(.plain)
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
                                .frame(width: 30, height: 44)
                        }
                        .buttonStyle(.plain)
                        .disabled(selectedAddressIndex >= activeProfile.receiveAddresses.count - 1)
                        .opacity(
                            selectedAddressIndex >= activeProfile.receiveAddresses.count - 1
                                ? 0.25
                                : 1
                        )
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
                .buttonStyle(.plain)
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
                .buttonStyle(.plain)
                .disabled(isGeneratingAddress)

                VStack(spacing: 10) {
                    LabeledContent("UTXOs", value: "\(syncService.snapshot?.balance.utxoCount ?? 0)")
                    TimelineView(.periodic(from: .now, by: 9)) { context in
                        LabeledContent("Last refreshed", value: refreshAge(now: context.date))
                    }
                }
                .padding()
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .padding()
        }
        .navigationTitle("Receive")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            engine.startIfNeeded()
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

    private func persistSelectedAddressIndex(addressCount: Int? = nil) {
        walletStore.setLastViewedReceiveIndex(
            selectedAddressIndex,
            for: profile.id,
            addressCount: addressCount ?? activeProfile.receiveAddresses.count
        )
    }

    private var balanceText: String {
        guard let balance = syncService.snapshot?.balance.totalKas else { return "— KAS" }
        return balance.formatted(.number.precision(.fractionLength(0...8))) + " KAS"
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

    private func refreshAge(now: Date) -> String {
        guard let timestamp = syncService.snapshot?.syncedAt else { return "Not yet" }
        let elapsed = max(0, Int(now.timeIntervalSince1970 - timestamp))
        if elapsed < 60 { return "\(elapsed) sec ago" }
        let minutes = elapsed / 60
        if minutes < 60 { return "\(minutes) min ago" }
        return "\(minutes / 60) hr ago"
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
