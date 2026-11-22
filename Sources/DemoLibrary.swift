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

    static var snapshot: ScanSnapshot {
        func resource(_ contents: String, type: Int = 1) -> ResourceFingerprint {
            let data = Data(contents.utf8)
            return ResourceFingerprint(type: type, digest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), bytes: Int64(data.count))
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
            asset("sample-1", "Beach.heic", true, [resource("synthetic beach image")]),
            asset("sample-2", "Beach copy.heic", false, [resource("synthetic beach image")]),
            asset("sample-3", "Live Photo.heic", false, [resource("synthetic still"), resource("synthetic motion", type: 9)], subtypes: .photoLive),
            asset("sample-4", "Different motion.heic", false, [resource("synthetic still"), resource("different motion", type: 9)], subtypes: .photoLive),
            asset("sample-5", "Cloud-only.heic", false, [], issue: "Original resource is not available locally."),
            asset("sample-6", "Boarding pass.png", false, [resource("synthetic screenshot")], subtypes: .photoScreenshot),
            asset("sample-7", "Dancing cat.gif", false, [resource("synthetic animated image")], animated: true),
            asset("sample-8", "Goal celebration.heic", false, [resource("synthetic burst frame")], burst: ("demo-burst", 14)),
            asset("sample-9", "Mountain view.heic", false, [resource("synthetic panorama")], subtypes: .photoPanorama),
            asset("sample-10", "Skate trick.mov", false, [resource("synthetic slow motion video", type: 2)], mediaType: .video, subtypes: .videoHighFrameRate),
            asset("sample-11", "Sunset.mov", false, [resource("synthetic time-lapse video", type: 2)], mediaType: .video, subtypes: .videoTimelapse),
            asset("sample-12", "IMG-20240512-WA0007.jpg", false, [resource("synthetic chat image")], pixels: (1280, 960), hasLocation: false)
        ])
    }
}
