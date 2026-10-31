import Foundation

struct ResourceFingerprint: Codable, Hashable {
    let type: Int
    let digest: String
    let bytes: Int64
    var key: String { "\(type):\(bytes):\(digest)" }
}

struct AssetRecord: Codable, Identifiable {
    let id: String
    let filename: String
    let mediaType: Int
    let favorite: Bool
    let createdAt: Date?
    let resources: [ResourceFingerprint]
    let issue: String?

    var fingerprint: String? {
        guard issue == nil, !resources.isEmpty else { return nil }
        return "\(mediaType)|" + resources.map(\.key).sorted().joined(separator: "|")
    }
    var bytes: Int64 { resources.reduce(0) { $0 + $1.bytes } }
}

struct DuplicateGroup: Identifiable {
    let id: String
    let assets: [AssetRecord]
    // Candidate bytes only, not a promise of space reclaimed after synchronization.
    var extraBytes: Int64 { assets.dropFirst().reduce(0) { $0 + $1.bytes } }
}

struct ScanSnapshot: Codable {
    let date: Date
    let limitedAccess: Bool
    let includedCloudDownloads: Bool
    let assets: [AssetRecord]
    var groups: [DuplicateGroup] {
        let complete = assets.filter { $0.fingerprint != nil }
        return Dictionary(grouping: complete, by: { $0.fingerprint! })
            .filter { $0.value.count > 1 }
            .map { key, records in
                DuplicateGroup(id: key, assets: records.sorted {
                    if $0.favorite != $1.favorite { return $0.favorite }
                    return $0.id < $1.id
                })
            }.sorted { $0.id < $1.id }
    }
    var verifiedCount: Int { assets.filter { $0.fingerprint != nil }.count }
    var candidateBytes: Int64 { groups.reduce(0) { $0 + $1.extraBytes } }
}

struct ActivityEntry: Identifiable {
    let id: Int64
    let date: Date
    let message: String
}
