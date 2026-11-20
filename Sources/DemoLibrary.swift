import Foundation
import CryptoKit
import Photos

enum DemoLibrary {
    static var snapshot: ScanSnapshot {
        func resource(_ contents: String, type: Int = 1) -> ResourceFingerprint {
            let data = Data(contents.utf8)
            return ResourceFingerprint(type: type, digest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), bytes: Int64(data.count))
        }
        func asset(_ id: String, _ name: String, _ favorite: Bool, _ resources: [ResourceFingerprint], issue: String? = nil,
                   mediaType: PHAssetMediaType = .image, subtypes: PHAssetMediaSubtype = [], animated: Bool = false,
                   burst: (id: String, frames: Int)? = nil) -> AssetRecord {
            AssetRecord(id: id, filename: name, mediaType: mediaType.rawValue, favorite: favorite, createdAt: nil, resources: resources, issue: issue,
                        isScreenshot: subtypes.contains(.photoScreenshot), subtypes: subtypes.rawValue, animated: animated,
                        burstID: burst?.id, burstFrames: burst?.frames)
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
            asset("sample-11", "Sunset.mov", false, [resource("synthetic time-lapse video", type: 2)], mediaType: .video, subtypes: .videoTimelapse)
        ])
    }
}
