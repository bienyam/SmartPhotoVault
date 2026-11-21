import SwiftUI

extension CleanCategory {
    /// Bursts stay review-only: deleting a burst's visible photo may not remove its hidden frames,
    /// so people are pointed to Select in Photos instead.
    var allowsRemoval: Bool { self != .bursts }
}

/// Sign-off and removal for items picked one by one from a Clean category.
/// Wording comes from ACTION_AUTHORIZATION.md, "Delete reviewed items from Apple Photos".
struct CategoryRemovalControls: View {
    let category: CleanCategory
    let records: [AssetRecord]
    let model: DashboardModel
    @State private var agreed = false
    @State private var working = false
    @State private var outcome: DuplicateRemovalOutcome?
    @Environment(\.colorScheme) private var colorScheme

    private let slate = Color(red: 0.19, green: 0.32, blue: 0.44)
    private let done = Color(red: 0.08, green: 0.26, blue: 0.16)

    private var removable: [AssetRecord] { records.filter { !$0.favorite } }
    private var itemWord: String { removable.count == 1 ? "item" : "items" }
    private var bytes: Int64 { removable.filter { $0.fingerprint != nil }.reduce(0) { $0 + $1.bytes } }
    private var deleteLabel: String { "Delete \(removable.count) \(itemWord) from Apple Photos" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let outcome { result(outcome) }
            if !isFinished { controls }
        }
        .padding(.vertical, 4)
        .onChange(of: records.map(\.id)) { agreed = false }
    }

    private var isFinished: Bool {
        if case .removed = outcome { return true }
        return false
    }

    @ViewBuilder
    private var controls: some View {
            LabeledContent("Selected", value: "\(removable.count.formatted()) · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
            Text("I authorize TidyAway to delete \(removable.count) \(itemWord) I selected from \(category.title) in Apple Photos. These items are not duplicates: unless I archived them elsewhere, Apple Photos holds the only copy. If iCloud Photos is on, they will also be deleted from iCloud Photos and synced devices. Apple normally keeps deleted items in Recently Deleted for up to 30 days unless they're permanently deleted sooner; after that they can't be recovered.")
                .font(.footnote)
            Button {
                agreed.toggle()
            } label: {
                Label("I understand and authorize these changes", systemImage: agreed ? "checkmark.square.fill" : "square")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .accessibilityAddTraits(agreed ? .isSelected : [])
            .accessibilityIdentifier("category-signoff")
            Button(deleteLabel) {
                working = true
                Task {
                    let result = await model.removeItems(removable.map(\.id), bytes: bytes, from: category.title)
                    outcome = result
                    working = false
                    agreed = false
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(slate)
            .disabled(!agreed || working || removable.isEmpty)
            .accessibilityIdentifier("category-delete")
            if working { ProgressView("Checking the selected items…") }
    }

    @ViewBuilder
    private func result(_ outcome: DuplicateRemovalOutcome) -> some View {
        switch outcome {
        case .removed(let count, let bytes):
            Label("Removed \(count) \(count == 1 ? "item" : "items"), about \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)). Recoverable in Recently Deleted for up to 30 days.", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(colorScheme == .dark ? Color.green : done)
        case .cancelled:
            Text("Cancelled. Nothing was removed.").font(.subheadline)
        case .sample:
            Text("Sample data. Nothing was removed.").font(.subheadline)
        case .blocked(let reason):
            Text(reason).font(.subheadline).foregroundStyle(.orange)
        }
    }
}
