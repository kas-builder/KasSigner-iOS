import SwiftUI

struct ActivityView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView("No Activity", systemImage: "clock.arrow.circlepath", description: Text("Transactions will appear here after wallet synchronization is added."))
                .navigationTitle("Activity")
        }
    }
}
