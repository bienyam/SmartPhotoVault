import Foundation
import CryptoKit
import Photos
import UIKit

enum DemoLibrary {
    /// Made-up items for the Archive screens in UI tests (--demo-archive). Nothing here can be copied.
    static var archiveSnapshot: ScanSnapshot {
        func item(_ id: String, _ seconds: TimeInterval, video: Bool = false, bytes: Int64, at place: (Double, Double)) -> AssetRecord {
            AssetRecord(id: "sample-\(id)", filename: "\(id).\(video ? "MOV" : "HEIC")",
                        mediaType: (video ? PHAssetMediaType.video : .image).rawValue, favorite: false,
                        createdAt: Date(timeIntervalSince1970: seconds),
                        resources: [ResourceFingerprint(type: (video ? PHAssetResourceType.video : .photo).rawValue, digest: id, bytes: bytes)],
                        issue: nil, isScreenshot: false, subtypes: 0, albumIDs: video ? [] : ["album"],
                        latitude: place.0, longitude: place.1)
        }
        let home = (44.95, -93.1), away = (36.1, -112.1), start: TimeInterval = 1_718_390_000
        var assets: [AssetRecord] = []
        for index in 0..<48 { assets.append(item("party\(index)", start + Double(index) * 420, bytes: 4_200_000, at: home)) }
        for day in 0..<4 {
            for index in 0..<30 { assets.append(item("trip\(day)-\(index)", start + Double(18 + day) * 86_400 + Double(index) * 600, bytes: 3_900_000, at: away)) }
        }
        for index in 0..<6 { assets.append(item("clip\(index)", start + 60 * 86_400 + Double(index) * 90_000, video: true, bytes: 900_000_000, at: home)) }
        return ScanSnapshot(date: Date(timeIntervalSince1970: start), limitedAccess: false, includedCloudDownloads: false, assets: assets,
                            albums: [AlbumInfo(id: "album", title: "Family")])
    }

    /// Made-up recognition for the sample items above.
    static var archiveInsights: [String: PhotoInsight] {
        var result: [String: PhotoInsight] = [:]
        for index in 0..<48 {
            let id = "sample-party\(index)"
            result[id] = PhotoInsight(id: id, labels: index % 12 == 0 ? ["birthday_cake"] : ["food"], sharpness: Double(index % 7),
                                      sameAs: index > 0 && index < 10 ? "sample-party\(index - 1)" : nil)
        }
        for day in 0..<4 {
            for index in 0..<30 {
                let id = "sample-trip\(day)-\(index)"
                result[id] = PhotoInsight(id: id, labels: index % 3 == 0 ? ["beach"] : [])
            }
        }
        return result
    }

    static var snapshot: ScanSnapshot {
        // App Store pictures use sizes like real photos and videos; tests keep the tiny ones they were written for.
        let lifelike = LaunchFlags.has("--store-pictures")
        func resource(_ contents: String, type: Int = 1, size: Int64? = nil) -> ResourceFingerprint {
            let data = Data(contents.utf8)
            return ResourceFingerprint(type: type, digest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                                       bytes: lifelike ? (size ?? Int64(data.count)) : Int64(data.count))
        }
        func asset(_ id: String, _ name: String, _ favorite: Bool, _ resources: [ResourceFingerprint], issue: String? = nil,
                   mediaType: PHAssetMediaType = .image, subtypes: PHAssetMediaSubtype = [], animated: Bool = false,
                   burst: (id: String, frames: Int)? = nil, pixels: (Int, Int) = (4032, 3024), hasLocation: Bool = true) -> AssetRecord {
            AssetRecord(id: id, filename: name, mediaType: mediaType.rawValue, favorite: favorite, createdAt: nil, resources: resources, issue: issue,
                        isScreenshot: subtypes.contains(.photoScreenshot), subtypes: subtypes.rawValue, animated: animated,
                        burstID: burst?.id, burstFrames: burst?.frames,
                        pixelWidth: pixels.0, pixelHeight: pixels.1, hasLocation: hasLocation)
        }
        // App Store pictures only: a fuller list of large videos. Tests keep the two they were written for.
        let moreVideos: [AssetRecord] = lifelike ? storeVideos.enumerated().map { index, video in
            asset("sample-\(index + 13)", video.name, false, [resource("synthetic store video \(index)", type: 2, size: video.bytes)], mediaType: .video)
        } : []
        return ScanSnapshot(date: Date(), limitedAccess: false, includedCloudDownloads: false, assets: [
            asset("sample-1", "Beach.heic", true, [resource("synthetic beach image", size: 3_400_000)]),
            asset("sample-2", "Beach copy.heic", false, [resource("synthetic beach image", size: 3_400_000)]),
            asset("sample-3", "Live Photo.heic", false, [resource("synthetic still", size: 2_800_000), resource("synthetic motion", type: 9, size: 3_100_000)], subtypes: .photoLive),
            asset("sample-4", "Different motion.heic", false, [resource("synthetic still", size: 2_800_000), resource("different motion", type: 9, size: 3_000_000)], subtypes: .photoLive),
            asset("sample-5", "Cloud-only.heic", false, [], issue: "Original resource is not available locally."),
            asset("sample-6", "Boarding pass.png", false, [resource("synthetic screenshot", size: 1_200_000)], subtypes: .photoScreenshot),
            asset("sample-7", "Dancing cat.gif", false, [resource("synthetic animated image", size: 4_500_000)], animated: true),
            asset("sample-8", "Goal celebration.heic", false, [resource("synthetic burst frame", size: 2_900_000)], burst: ("demo-burst", 14)),
            asset("sample-9", "Mountain view.heic", false, [resource("synthetic panorama", size: 18_000_000)], subtypes: .photoPanorama),
            asset("sample-10", "Skate trick.mov", false, [resource("synthetic slow motion video", type: 2, size: lifelike ? 2_600_000_000 : 1_600_000_000)], mediaType: .video, subtypes: .videoHighFrameRate),
            asset("sample-11", "Sunset.mov", false, [resource("synthetic time-lapse video", type: 2, size: lifelike ? 1_900_000_000 : 820_000_000)], mediaType: .video, subtypes: .videoTimelapse),
            asset("sample-12", "IMG-20240512-WA0007.jpg", false, [resource("synthetic chat image", size: 280_000)], pixels: (1280, 960), hasLocation: false)
        ] + moreVideos)
    }
}

// MARK: - App Store pictures

/// Stand-ins used only when the store screenshots are made (the test-only `--store-pictures` flag).
/// `LaunchFlags` is always off in App Store builds, so none of this can show for a customer.
extension DemoLibrary {
    /// The folder the Copy screen shows as chosen. Nothing is ever written to it.
    static let archiveFolder = URL(fileURLWithPath: "/TidyAway Archive", isDirectory: true)
    static let archiveFolderFree: Int64 = 186_000_000_000

    /// The iPhone the pictures show: 128 GB with 14.4 GB free, which scores 45 (C, Getting full).
    static let storage = DeviceStorage(available: 14_400_000_000, total: 128_000_000_000)

    /// Extra large videos for the pictures (ids sample-13 onwards).
    static let storeVideos: [(name: String, bytes: Int64)] = [
        ("Birthday candles.mov", 4_125_400_000), ("School play.mov", 1_400_000_000), ("Beach day.mov", 1_100_000_000),
        ("First steps.mov", 920_000_000), ("Road trip.mov", 810_000_000), ("Fireworks.mov", 640_000_000),
        ("Snow day.mov", 520_000_000), ("Puppy.mov", 430_000_000), ("Concert.mov", 310_000_000),
        ("Kitchen dance.mov", 240_000_000)
    ]

    /// The sample videos the pictures treat as already archived, for the "not backed up" check.
    static let backedUp: Set<String> = ["sample-13", "sample-10", "sample-11"]

    /// Stand-in archive records for Get back. Nil unless the store screenshots are being made.
    static var archivedRecords: [ArchivedRecord]? {
        guard LaunchFlags.has("--store-pictures") else { return nil }
        let day: TimeInterval = 86_400
        let noon = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3_600)
        func record(_ id: String, _ name: String, _ bytes: Int64, daysAgo: Double, minute: Int) -> ArchivedRecord {
            ArchivedRecord(id: "store-\(id)", name: name, folderName: "TidyAway Archive", bytes: bytes, digest: id,
                           date: noon.addingTimeInterval(-daysAgo * day + Double(minute) * 60), viaHomeServer: false,
                           folderBookmark: nil, photoID: "sample-\(id)")
        }
        var records: [ArchivedRecord] = []
        for index in 0..<6 { records.append(record("clip\(index)", "Video \(index + 1).MOV", 900_000_000, daysAgo: 2, minute: index)) }
        for index in 0..<24 { records.append(record("trip0-\(index)", "Beach \(index + 1).HEIC", 3_900_000, daysAgo: 9, minute: index)) }
        for index in 0..<18 { records.append(record("party\(index)", "Party \(index + 1).HEIC", 4_200_000, daysAgo: 23, minute: index)) }
        return records
    }

    /// The Storage Checkup with one step done, as it looks after free space rose. Nil unless the
    /// store screenshots are being made.
    static func checkup(free: Int64) -> CheckupProgress? {
        guard LaunchFlags.has("--store-pictures") else { return nil }
        let gained: Int64 = 2_100_000_000
        var progress = CheckupProgress(free: free - gained)
        progress.results = ["recently-deleted": gained]
        progress.lastFree = free
        return progress
    }

    /// The note a real run shows when the copied items can be removed afterwards.
    static func completionNote(_ done: ArchiveCompletion) -> String {
        "They're still on your \(Device.name) too. Every copy is checked again before anything is removed: up to \(done.bytes.fileSize)."
    }

    /// A drawn picture for a sample item, so lists and cards aren't rows of grey placeholders.
    /// Nil unless the store screenshots are being made.
    static func picture(for id: String) -> UIImage? {
        guard LaunchFlags.has("--store-pictures") else { return nil }
        return draw(id)
    }

    private struct Dice {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double((state >> 33) % 10_000) / 10_000
        }
    }

    private static func color(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) -> UIColor {
        UIColor(red: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha))
    }

    private static func band(_ context: CGContext, _ rect: CGRect, _ colors: [UIColor]) {
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: colors.map { $0.cgColor } as CFArray, locations: nil) else { return }
        context.saveGState()
        context.clip(to: rect)
        context.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.minY),
                                   end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
        context.restoreGState()
    }

    private static func glow(_ context: CGContext, at center: CGPoint, radius: CGFloat, _ tint: UIColor) {
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: [tint.cgColor, tint.withAlphaComponent(0).cgColor] as CFArray, locations: nil) else { return }
        context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    }

    private static func ridge(_ context: CGContext, side: CGFloat, base: CGFloat, height: CGFloat, dice: inout Dice, _ fill: UIColor) {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 0, y: side))
        path.addLine(to: CGPoint(x: 0, y: base))
        var x: CGFloat = 0
        while x < side {
            x += side * CGFloat(0.10 + dice.next() * 0.14)
            path.addLine(to: CGPoint(x: x, y: base - height * CGFloat(0.25 + dice.next() * 0.75)))
        }
        path.addLine(to: CGPoint(x: side, y: base))
        path.addLine(to: CGPoint(x: side, y: side))
        path.close()
        context.setFillColor(fill.cgColor)
        context.addPath(path.cgPath)
        context.fillPath()
    }

    private static func draw(_ id: String) -> UIImage {
        let side: CGFloat = 600
        var dice = Dice(state: id.unicodeScalars.reduce(UInt64(5381)) { ($0 &* 33) ^ UInt64($1.value) })
        _ = dice.next()
        let scene: Int
        if id == "sample-11" { scene = 0 }
        else if id == "sample-10" { scene = 3 }
        else if id.hasPrefix("sample-party") { scene = 2 }
        else if id.hasPrefix("sample-trip") { scene = 1 }
        else if id.hasPrefix("sample-clip") { scene = Int(dice.next() * 2) == 0 ? 3 : 0 }
        else { scene = Int(dice.next() * 4) }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { renderer in
            let context = renderer.cgContext
            let full = CGRect(x: 0, y: 0, width: side, height: side)
            let shift = dice.next() * 0.12 - 0.06
            switch scene {
            case 0:
                // Sunset over water.
                let horizon = side * CGFloat(0.60 + dice.next() * 0.06)
                band(context, CGRect(x: 0, y: 0, width: side, height: horizon),
                     [color(0.20 + shift, 0.14, 0.38), color(0.86, 0.36 + shift, 0.30), color(1.0, 0.72, 0.38)])
                let sun = CGPoint(x: side * CGFloat(0.30 + dice.next() * 0.40), y: horizon - side * 0.05)
                glow(context, at: sun, radius: side * 0.42, color(1.0, 0.86, 0.55, 0.85))
                context.setFillColor(color(1.0, 0.95, 0.78).cgColor)
                context.fillEllipse(in: CGRect(x: sun.x - 46, y: sun.y - 46, width: 92, height: 92))
                band(context, CGRect(x: 0, y: horizon, width: side, height: side - horizon),
                     [color(0.88, 0.48, 0.30), color(0.24, 0.16, 0.36)])
                for step in 0..<9 {
                    let y = horizon + CGFloat(step) * 22 + 8
                    let width = CGFloat(150 - step * 12) * CGFloat(0.7 + dice.next() * 0.6)
                    context.setFillColor(color(1.0, 0.86, 0.60, 0.55 - Double(step) * 0.05).cgColor)
                    context.fill(CGRect(x: sun.x - width / 2, y: y, width: width, height: 6))
                }
                ridge(context, side: side, base: horizon + 4, height: side * 0.07, dice: &dice, color(0.14, 0.09, 0.22))
            case 1:
                // Beach.
                let sea = side * CGFloat(0.46 + dice.next() * 0.06)
                let sand = side * CGFloat(0.68 + dice.next() * 0.05)
                band(context, CGRect(x: 0, y: 0, width: side, height: sea), [color(0.25, 0.58 + shift, 0.90), color(0.74, 0.89, 0.98)])
                for _ in 0..<4 {
                    let x = side * CGFloat(dice.next()), y = side * CGFloat(0.06 + dice.next() * 0.26)
                    glow(context, at: CGPoint(x: x, y: y), radius: side * CGFloat(0.10 + dice.next() * 0.08), color(1, 1, 1, 0.85))
                }
                band(context, CGRect(x: 0, y: sea, width: side, height: sand - sea), [color(0.05, 0.42, 0.62), color(0.30, 0.78 + shift, 0.78)])
                band(context, CGRect(x: 0, y: sand, width: side, height: side - sand), [color(0.97, 0.90, 0.72), color(0.86, 0.72, 0.50)])
                context.setFillColor(color(1, 1, 1, 0.85).cgColor)
                context.fill(CGRect(x: 0, y: sand - 5, width: side, height: 9))
                let pole = side * CGFloat(0.22 + dice.next() * 0.5)
                context.setFillColor(color(0.95, 0.35 + shift, 0.22).cgColor)
                context.fillEllipse(in: CGRect(x: pole - 80, y: sand + 10, width: 160, height: 70))
                context.setFillColor(color(0.97, 0.90, 0.72).cgColor)
                context.fill(CGRect(x: pole - 90, y: sand + 46, width: 180, height: 40))
                context.setFillColor(color(0.35, 0.25, 0.20).cgColor)
                context.fill(CGRect(x: pole - 3, y: sand + 40, width: 6, height: 90))
            case 2:
                // Evening table with lights.
                band(context, full, [color(0.16, 0.08, 0.12), color(0.50 + shift, 0.22, 0.14)])
                for _ in 0..<26 {
                    let x = side * CGFloat(dice.next()), y = side * CGFloat(dice.next() * 0.62)
                    let warm = dice.next()
                    glow(context, at: CGPoint(x: x, y: y), radius: side * CGFloat(0.04 + dice.next() * 0.07),
                         color(1.0, 0.62 + warm * 0.3, 0.25 + warm * 0.35, 0.55))
                }
                band(context, CGRect(x: 0, y: side * 0.70, width: side, height: side * 0.30), [color(0.42, 0.26, 0.18), color(0.24, 0.14, 0.10)])
                let plate = CGRect(x: side * CGFloat(0.20 + dice.next() * 0.2), y: side * 0.62, width: side * 0.44, height: side * 0.20)
                context.setFillColor(color(0.97, 0.95, 0.90).cgColor)
                context.fillEllipse(in: plate)
                context.setFillColor(color(0.93, 0.60 + shift, 0.52).cgColor)
                context.fillEllipse(in: plate.insetBy(dx: plate.width * 0.22, dy: plate.height * 0.20))
                context.setFillColor(color(0.99, 0.93, 0.80).cgColor)
                context.fillEllipse(in: plate.insetBy(dx: plate.width * 0.30, dy: plate.height * 0.34).offsetBy(dx: 0, dy: -8))
            default:
                // Hills at dusk.
                band(context, full, [color(0.28, 0.42 + shift, 0.72), color(0.98, 0.76, 0.56)])
                glow(context, at: CGPoint(x: side * CGFloat(0.25 + dice.next() * 0.5), y: side * 0.52), radius: side * 0.36, color(1.0, 0.90, 0.70, 0.8))
                ridge(context, side: side, base: side * 0.66, height: side * 0.30, dice: &dice, color(0.42, 0.46, 0.66))
                ridge(context, side: side, base: side * 0.78, height: side * 0.26, dice: &dice, color(0.26, 0.30, 0.48))
                ridge(context, side: side, base: side * 0.92, height: side * 0.22, dice: &dice, color(0.13, 0.16, 0.28))
            }
            // A soft darker edge, as a lens gives.
            guard let edge = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: [UIColor.black.withAlphaComponent(0).cgColor, UIColor.black.withAlphaComponent(0.28).cgColor] as CFArray,
                                        locations: [0.55, 1]) else { return }
            context.drawRadialGradient(edge, startCenter: CGPoint(x: side / 2, y: side / 2), startRadius: 0,
                                       endCenter: CGPoint(x: side / 2, y: side / 2), endRadius: side * 0.75, options: [])
        }
    }
}
