import Foundation
import Photos

/// What the Free up tab offers, worked out once per scan rather than on every redraw.
struct RescueSummary {
    /// Videos read in full on this iPhone, largest first.
    let videos: [AssetRecord]
    /// Exact-duplicate groups with at least one removable extra copy.
    let duplicateGroups: [DuplicateGroup]
    let duplicatePlans: [DuplicateRemovalPlan]
    let screenshots: CleanCategorySummary
    /// Every type except screenshots, which has its own row.
    let otherTypes: [CleanCategorySummary]

    init(snapshot: ScanSnapshot) {
        videos = snapshot.assets
            .filter { $0.mediaType == PHAssetMediaType.video.rawValue && $0.fingerprint != nil }
            .sorted { $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes }
        var groups: [DuplicateGroup] = []
        var plans: [DuplicateRemovalPlan] = []
        for group in snapshot.groups {
            guard let plan = DuplicateRemovalPlan(group: group) else { continue }
            groups.append(group)
            plans.append(plan)
        }
        // Biggest savings first.
        let order = zip(groups, plans).sorted { $0.1.removeBytes > $1.1.removeBytes }
        duplicateGroups = order.map(\.0)
        duplicatePlans = order.map(\.1)
        let summaries = snapshot.recordsCategories ? snapshot.cleanSummaries() : []
        screenshots = summaries.first { $0.category == .screenshots }
            ?? CleanCategorySummary(category: .screenshots, items: [])
        otherTypes = summaries.filter { $0.category != .screenshots }
    }

    var videoBytes: Int64 { videos.reduce(0) { $0 + $1.bytes } }
    var duplicateBytes: Int64 { duplicatePlans.reduce(0) { $0 + $1.removeBytes } }
    var duplicateCopies: Int { duplicatePlans.reduce(0) { $0 + $1.removeIDs.count } }
    var otherBytes: Int64 { otherTypes.filter { $0.category.allowsRemoval }.reduce(0) { $0 + $1.knownBytes } }
    /// An upper bound: an item can appear in more than one row.
    var upToBytes: Int64 { videoBytes + duplicateBytes + screenshots.knownBytes }
}

/// Space on this iPhone, from the system's own volume figures.
struct DeviceStorage: Equatable {
    let available: Int64
    let total: Int64

    var used: Int64 { max(0, total - available) }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    static func current() -> DeviceStorage? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
              let available = values.volumeAvailableCapacityForImportantUsage,
              let total = values.volumeTotalCapacity, total > 0 else { return nil }
        return DeviceStorage(available: available, total: Int64(total))
    }
}

extension Int64 {
    var fileSize: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
