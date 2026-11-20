import SwiftUI

/// Clean tab section listing each category with its count and measured size.
struct CleanCategoriesSection: View {
    /// Nil for scans saved before categories were recorded.
    let summaries: [CleanCategorySummary]?

    var body: some View {
        Section {
            if let summaries {
                ForEach(summaries, id: \.category) { summary in
                    if summary.items.isEmpty {
                        row(summary)
                    } else {
                        NavigationLink { CleanCategoryReviewView(summary: summary) } label: { row(summary) }
                            .accessibilityIdentifier("category-\(summary.category.rawValue)")
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
        if summary.category == .bursts {
            return "\(summary.items.count.formatted()) · \(summary.burstFrames.formatted()) frames"
        }
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
                if summary.category == .bursts {
                    LabeledContent("Frames kept", value: summary.burstFrames.formatted())
                    Text("Sizes below are for the one photo Photos shows from each burst. The hidden frames take space too.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    LabeledContent("Measured size (estimate)", value: ByteCountFormatter.string(fromByteCount: summary.knownBytes, countStyle: .file))
                }
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
