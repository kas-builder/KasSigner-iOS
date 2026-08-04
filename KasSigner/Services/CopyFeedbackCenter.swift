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
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) {
                self.message = nil
            }
        }
    }
}
