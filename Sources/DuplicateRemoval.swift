import Foundation
import SwiftUI

/// Which copies of one exact-duplicate group stay and which may be removed.
/// The first asset in a group is kept. Favorites are never removed.
struct DuplicateRemovalPlan: Equatable, Sendable {
    let keepID: String
    let keepFilename: String
    let removeIDs: [String]
    let removeBytes: Int64
    let fingerprint: String

    init?(group: DuplicateGroup) {
        guard let keep = group.assets.first, let fingerprint = keep.fingerprint else { return nil }
        let removable = group.assets.dropFirst().filter { !$0.favorite && $0.fingerprint == fingerprint }
        guard !removable.isEmpty else { return nil }
        keepID = keep.id
        keepFilename = keep.filename
        removeIDs = removable.map(\.id)
        removeBytes = removable.reduce(0) { $0 + $1.bytes }
        self.fingerprint = fingerprint
    }

    var itemWord: String { removeIDs.count == 1 ? "item" : "items" }
    var deleteLabel: String { "Delete \(removeIDs.count) \(itemWord) from Apple Photos" }
}

enum DuplicateRemovalOutcome: Equatable {
    case removed(count: Int, bytes: Int64)
    case cancelled
    case sample
    case blocked(String)

    /// Space only comes back once Recently Deleted is emptied, so never say "freed" here.
    static func removedMessage(count: Int, bytes: Int64) -> String {
        let items = count == 1 ? "1 item" : "\(count.formatted()) items"
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return "Moved \(items) to Recently Deleted. Empty it in Photos to free about \(size)."
    }
}

/// Sign-off and removal controls for one duplicate group.
struct DuplicateRemovalControls: View {
    let plan: DuplicateRemovalPlan
    let model: DashboardModel
    @State private var agreed = false
    @State private var working = false
    @State private var outcome: DuplicateRemovalOutcome?
    @Environment(\.colorScheme) private var colorScheme

    private let accent = Brand.primary
    private let done = Brand.safe

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let outcome {
                result(outcome)
            }
            if !isFinished {
                Text("I authorize TidyAway to delete \(plan.removeIDs.count) selected \(plan.itemWord) from Apple Photos. If iCloud Photos is on, these items will also be deleted from iCloud Photos and synced devices. Apple normally keeps deleted items in Recently Deleted for up to 30 days unless they’re permanently deleted sooner. An identical full-resolution copy, \(plan.keepFilename), stays in Apple Photos and is checked again just before removal.")
                    .font(.footnote)
                Button {
                    agreed.toggle()
                } label: {
                    Label("I understand and authorize these changes", systemImage: agreed ? "checkmark.square.fill" : "square")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .accessibilityAddTraits(agreed ? .isSelected : [])
                Button(plan.deleteLabel) {
                    working = true
                    Task {
                        outcome = await model.removeDuplicates(plan)
                        working = false
                        agreed = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .disabled(!agreed || working)
                if working { ProgressView("Checking the copy to keep…") }
            }
        }
        .padding(.vertical, 4)
    }

    private var isFinished: Bool {
        if case .removed = outcome { return true }
        return false
    }

    @ViewBuilder
    private func result(_ outcome: DuplicateRemovalOutcome) -> some View {
        switch outcome {
        case .removed(let count, let bytes):
            Label(DuplicateRemovalOutcome.removedMessage(count: count, bytes: bytes), systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.safe)
        case .cancelled:
            Text("Cancelled. Nothing was removed.").font(.subheadline)
        case .sample:
            Text("Sample data. Nothing was removed.").font(.subheadline)
        case .blocked(let reason):
            Text(reason).font(.subheadline).foregroundStyle(Brand.caution)
        }
    }
}
