import Foundation

/// Which copies of one exact-duplicate group stay and which may be removed.
/// The first asset in a group is kept. Favorites are never removed.
struct DuplicateRemovalPlan: Equatable, Sendable {
    let keepID: String
    let keepFilename: String
    let removeIDs: [String]
    let removeBytes: Int64
    let fingerprint: String

    /// With `selection`, only the extra copies the user selected are removed; the rest stay.
    init?(group: DuplicateGroup, onlyRemoving selection: Set<String>? = nil) {
        guard let keep = group.assets.first, let fingerprint = keep.fingerprint else { return nil }
        let removable = group.assets.dropFirst().filter {
            !$0.favorite && $0.fingerprint == fingerprint && (selection?.contains($0.id) ?? true)
        }
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
