import Foundation
import CryptoKit
import Photos

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
            asset("sample-10", "Skate trick.mov", false, [resource("synthetic slow motion video", type: 2, size: 1_600_000_000)], mediaType: .video, subtypes: .videoHighFrameRate),
            asset("sample-11", "Sunset.mov", false, [resource("synthetic time-lapse video", type: 2, size: 820_000_000)], mediaType: .video, subtypes: .videoTimelapse),
            asset("sample-12", "IMG-20240512-WA0007.jpg", false, [resource("synthetic chat image", size: 280_000)], pixels: (1280, 960), hasLocation: false)
        ])
    }
}
