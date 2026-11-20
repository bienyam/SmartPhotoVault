import SwiftUI

/// A plain history of what the user approved and what happened, plus the storage and cost analysis.
struct LedgerView: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        List {
            Section {
                Text("Everything you approved and what happened, newest first. This history stays on your iPhone.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Activity") {
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
            Section("Storage and cost") {
                NavigationLink("Storage and cost analysis") {
                    StorageGuideView(snapshot: model.isDemo ? nil : model.snapshot)
                }
            }
            Section("About") {
                NavigationLink("Help and privacy") {
                    PhotoDetailsView(model: model, destination: .help)
                }
            }
        }
        .navigationTitle("Ledger")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.reloadActivity() }
    }
}
