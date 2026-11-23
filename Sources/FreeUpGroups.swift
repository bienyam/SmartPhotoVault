import Foundation
import Photos

/// One look-alike set: the photo that stays, and the ones offered for removal.
struct KeepSet: Identifiable {
    let keep: AssetRecord
    let extras: [AssetRecord]
    /// Why this one stays, in a few words: "the sharpest".
    let because: String
    var id: String { keep.id }
}

/// A smart Free up group: what it holds, why, and exactly what is offered for removal and what stays.
struct CleanupGroup: Identifiable {
    enum Tier: String { case safe = "Safe to clear", probably = "Probably not needed" }

    let id: String
    let tier: Tier
    let title: String
    /// A few words on the card, such as "Keeps the sharpest".
    let why: String
    /// The info button: what is selected, what is kept, how TidyAway decides.
    let info: String
    /// Everything that can be selected for removal. Never a favorite, never a photo that is kept.
    let items: [AssetRecord]
    /// Look-alike sets, shown with the kept photo first. Empty for plain groups.
    var sets: [KeepSet] = []
    var symbol: String = "photo.on.rectangle"

    var bytes: Int64 { items.reduce(0) { $0 + $1.displayBytes } }
    var coverID: String? { items.first?.id }
}

/// Builds the smart Free up groups from the last scan and the on-device recognition results.
/// Every photo stays on the iPhone; nothing is sent anywhere.
enum CleanupGrouper {
    /// Below this, a photo has very little fine detail: out of focus or shaken.
    /// Measured on a 128-pixel copy. Cautious: only clearly soft pictures fall under it.
    static let blurLevel = 40.0
    /// Shots this dim and soft, with nothing recognised in them, are almost always accidental.
    static let accidentalLight = 35.0
    static let accidentalDetail = 80.0
    /// Videos shorter than this are nearly always a mis-tap.
    static let accidentalVideo = 2.0
    static let receiptAge: TimeInterval = 90 * 86_400
    static let screenshotAge: TimeInterval = 30 * 86_400
    /// Fewer than this and a group isn't worth a card.
    static let minimum = 3

    static let expiredLabels: Set<String> = ["receipt", "ticket", "parking_lot", "license_plate", "checkbook"]
    static let screenLabels: Set<String> = Set(Recognition.topics.filter { ["screens", "whiteboards"].contains($0.id) }.flatMap(\.labels))

    static func groups(in snapshot: ScanSnapshot, insights: [String: PhotoInsight], facts: [String: AssetFacts],
                       now: Date = .now) -> [CleanupGroup] {
        // Favorites and photos someone edited are kept out of every smart group.
        let candidates = snapshot.assets.filter { !$0.favorite && !(facts[$0.id]?.edited ?? false) && !$0.id.hasPrefix("sample-") }
        var result: [CleanupGroup] = []
        var taken = Set<String>()

        let sets = keepSets(in: snapshot.assets, insights: insights, facts: facts)
        let lookAlikes = sets.flatMap(\.extras)
        if lookAlikes.count >= minimum {
            result.append(CleanupGroup(
                id: "look-alike", tier: .safe, title: "Look-alike shots", why: "Keeps the sharpest",
                info: "Photos taken seconds apart that look nearly the same. In each set TidyAway keeps one, marked \"Keeping\" with a lock: a favorite or an edited photo if there is one, otherwise the sharpest. The kept photo is never selected and can't be. Only the others are offered, and nothing is selected until you choose.",
                items: lookAlikes, sets: sets, symbol: "square.on.square"))
            taken.formUnion(lookAlikes.map(\.id))
        }

        func photos(_ test: (AssetRecord, PhotoInsight) -> Bool) -> [AssetRecord] {
            candidates.filter { record in
                guard record.mediaType == PHAssetMediaType.image.rawValue, record.isScreenshot != true,
                      !taken.contains(record.id), let insight = insights[record.id] else { return false }
                return test(record, insight)
            }
            .sorted { ($0.createdAt ?? .distantPast, $0.id) < ($1.createdAt ?? .distantPast, $1.id) }
        }

        let dark = photos { _, insight in (insight.brightness ?? 255) < SmartGrouper.darkLevel }
        taken.formUnion(dark.map(\.id))

        var accidental = photos { _, insight in
            guard let light = insight.brightness else { return false }
            return light < accidentalLight && insight.sharpness < accidentalDetail && insight.labels.isEmpty && !insight.closeFace
        }
        let shortVideos = candidates.filter { record in
            guard record.mediaType == PHAssetMediaType.video.rawValue, !taken.contains(record.id),
                  let length = facts[record.id]?.duration else { return false }
            return length > 0 && length < accidentalVideo
        }
        accidental += shortVideos
        taken.formUnion(accidental.map(\.id))

        let blurry = photos { _, insight in
            insight.sharpness > 0 && insight.sharpness < blurLevel && !insight.closeFace && (insight.brightness ?? 0) >= SmartGrouper.darkLevel
        }
        taken.formUnion(blurry.map(\.id))

        if blurry.count >= minimum {
            result.append(CleanupGroup(
                id: "blurry", tier: .safe, title: "Blurry photos", why: "Out of focus",
                info: "Photos with very little sharp detail, measured on this \(Device.name): out of focus or shaken. Close-ups of faces, favorites and edited photos are never included. Every photo in the list is offered; nothing is selected until you choose, so check before deleting.",
                items: blurry, symbol: "camera.metering.unknown"))
        }
        if accidental.count >= minimum {
            result.append(CleanupGroup(
                id: "accidental", tier: .probably, title: "Accidental shots", why: "Pocket, floor, ceiling",
                info: "Dim, soft photos where nothing could be recognised, the kind taken in a pocket or pointing at the floor, plus videos shorter than 2 seconds. Favorites and edited items are never included. Nothing is selected until you choose.",
                items: accidental, symbol: "hand.raised.slash"))
        }
        if dark.count >= minimum {
            result.append(CleanupGroup(
                id: "dark", tier: .probably, title: "Too dark to see", why: "Nearly black",
                info: "Photos so dark that almost nothing shows. Favorites and edited photos are never included. Nothing is selected until you choose.",
                items: dark, symbol: "moon.fill"))
        }

        let expired = photos { record, insight in
            guard let shot = record.createdAt, now.timeIntervalSince(shot) > receiptAge else { return false }
            return !expiredLabels.isDisjoint(with: insight.labels)
        }
        taken.formUnion(expired.map(\.id))
        if expired.count >= minimum {
            result.append(CleanupGroup(
                id: "expired", tier: .probably, title: "Expired receipts & tickets", why: "Over 3 months old",
                info: "Photos that look like receipts, tickets, parking spots or number plates, taken more than 3 months ago. Recognition runs on this \(Device.name) and can be wrong, so look before deleting. Nothing is selected until you choose.",
                items: expired, symbol: "receipt"))
        }

        let screenshots = candidates.filter { record in
            guard record.isScreenshot == true, !taken.contains(record.id), let shot = record.createdAt else { return false }
            return now.timeIntervalSince(shot) > screenshotAge
        }
        .sorted { ($0.createdAt ?? .distantPast, $0.id) < ($1.createdAt ?? .distantPast, $1.id) }
        taken.formUnion(screenshots.map(\.id))
        if screenshots.count >= minimum {
            result.append(CleanupGroup(
                id: "old-screenshots", tier: .probably, title: "Old screenshots", why: "Over 30 days old",
                info: "Screenshots taken more than 30 days ago. Recent ones are left out. All screenshots are still under By type. Nothing is selected until you choose.",
                items: screenshots, symbol: "rectangle.dashed"))
        }

        let screens = photos { _, insight in !screenLabels.isDisjoint(with: insight.labels) }
        if screens.count >= minimum {
            result.append(CleanupGroup(
                id: "screens", tier: .probably, title: "Photos of screens & slides", why: "Taken as a reminder",
                info: "Photos of a computer or TV screen, a whiteboard or slides, usually taken to remember something. Recognition runs on this \(Device.name) and can be wrong. Nothing is selected until you choose.",
                items: screens, symbol: "display"))
        }
        return result
    }

    /// Look-alike sets with the photo that stays: a favorite, then an edited one, then the sharpest.
    static func keepSets(in assets: [AssetRecord], insights: [String: PhotoInsight], facts: [String: AssetFacts]) -> [KeepSet] {
        SmartGrouper.series(in: assets, insights: insights).compactMap { series in
            guard let keep = SmartGrouper.best(of: series, insights: insights, facts: facts) else { return nil }
            let extras = series.filter { $0.id != keep.id && !$0.favorite && !(facts[$0.id]?.edited ?? false) }
            guard !extras.isEmpty else { return nil }
            let because = keep.favorite ? "your favorite" : (facts[keep.id]?.edited ?? false) ? "the one you edited" : "the sharpest"
            return KeepSet(keep: keep, extras: extras, because: because)
        }
    }

    /// The one-tap suggestion: look-alike extras, blurry, accidental and dark photos together.
    static func suggestion(from groups: [CleanupGroup]) -> CleanupGroup? {
        let parts = groups.filter { ["look-alike", "blurry", "accidental", "dark"].contains($0.id) }
        var seen = Set<String>()
        let items = parts.flatMap(\.items).filter { seen.insert($0.id).inserted }
        guard items.count >= minimum else { return nil }
        return CleanupGroup(
            id: "for-you", tier: .safe, title: "Free \(items.reduce(0) { $0 + $1.displayBytes }.fileSize) in one go",
            why: parts.map { "\($0.items.count.formatted()) \($0.title.lowercased())" }.joined(separator: " · "),
            info: "The look-alike extras, blurry, accidental and too-dark photos together. In look-alike sets the best shot stays, marked \"Keeping\", and can't be selected. Favorites and edited photos are never included. Nothing is selected until you choose; you can tap Select all, then untick anything you want to keep.",
            items: items, sets: parts.first { $0.id == "look-alike" }?.sets ?? [], symbol: "sparkles")
    }
}
