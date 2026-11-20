import SwiftUI

/// Clean tab section listing each category with its count and measured size.
struct CleanCategoriesSection: View {
    let snapshot: ScanSnapshot

    var body: some View {
        Section {
            if snapshot.recordsCategories {
                ForEach(CleanCategory.allCases) { category in
                    let summary = snapshot.summary(for: category)
                    if summary.items.isEmpty {
                        row(summary)
                    } else {
                        NavigationLink { CleanCategoryReviewView(summary: summary) } label: { row(summary) }
                            .accessibilityIdentifier("category-\(category.rawValue)")
                    }
                }
            } else {
                Text("Scan again to sort your library into screenshots, bursts, Live Photos and more.")
            }
        } header: {
            Text("Look through by type")
        } footer: {
            Text("For review only. TidyAway doesn't remove anything from these lists. Sizes count items read on this iPhone during the scan.")
        }
    }

    private func row(_ summary: CleanCategorySummary) -> some View {
        HStack {
            Label(summary.category.title, systemImage: summary.category.systemImage)
            Spacer()
            Text(detail(summary)).foregroundStyle(.secondary)
        }
    }

    private func detail(_ summary: CleanCategorySummary) -> String {
        guard !summary.items.isEmpty else { return "None found" }
        let size = ByteCountFormatter.string(fromByteCount: summary.knownBytes, countStyle: .file)
        return "\(summary.items.count.formatted()) · \(size)"
    }
}

struct CleanCategoryReviewView: View {
    let summary: CleanCategorySummary

    var body: some View {
        List {
            Section {
                Text(summary.category.guidance).font(.footnote)
                LabeledContent("Items", value: summary.items.count.formatted())
                LabeledContent("Measured size (estimate)", value: ByteCountFormatter.string(fromByteCount: summary.knownBytes, countStyle: .file))
                if summary.unreadCount > 0 {
                    Text("\(summary.unreadCount.formatted()) not on this iPhone, so their size isn't counted.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                ForEach(summary.items) { asset in
                    HStack(alignment: .top, spacing: 12) {
                        AssetThumbnail(assetID: asset.id)
                        VStack(alignment: .leading, spacing: 4) {
                            Label(asset.filename, systemImage: asset.favorite ? "heart.fill" : summary.category.systemImage)
                            Text(sizeText(asset)).font(.caption).foregroundStyle(.secondary)
                            if summary.category == .bursts, let frames = asset.burstFrames, frames > 1 {
                                Text("\(frames.formatted()) frames in this burst").font(.caption)
                            }
                            if asset.favorite { Text("Favorite").font(.caption).foregroundStyle(.secondary) }
                            if let date = asset.createdAt { Text(date.formatted()).font(.caption) }
                        }
                    }
                }
            } footer: {
                Text("For review only. To remove something, delete it in Photos, which normally keeps it in Recently Deleted for up to 30 days.")
            }
        }
        .navigationTitle(summary.category.title)
    }

    private func sizeText(_ asset: AssetRecord) -> String {
        asset.fingerprint == nil
            ? "Size unknown, not on this iPhone"
            : ByteCountFormatter.string(fromByteCount: asset.bytes, countStyle: .file)
    }
}
