import SwiftUI

/// The one place that explains TidyAway Pro. It never interrupts: people open it from More,
/// or from a calm note where a Pro feature starts.
struct ProUpgradeView: View {
    @EnvironmentObject private var pro: ProStore

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("TidyAway Pro").font(.title2.bold())
                    Text("Monthly, or once for life. Your choice.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }
            Section("Always free") {
                feature("Find and clear large videos, duplicates, screenshots and more", icon: "sparkles")
                feature("Archive up to 5 GB, with every copy checked", icon: "archivebox")
                feature("Get archived items back, always", icon: "arrow.uturn.backward")
                feature("Activity record and storage analysis", icon: "checkmark.shield")
            }
            Section("Added with Pro") {
                feature("Archive without a limit", icon: "infinity")
                feature("Choose what to archive by album, place and size", icon: "line.3.horizontal.decrease.circle")
            }
            Section {
                ProPurchaseControls()
            } footer: {
                Text("Pro is optional. Cleaning up your \(Device.name) and getting your photos back stay free.")
            }
        }
        .navigationTitle("TidyAway Pro")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func feature(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
    }
}
