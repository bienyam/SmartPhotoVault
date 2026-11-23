import SwiftUI

/// The numbers behind the last check, and the items it couldn't read (restored from the original
/// Clean tab at the owner's request).
struct ScanDetailsView: View {
    let snapshot: ScanSnapshot
    let isDemo: Bool

    private var unreadable: [AssetRecord] { snapshot.assets.filter { $0.fingerprint == nil } }

    var body: some View {
        List {
            Section {
                if isDemo { Label("Sample data — not your photo library", systemImage: "testtube.2") }
                LabeledContent("Checked", value: snapshot.date.formatted())
                if snapshot.limitedAccess {
                    Text("Only the photos you selected for TidyAway are included.").foregroundStyle(Brand.caution)
                }
                LabeledContent("Items checked", value: snapshot.assets.count.formatted())
                LabeledContent("Read in full on this \(Device.name)", value: snapshot.verifiedCount.formatted())
                LabeledContent("Not read (in iCloud or unreadable)", value: unreadable.count.formatted())
                LabeledContent("Exact duplicate groups", value: snapshot.groups.count.formatted())
                LabeledContent("Extra copies (estimate)", value: snapshot.candidateBytes.fileSize)
            } footer: {
                Text("Duplicates can only be confirmed for items read in full. Sizes are estimates, not guaranteed space.")
            }
            Section {
                NavigationLink {
                    UnreadableItemsView(items: unreadable)
                } label: {
                    LabeledContent("Items TidyAway couldn't read", value: unreadable.count.formatted())
                }
                .disabled(unreadable.isEmpty)
                .accessibilityIdentifier("scan-unreadable")
            }
        }
        .navigationTitle("Scan details")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Items the check couldn't read, each with the reason.
struct UnreadableItemsView: View {
    let items: [AssetRecord]

    var body: some View {
        List(items) { asset in
            HStack(alignment: .top, spacing: 12) {
                AssetThumbnail(assetID: asset.id)
                VStack(alignment: .leading, spacing: 3) {
                    Text(asset.filename).lineLimit(1)
                    Text(asset.inICloud ? "Original is in iCloud (\(asset.displayBytes.fileSize))"
                                        : (asset.issue ?? "No complete file to read"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .overlay {
            if items.isEmpty { Text("Every item was read in full.").foregroundStyle(.secondary) }
        }
        .navigationTitle("Couldn't read")
        .navigationBarTitleDisplayMode(.inline)
    }
}
