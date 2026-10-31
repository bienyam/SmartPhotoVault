import Foundation
import CryptoKit

enum DemoLibrary {
    static var snapshot: ScanSnapshot {
        func resource(_ contents: String, type: Int = 1) -> ResourceFingerprint {
            let data = Data(contents.utf8)
            return ResourceFingerprint(type: type, digest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), bytes: Int64(data.count))
        }
        func asset(_ id: String, _ name: String, _ favorite: Bool, _ resources: [ResourceFingerprint], issue: String? = nil) -> AssetRecord {
            AssetRecord(id: id, filename: name, mediaType: 1, favorite: favorite, createdAt: nil, resources: resources, issue: issue)
        }
        return ScanSnapshot(date: Date(), limitedAccess: false, includedCloudDownloads: false, assets: [
            asset("sample-1", "Beach.heic", true, [resource("synthetic beach image")]),
            asset("sample-2", "Beach copy.heic", false, [resource("synthetic beach image")]),
            asset("sample-3", "Live Photo.heic", false, [resource("synthetic still"), resource("synthetic motion", type: 9)]),
            asset("sample-4", "Different motion.heic", false, [resource("synthetic still"), resource("different motion", type: 9)]),
            asset("sample-5", "Cloud-only.heic", false, [], issue: "Original resource is not available locally.")
        ])
    }
}
