import Foundation

struct ResourceFingerprint: Codable, Hashable, Sendable {
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
    var isScreenshot: Bool? = nil
    // Added for Clean categories. Nil in scans saved before these were recorded.
    var subtypes: UInt? = nil
    var animated: Bool? = nil
    var burstID: String? = nil
    var burstFrames: Int? = nil
    var pixelWidth: Int? = nil
    var pixelHeight: Int? = nil
    var hasLocation: Bool? = nil
    // Added for Archive filters. Nil in scans saved before these were recorded.
    var albumIDs: [String]? = nil
    /// Rounded to two decimal places (about 1 km) and kept on this iPhone.
    var latitude: Double? = nil
    var longitude: Double? = nil
    /// Size Photos reports for originals that live only in iCloud (Optimize iPhone Storage).
    /// Nil when the item was read on this iPhone, or Photos reported no size.
    var cloudBytes: Int64? = nil

    var fingerprint: String? {
        guard issue == nil, !resources.isEmpty else { return nil }
        return "\(mediaType)|" + resources.map(\.key).sorted().joined(separator: "|")
    }
    var bytes: Int64 { resources.reduce(0) { $0 + $1.bytes } }
    /// True when the full-size original is in iCloud rather than on this iPhone.
    var inICloud: Bool { fingerprint == nil && cloudBytes != nil }
    /// Best known size: read on this iPhone, or reported by Photos for iCloud originals.
    var displayBytes: Int64 { fingerprint != nil ? bytes : (cloudBytes ?? 0) }
    /// Space the full original takes on this iPhone. Zero when it lives only in iCloud.
    var localBytes: Int64 { fingerprint != nil ? bytes : 0 }
    /// Size of an original kept only in iCloud; deleting it frees iCloud space, not phone space.
    var iCloudBytes: Int64 { inICloud ? (cloudBytes ?? 0) : 0 }
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
    /// Your own albums at scan time. Nil in scans saved before albums were recorded.
    var albums: [AlbumInfo]? = nil
    /// True when this scan can filter by album and place; older scans need a rescan.
    var recordsArchiveFilters: Bool { albums != nil }
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
    /// The same scan without items that were just deleted, so results stay usable without a rescan.
    func removing(_ ids: Set<String>) -> ScanSnapshot {
        ScanSnapshot(date: date, limitedAccess: limitedAccess, includedCloudDownloads: includedCloudDownloads,
                     assets: assets.filter { !ids.contains($0.id) }, albums: albums)
    }
    var verifiedCount: Int { assets.filter { $0.fingerprint != nil }.count }
    var candidateBytes: Int64 { groups.reduce(0) { $0 + $1.extraBytes } }
}

struct AlbumInfo: Codable, Identifiable, Hashable {
    let id: String
    let title: String
}

/// A rectangle on the map chosen for the Archive place filter.
struct PlaceArea: Equatable {
    let minLatitude: Double
    let maxLatitude: Double
    let minLongitude: Double
    let maxLongitude: Double

    func contains(_ record: AssetRecord) -> Bool {
        guard let latitude = record.latitude, let longitude = record.longitude else { return false }
        return (minLatitude...maxLatitude).contains(latitude) && (minLongitude...maxLongitude).contains(longitude)
    }

    static func rounded(_ value: Double) -> Double { (value * 100).rounded() / 100 }
}

struct ActivityEntry: Identifiable {
    let id: Int64
    let date: Date
    let message: String
}
