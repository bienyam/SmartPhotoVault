import Photos
import Foundation

/// Ways to look through the library by type. Review only: nothing here removes anything.
enum CleanCategory: String, CaseIterable, Identifiable {
    case screenshots, gifs, bursts, livePhotos, sloMo, timeLapse, panoramas

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenshots: "Screenshots"
        case .gifs: "GIFs"
        case .bursts: "Bursts"
        case .livePhotos: "Live Photos"
        case .sloMo: "Slo-mo videos"
        case .timeLapse: "Time-lapse videos"
        case .panoramas: "Panoramas"
        }
    }

    var systemImage: String {
        switch self {
        case .screenshots: "camera.viewfinder"
        case .gifs: "photo.stack"
        case .bursts: "square.stack.3d.down.right"
        case .livePhotos: "livephoto"
        case .sloMo: "slowmo"
        case .timeLapse: "timelapse"
        case .panoramas: "pano"
        }
    }

    var guidance: String {
        switch self {
        case .screenshots:
            "Screenshots are often useful for a day and then forgotten. Look for ones you no longer need."
        case .gifs:
            "Animated images saved from chats and the web. Most are easy to find again online."
        case .bursts:
            "Each burst keeps every frame, even though Photos shows only one. In Photos, open a burst, tap Select, and keep just the frames you like."
        case .livePhotos:
            "A Live Photo stores a short video next to the still. Photos keeps that video even if you turn Live off, so space comes back only when you delete a photo you don't need."
        case .sloMo:
            "Slo-mo is recorded at a high frame rate, so these videos are larger than they look."
        case .timeLapse:
            "Time-lapses are usually small, but long ones can add up."
        case .panoramas:
            "Panoramas are very wide, high-resolution photos, often several times the size of a normal photo."
        }
    }

    func includes(_ asset: AssetRecord) -> Bool {
        let subtypes = PHAssetMediaSubtype(rawValue: asset.subtypes ?? 0)
        switch self {
        case .screenshots: return subtypes.contains(.photoScreenshot)
        case .gifs: return asset.animated == true
        case .bursts: return asset.burstID != nil
        case .livePhotos: return subtypes.contains(.photoLive)
        case .sloMo: return subtypes.contains(.videoHighFrameRate)
        case .timeLapse: return subtypes.contains(.videoTimelapse)
        case .panoramas: return subtypes.contains(.photoPanorama)
        }
    }
}

struct CleanCategorySummary {
    let category: CleanCategory
    /// Largest first; items without a full reading follow, in a stable order.
    let items: [AssetRecord]
    /// Bytes of items read in full during the scan. An estimate, not guaranteed recoverable space.
    var knownBytes: Int64 { items.filter { $0.fingerprint != nil }.reduce(0) { $0 + $1.bytes } }
    var unreadCount: Int { items.filter { $0.fingerprint == nil }.count }
    /// Bursts only: every frame Photos keeps, including the hidden ones.
    var burstFrames: Int { items.reduce(0) { $0 + max($1.burstFrames ?? 1, 1) } }
}

extension ScanSnapshot {
    /// False for scans saved before categories were recorded; those need a new scan.
    var recordsCategories: Bool { assets.isEmpty || assets.contains { $0.subtypes != nil } }

    /// All categories at once, so views don't re-filter the library on every redraw.
    func cleanSummaries() -> [CleanCategorySummary] {
        CleanCategory.allCases.map(summary(for:))
    }

    func summary(for category: CleanCategory) -> CleanCategorySummary {
        var seenBursts = Set<String>()
        let matching = assets.filter { asset in
            guard category.includes(asset) else { return false }
            // One row per burst, even if Photos returns more than one photo from it.
            if category == .bursts, let burst = asset.burstID { return seenBursts.insert(burst).inserted }
            return true
        }
        let items = matching.sorted { lhs, rhs in
            let left = lhs.fingerprint == nil ? -1 : lhs.bytes
            let right = rhs.fingerprint == nil ? -1 : rhs.bytes
            return left == right ? lhs.id < rhs.id : left > right
        }
        return CleanCategorySummary(category: category, items: items)
    }
}
