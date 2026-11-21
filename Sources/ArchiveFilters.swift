import Foundation
import Photos

/// What kind of items the Archive tab suggests.
enum ArchiveKind: String, CaseIterable {
    case photos = "All photos"
    case screenshots = "Screenshots only"
    case notScreenshots = "No screenshots"
    case videos = "Videos"
}

/// The choices on the Archive tab, applied to the last scan. Favorites are never suggested.
struct ArchiveSuggestionFilter {
    var olderThanYears: Int?
    var minimumBytes: Int64 = 0
    var kind: ArchiveKind = .photos
    var albumID: String?
    var place: PlaceArea?
    var limit = 200

    func matches(in snapshot: ScanSnapshot, now: Date = .now) -> [AssetRecord] {
        let cutoff = olderThanYears.flatMap { Calendar.current.date(byAdding: .year, value: -$0, to: now) }
        return snapshot.assets.filter { record in
            guard record.issue == nil, !record.favorite, record.resources.count == 1,
                  record.bytes >= minimumBytes else { return false }
            guard kindMatches(record) else { return false }
            if let cutoff, !(record.createdAt.map { $0 < cutoff } ?? false) { return false }
            if let albumID, !(record.albumIDs?.contains(albumID) ?? false) { return false }
            if let place, !place.contains(record) { return false }
            return true
        }
        .sorted { $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes }
        .prefix(limit)
        .map { $0 }
    }

    private func kindMatches(_ record: AssetRecord) -> Bool {
        let resourceType = record.resources.first?.type
        if kind == .videos {
            return record.mediaType == PHAssetMediaType.video.rawValue
                && resourceType == PHAssetResourceType.video.rawValue
        }
        guard record.mediaType == PHAssetMediaType.image.rawValue,
              resourceType == PHAssetResourceType.photo.rawValue else { return false }
        switch kind {
        case .screenshots: return record.isScreenshot == true
        case .notScreenshots: return record.isScreenshot != true
        case .photos, .videos: return true
        }
    }
}
