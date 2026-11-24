import Foundation
import Photos
import UniformTypeIdentifiers

/// One more file of an archived item that Photos keeps as several files: a Live Photo's video, or an
/// edited photo's edit instructions and edited picture. The item's own record holds the original still;
/// each of these sits beside it in the archive and was checked the same way when it was copied.
struct ArchivedPart: Codable, Equatable, Sendable {
    /// Which file of the item this is (Photos' own resource type number).
    let type: Int
    /// The name it was stored under, beside the original.
    let name: String
    let bytes: Int64
    let digest: String
    /// Google Drive, OneDrive or Dropbox: that service's ID for this file.
    var fileID: String? = nil
    /// OneDrive or Dropbox: the service's own fingerprint of this file, matched when it was archived.
    var cloudHash: String? = nil
}

/// Which Photos items made of several files can be archived, which files that means, and what each is
/// called in the archive. Photos and videos kept as one file don't come through here.
enum ArchivePlan {
    static let photo = PHAssetResourceType.photo.rawValue
    static let pairedVideo = PHAssetResourceType.pairedVideo.rawValue
    static let adjustmentData = PHAssetResourceType.adjustmentData.rawValue
    static let fullSizePhoto = PHAssetResourceType.fullSizePhoto.rawValue
    static let fullSizePairedVideo = PHAssetResourceType.fullSizePairedVideo.rawValue

    /// The order the files are copied and listed in: the original still first.
    static let order = [photo, pairedVideo, adjustmentData, fullSizePhoto, fullSizePairedVideo]

    /// The files to copy for a photo that Photos keeps as these resources, original still first.
    /// Nil when it is a single file (handled the way it always was) or a combination that can't be
    /// archived yet: videos with extra files (slo-mo, edited videos), RAW pairs, and anything else
    /// TidyAway doesn't know how to put back.
    ///
    /// Supported, and nothing else:
    /// - Live Photo: still + its video.
    /// - Edited photo: original + edit instructions + the edited picture.
    /// - Edited Live Photo: all of those, with or without an edited video.
    static func parts(mediaType: Int, types: [Int]) -> [Int]? {
        guard mediaType == PHAssetMediaType.image.rawValue, types.count > 1 else { return nil }
        let set = Set(types)
        // Two files of one kind can't be told apart when putting the item back.
        guard set.count == types.count, set.contains(photo), set.isSubset(of: Set(order)) else { return nil }
        let live = set.contains(pairedVideo)
        let edited = set.contains(adjustmentData)
        // An edit is its instructions and its picture together; one without the other can't be rebuilt.
        guard edited == set.contains(fullSizePhoto) else { return nil }
        if set.contains(fullSizePairedVideo) { guard live, edited else { return nil } }
        guard live || edited else { return nil }
        return order.filter(set.contains)
    }

    /// The name one file of an item is stored under, beside the original, the way Apple's own exports
    /// lay them out: `IMG_1234.HEIC`, `IMG_1234.MOV` (the Live Photo's video), `IMG_1234.AAE` (the edit),
    /// `IMG_1234_edited.JPG` and `IMG_1234_edited.MOV` (the edited picture and video).
    static func name(for type: Int, primary: String, resourceFilename: String, uniformType: String? = nil) -> String {
        guard type != photo else { return primary }
        let whole = primary as NSString
        let stem = whole.pathExtension.isEmpty ? primary : whole.deletingPathExtension
        let capitals = !whole.pathExtension.isEmpty && whole.pathExtension == whole.pathExtension.uppercased()
        func ending(_ fallback: String) -> String {
            var found = (resourceFilename as NSString).pathExtension
            if found.isEmpty { found = uniformType.flatMap { UTType($0)?.preferredFilenameExtension } ?? fallback }
            return capitals ? found.uppercased() : found
        }
        switch type {
        case pairedVideo: return "\(stem).\(ending("mov"))"
        case adjustmentData: return "\(stem).\(capitals ? "AAE" : "aae")"
        case fullSizePhoto: return "\(stem)_edited.\(ending("jpg"))"
        case fullSizePairedVideo: return "\(stem)_edited.\(ending("mov"))"
        default: return "\(stem)_\(type).\(ending("bin"))"
        }
    }

    /// True when the scan saw this item as a set of files that can be archived together.
    static func supports(_ record: AssetRecord) -> Bool {
        record.issue == nil && parts(mediaType: record.mediaType, types: record.resources.map(\.type)) != nil
    }

    /// The scan's fingerprint of the file that is copied first: the only one for a single-file item,
    /// the original still for a Live Photo or an edited photo.
    static func primaryFingerprint(of record: AssetRecord) -> ResourceFingerprint? {
        record.resources.count > 1 ? record.resources.first { $0.type == photo } : record.resources.first
    }

    /// The scan's fingerprints of every file, when the item is copied as several. Nil for a single file.
    static func partFingerprints(of record: AssetRecord) -> [ResourceFingerprint]? {
        supports(record) ? record.resources : nil
    }
}

extension ArchivedRecord {
    /// The other files of this item; empty for a single-file copy and for every record saved before
    /// Live Photos and edited photos could be archived.
    var otherParts: [ArchivedPart] { parts ?? [] }
    var hasParts: Bool { !otherParts.isEmpty }
    /// The size of every file of the item together.
    var totalBytes: Int64 { otherParts.reduce(bytes) { $0 + $1.bytes } }
    /// Photos' resource type of each stored file, original first. A single-file record has none recorded.
    var partTypes: [Int] { hasParts ? [ArchivePlan.photo] + otherParts.map(\.type) : [] }

    /// Each stored file as a single-file record, the original first, so every file goes through the
    /// same checks a single-file copy does. A single-file record is just itself.
    var files: [ArchivedRecord] {
        guard hasParts else { return [self] }
        var first = self
        first.parts = nil
        return [first] + otherParts.map { part in
            ArchivedRecord(id: id, name: part.name, folderName: folderName, bytes: part.bytes, digest: part.digest,
                           date: date, viaHomeServer: viaHomeServer, folderBookmark: folderBookmark,
                           driveFileID: part.fileID, photoID: photoID, cloud: cloud, cloudHash: part.cloudHash)
        }
    }

    /// "3 files" for an item kept as several, nil for a single file.
    var filesNote: String? { hasParts ? "\(files.count) files" : nil }
}

/// What was stored for one file of an item, whichever destination it went to.
struct StoredPart: Sendable {
    let name: String
    let fingerprint: ArchiveFingerprint
    var fileID: String? = nil
    var cloudHash: String? = nil
}

enum ArchiveParts {
    /// The files to copy for a Photos item kept as several, original first, each as its own item so it
    /// is streamed, fingerprinted and checked exactly like a single file. Nil for a single-file item,
    /// which is copied the way it always was.
    static func files(of item: ArchiveItem) throws -> [ArchiveItem]? {
        guard item.part == nil, case let .photo(id, expected) = item.source,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject,
              let resources = VerifiedArchive.plan(for: asset) else { return nil }
        var files: [ArchiveItem] = []
        for resource in resources {
            let type = resource.type.rawValue
            let name = ArchivePlan.name(for: type, primary: item.name, resourceFilename: resource.originalFilename,
                                        uniformType: resource.uniformTypeIdentifier)
            // What the scan read for this file. Without a scan, the original still keeps the fingerprint
            // measured for it and the other files are fingerprinted as they stream.
            let known = item.expectedParts?.first { $0.type == type } ?? (type == ArchivePlan.photo && item.expectedParts == nil ? expected : nil)
            files.append(ArchiveItem(id: item.id, name: name, source: .photo(id, expected: known),
                                     size: known?.bytes ?? DuplicateScanner.reportedSize(of: [resource]), part: type))
        }
        // Every file needs its own name, or one would be refused as already there.
        guard Set(files.map { $0.name.lowercased() }).count == files.count else { throw ArchiveError.unsupportedPhoto }
        return files
    }

    /// The saved record's extra parts, from what was stored for every file after the first.
    /// Only ever called with all of an item's files stored and checked.
    static func parts(_ files: [ArchiveItem], _ stored: [StoredPart]) -> [ArchivedPart] {
        zip(files, stored).dropFirst().compactMap { file, copy -> ArchivedPart? in
            guard let type = file.part else { return nil }
            return ArchivedPart(type: type, name: copy.name, bytes: copy.fingerprint.bytes, digest: copy.fingerprint.digest,
                                fileID: copy.fileID, cloudHash: copy.cloudHash)
        }
    }

    /// An item counts as copied only when every one of its files was stored and checked. `copy` throws
    /// for a file that wasn't, which stops the item there: nothing is recorded for it and its original stays.
    static func every<Stored>(_ files: [ArchiveItem], copy: (ArchiveItem) throws -> Stored) throws -> [Stored] {
        var stored: [Stored] = []
        for file in files { stored.append(try copy(file)) }
        guard !stored.isEmpty, stored.count == files.count else { throw ArchiveError.verification }
        return stored
    }

    static func everyAsync<Stored>(_ files: [ArchiveItem], copy: (ArchiveItem) async throws -> Stored) async throws -> [Stored] {
        var stored: [Stored] = []
        for file in files { stored.append(try await copy(file)) }
        guard !stored.isEmpty, stored.count == files.count else { throw ArchiveError.verification }
        return stored
    }

    /// The progress screen counts downloads by item; a second file of the same item gets its own entry.
    static func liveKey(_ id: String, part: Int?) -> String {
        guard let part, part != ArchivePlan.photo else { return id }
        return "\(id)#\(part)"
    }

    /// The second way of asking Photos for a photo only ever returns the original still.
    static func allowsImageFallback(part: Int?) -> Bool { part == nil || part == ArchivePlan.photo }
}
