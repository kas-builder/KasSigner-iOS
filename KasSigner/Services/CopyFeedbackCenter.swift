import SwiftUI

@MainActor
final class CopyFeedbackCenter: ObservableObject {
    @Published private(set) var message: String?

    private var dismissalTask: Task<Void, Never>?

    func show(_ message: String) {
        dismissalTask?.cancel()

        withAnimation(.snappy) {
            self.message = message
        }

        dismissalTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) {
                self.message = nil
            }
        }
    }

    func showCopied(_ value: String, label: String = "Address") {
        let previewValue = value.hasPrefix("kaspa:")
            ? String(value.dropFirst("kaspa:".count))
            : value
        let prefix = String(previewValue.prefix(6))
        let suffix = String(previewValue.suffix(6))
        show("\(label) \(prefix)...\(suffix) copied")
    }
}
