import Photos
import Foundation

/// Ways to look through the library by type. Review only: nothing here removes anything.
enum CleanCategory: String, CaseIterable, Identifiable {
    case screenshots, gifs, bursts, livePhotos, sloMo, timeLapse, panoramas, savedImages

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
        case .savedImages: "Saved from chats (a guess)"
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
        case .savedImages: "bubble.left.and.bubble.right"
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
        case .savedImages:
            "Photos doesn't record which app an image came from, so this is a guess. TidyAway looks for chat-app file names, and for smaller images with no location, which is typical of pictures saved from chats and the web. Some of your own photos may appear here too, such as cropped photos or ones from older phones, so look carefully."
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
        case .savedImages: return SavedImageHeuristic.matches(asset, subtypes: subtypes)
        }
    }
}

/// A guess, never a fact: Photos doesn't record the source app. Review only.
enum SavedImageHeuristic {
    /// A long side at or below this is typical of images sent through chat apps; camera photos are larger.
    static let maxChatSide = 2048

    static func matches(_ asset: AssetRecord, subtypes: PHAssetMediaSubtype) -> Bool {
        guard asset.mediaType == PHAssetMediaType.image.rawValue,
              asset.subtypes != nil,
              !subtypes.contains(.photoScreenshot),
              !subtypes.contains(.photoPanorama),
              !subtypes.contains(.photoLive),
              asset.animated != true,
              asset.burstID == nil else { return false }
        if hasChatFilename(asset.filename) { return true }
        guard asset.hasLocation == false, let width = asset.pixelWidth, let height = asset.pixelHeight,
              width > 0, height > 0 else { return false }
        return max(width, height) <= maxChatSide
    }

    /// Android WhatsApp ("IMG-20240512-WA0007.jpg") and Telegram ("photo_2024-05-12_10-20-30.jpg") naming.
    /// Mostly seen in libraries moved over from Android; on iPhone, the size and location test does most of the work.
    static func hasChatFilename(_ name: String) -> Bool {
        let patterns = [#"-WA\d+\."#, #"^photo_\d{4}-\d{2}-\d{2}"#]
        return patterns.contains { name.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }
}

struct CleanCategorySummary {
    let category: CleanCategory
    /// Largest first; items without a full reading follow, in a stable order.
    let items: [AssetRecord]
    /// Bytes of items read in full during the scan. An estimate, not guaranteed recoverable space.
    var knownBytes: Int64 { items.filter { $0.fingerprint != nil }.reduce(0) { $0 + $1.bytes } }
    /// Read on this iPhone plus sizes Photos reports for originals kept in iCloud.
    var displayBytes: Int64 { items.reduce(0) { $0 + $1.displayBytes } }
    /// Phone space only.
    var localBytes: Int64 { items.reduce(0) { $0 + $1.localBytes } }
    var iCloudBytes: Int64 { items.reduce(0) { $0 + $1.iCloudBytes } }
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
            let left = lhs.fingerprint == nil && lhs.cloudBytes == nil ? -1 : lhs.displayBytes
            let right = rhs.fingerprint == nil && rhs.cloudBytes == nil ? -1 : rhs.displayBytes
            return left == right ? lhs.id < rhs.id : left > right
        }
        return CleanCategorySummary(category: category, items: items)
    }
}
