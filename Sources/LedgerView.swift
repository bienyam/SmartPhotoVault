import SwiftUI

/// A plain history of what the user approved and what happened, newest first.
struct LedgerView: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        List {
            if model.activity.isEmpty {
                Text("No activity yet.")
            }
            ForEach(model.activity) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.message)
                    Text(entry.date.formatted()).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                InfoButton(title: "Activity",
                           text: "Everything you approved and what happened, newest first. This history stays on your iPhone and never includes file names.")
            }
        }
        .onAppear { model.reloadActivity() }
    }
}
