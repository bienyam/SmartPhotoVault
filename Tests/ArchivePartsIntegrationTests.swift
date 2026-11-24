// Synthetic fixtures are created only in the iOS simulator, never on an iPhone.
#if targetEnvironment(simulator)
import AVFoundation
import CoreMedia
import CoreVideo
import ImageIO
import Photos
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import SmartPhotoVault

/// Archives a real edited photo and a real Live Photo from the simulator's library to a folder, file by
/// file, and puts each back into Photos as one item. The fixtures are synthetic: when the simulator's
/// Photos won't build one, that test is skipped and says why, because nothing was proven either way.
/// A real camera Live Photo and a real Photos edit still need the device checklist.
final class ArchivePartsIntegrationTests: XCTestCase {
    private let photo = PHAssetResourceType.photo.rawValue
    private let paired = PHAssetResourceType.pairedVideo.rawValue
    private let adjustment = PHAssetResourceType.adjustmentData.rawValue
    private let fullPhoto = PHAssetResourceType.fullSizePhoto.rawValue

    @MainActor
    func testEditedPhotoIsArchivedWithEveryPartAndComesBackEdited() async throws {
        try await authorize()
        let adjustments = try PropertyListSerialization.data(fromPropertyList: [
            "adjustmentBaseVersion": 0,
            "adjustmentData": Data("TidyAway test edit".utf8),
            "adjustmentEditorBundleID": "com.bienyam.SmartPhotoVault",
            "adjustmentFormatIdentifier": "com.bienyam.SmartPhotoVault.test",
            "adjustmentFormatVersion": "1.0",
            "adjustmentRenderTypes": 0,
            "adjustmentTimestamp": Date(timeIntervalSince1970: 1_790_000_000),
        ] as [String: Any], format: .binary, options: 0)
        let original = try jpeg(.red), rendered = try jpeg(.green)
        let id = try await fixture("edited", [(.photo, original, "jpg"), (.adjustmentData, adjustments, "plist"),
                                              (.fullSizePhoto, rendered, "jpg")])
        try await roundTrip(id, label: "edited", types: [photo, adjustment, fullPhoto])
    }

    @MainActor
    func testLivePhotoIsArchivedWithItsVideoAndComesBackLive() async throws {
        try await authorize()
        let pairing = UUID().uuidString
        let still = try jpeg(.blue, pairing: pairing)
        let motion: Data
        do {
            motion = try await movie(pairing: pairing)
        } catch {
            print("PARTS|live|video fixture failed: \(error)")
            throw XCTSkip("Could not write the Live Photo's video fixture: \(error.localizedDescription)")
        }
        let id = try await fixture("live", [(.photo, still, "jpg"), (.pairedVideo, motion, "mov")])
        let asset = try XCTUnwrap(PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject)
        print("PARTS|live|fixture subtype live=\(asset.mediaSubtypes.contains(.photoLive))")
        let newID = try await roundTrip(id, label: "live", types: [photo, paired])
        let back = try XCTUnwrap(PHAsset.fetchAssets(withLocalIdentifiers: [newID], options: nil).firstObject)
        XCTAssertEqual(back.mediaSubtypes.contains(.photoLive), asset.mediaSubtypes.contains(.photoLive),
                       "It comes back as live as it went in.")
    }

    /// Archives the item to a folder, checks every file, tests a restore, then puts it back into Photos
    /// and compares the new item's files with the original's.
    @MainActor
    @discardableResult
    private func roundTrip(_ id: String, label: String, types: [Int]) async throws -> String {
        let asset = try XCTUnwrap(PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject)
        let found = PHAssetResource.assetResources(for: asset).map { "\($0.type.rawValue):\($0.originalFilename)" }
        print("PARTS|\(label)|fixture resources \(found)")
        guard let plan = VerifiedArchive.plan(for: asset), plan.map({ $0.type.rawValue }) == types else {
            throw XCTSkip("The simulator's Photos kept different files for the \(label) fixture: \(found)")
        }
        XCTAssertNil(VerifiedArchive.original(for: asset), "The single-file path still refuses it.")
        XCTAssertEqual(VerifiedArchive.primary(for: asset)?.type, .photo)

        // Scan it, then copy it the way a Files archive does.
        let scanned = try await DuplicateScanner().archiveFingerprints(for: id)
        XCTAssertEqual(scanned.map(\.type), types)
        let name = plan[0].originalFilename
        let item = ArchiveItem(id: id, name: name, source: .photo(id, expected: scanned.first), expectedParts: scanned)
        let files = FileManager.default
        let archive = files.temporaryDirectory.appendingPathComponent("TidyAwayParts-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: archive, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: archive) }
        let stored = try await Task.detached { try VerifiedArchive.copyEvery(item, to: archive) }.value
        let record = ArchivedRecord(id: UUID().uuidString, name: stored.receipt.url.lastPathComponent, folderName: "archive",
                                    bytes: stored.receipt.fingerprint.bytes, digest: stored.receipt.fingerprint.digest, date: Date(),
                                    viaHomeServer: false, folderBookmark: try archive.bookmarkData(), photoID: id,
                                    parts: stored.parts.isEmpty ? nil : stored.parts)
        XCTAssertEqual(record.partTypes, types)
        print("PARTS|\(label)|stored \(record.files.map(\.name))")
        XCTAssertEqual(Set(try files.contentsOfDirectory(atPath: archive.path)), Set(record.files.map(\.name)),
                       "Every file is there, side by side, and nothing else.")
        for (file, original) in zip(record.files, scanned) {
            XCTAssertEqual(file.bytes, original.bytes)
            XCTAssertEqual(file.digest, original.digest)
            XCTAssertEqual(try GoogleDriveClient.sha256(of: archive.appendingPathComponent(file.name)), original.digest,
                           "\(file.name) on the destination is the original, byte for byte.")
        }

        // Copying again never overwrites: the files already there count only because they match.
        let again = try await Task.detached { try VerifiedArchive.copyEvery(item, to: archive) }.value
        XCTAssertEqual(again.parts, stored.parts)
        XCTAssertEqual(try files.contentsOfDirectory(atPath: archive.path).count, types.count)

        // The test restore brings back every file; one changed file fails the whole item.
        let wifi = ArchiveWiFi()
        let copies = try await ArchiveRestore.verifiedCopies(record, wifi: wifi)
        XCTAssertEqual(copies.count, types.count)
        for copy in copies { try? files.removeItem(at: copy) }
        let last = archive.appendingPathComponent(try XCTUnwrap(record.files.last).name)
        let kept = try Data(contentsOf: last)
        var changed = kept
        changed[changed.count / 2] ^= 0xff
        try changed.write(to: last)
        do {
            _ = try await ArchiveRestore.verifiedCopies(record, wifi: wifi)
            XCTFail("A changed part must fail the restore of the whole item.")
        } catch { }
        try kept.write(to: last)

        // Back into Photos as one item.
        print("PARTS|\(label)|Photos says it can rebuild \(types): \(ArchiveRestore.photosCanRebuild(types))")
        let newID = try await ArchiveRestore.everyPartToPhotos(record, wifi: wifi)
        XCTAssertNotEqual(newID, id)
        let back = try await DuplicateScanner().archiveFingerprints(for: newID)
        XCTAssertEqual(back.map(\.type), types, "The item that came back has every kind of file.")
        XCTAssertEqual(back.first?.digest, scanned.first?.digest, "The original still came back byte for byte.")
        for (returned, original) in zip(back, scanned) {
            print("PARTS|\(label)|type \(original.type) came back byte for byte: \(returned.digest == original.digest && returned.bytes == original.bytes)")
            if original.type == adjustment {
                // Photos keeps an edit's instructions in its own library and writes the file out again,
                // so the bytes can differ. What must come back unchanged is the edit inside it.
                let before = try await edit(in: id), after = try await edit(in: newID)
                print("PARTS|\(label)|edit file keys \(before.keys.sorted()), whole file content equal: \(NSDictionary(dictionary: before).isEqual(to: after))")
                XCTAssertEqual(after["adjustmentData"] as? Data, before["adjustmentData"] as? Data, "The edit itself came back unchanged.")
                XCTAssertNotNil(after["adjustmentData"] as? Data)
                XCTAssertEqual(after["adjustmentFormatIdentifier"] as? String, before["adjustmentFormatIdentifier"] as? String)
                XCTAssertEqual(after["adjustmentFormatVersion"] as? String, before["adjustmentFormatVersion"] as? String)
            } else {
                XCTAssertEqual(returned, original, "The pictures and videos that came back are the originals, byte for byte.")
            }
        }
        return newID
    }

    /// The edit instructions Photos holds for an item, read from its adjustment file.
    @MainActor
    private func edit(in id: String) async throws -> [String: Any] {
        let asset = try XCTUnwrap(PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject)
        let resource = try XCTUnwrap(PHAssetResource.assetResources(for: asset).first { $0.type == .adjustmentData })
        let box = FixtureDataBox()
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            PHAssetResourceManager.default().requestData(for: resource, options: nil) { piece in
                box.append(piece)
            } completionHandler: { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: box.data) }
            }
        }
        let list = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try XCTUnwrap(list as? [String: Any])
    }

    @MainActor
    private func authorize() async throws {
        let access = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard access == .authorized else { throw XCTSkip("Simulator Photos access wasn't granted; see README.") }
    }

    /// Adds one item made of these files to the simulator's library. Skips the test when Photos refuses.
    @MainActor
    private func fixture(_ label: String, _ parts: [(PHAssetResourceType, Data, String)]) async throws -> String {
        let types = parts.map { NSNumber(value: $0.0.rawValue) }
        print("PARTS|\(label)|Photos says it supports creating \(types): \(PHAssetCreationRequest.supportsAssetResourceTypes(types))")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TidyAwayFixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let stem = "TA-\(label)-\(UUID().uuidString.prefix(8))"
        var urls: [URL] = []
        for (index, part) in parts.enumerated() {
            let url = folder.appendingPathComponent(index == 0 || part.0 == .pairedVideo ? "\(stem).\(part.2)" : "\(stem)-\(index).\(part.2)")
            try part.1.write(to: url)
            urls.append(url)
        }
        let created = ArchiveCreatedBox()
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                for (index, part) in parts.enumerated() {
                    request.addResource(with: part.0, fileURL: urls[index], options: nil)
                }
                created.id = request.placeholderForCreatedAsset?.localIdentifier
            }
        } catch {
            print("PARTS|\(label)|fixture refused: \(error)")
            throw XCTSkip("The simulator's Photos would not build the \(label) fixture: \(error.localizedDescription)")
        }
        return try XCTUnwrap(created.id)
    }

    /// A small JPEG. With `pairing`, it carries the identifier that ties a Live Photo's still to its video.
    @MainActor
    private func jpeg(_ color: UIColor, pairing: String? = nil) throws -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        let data = NSMutableData()
        guard let picture = image.cgImage,
              let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw fixtureError("Could not start a JPEG.")
        }
        var properties: [String: Any] = [:]
        if let pairing { properties[kCGImagePropertyMakerAppleDictionary as String] = ["17": pairing] }
        CGImageDestinationAddImage(destination, picture, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw fixtureError("Could not finish a JPEG.") }
        return data as Data
    }

    /// A one-second movie carrying the same identifier as the still, and the marker for the still's moment.
    private func movie(pairing: String) async throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let identifier = AVMutableMetadataItem()
        identifier.keySpace = .quickTimeMetadata
        identifier.key = "com.apple.quicktime.content.identifier" as NSString
        identifier.value = pairing as NSString
        identifier.dataType = "com.apple.metadata.datatype.UTF-8"
        writer.metadata = [identifier]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64,
            AVVideoHeightKey: 64
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 64,
            kCVPixelBufferHeightKey as String: 64
        ])
        writer.add(input)

        let specification: [String: Any] = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: "mdta/com.apple.quicktime.still-image-time",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: "com.apple.metadata.datatype.int8"
        ]
        var description: CMFormatDescription?
        let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(allocator: kCFAllocatorDefault,
                                                                                 metadataType: kCMMetadataFormatType_Boxed,
                                                                                 metadataSpecifications: [specification] as CFArray,
                                                                                 formatDescriptionOut: &description)
        guard status == noErr, let description else { throw fixtureError("Could not describe the still's moment.") }
        let momentInput = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: description)
        guard writer.canAdd(momentInput) else { throw fixtureError("The writer won't take the still's moment.") }
        let moments = AVAssetWriterInputMetadataAdaptor(assetWriterInput: momentInput)
        writer.add(momentInput)

        guard writer.startWriting() else { throw writer.error ?? fixtureError("Could not start video writer.") }
        writer.startSession(atSourceTime: .zero)
        let moment = AVMutableMetadataItem()
        moment.keySpace = .quickTimeMetadata
        moment.key = "com.apple.quicktime.still-image-time" as NSString
        moment.value = 0 as NSNumber
        moment.dataType = "com.apple.metadata.datatype.int8"
        let ready = Date().addingTimeInterval(5)
        while !momentInput.isReadyForMoreMediaData {
            guard Date() < ready, writer.status == .writing else {
                writer.cancelWriting()
                throw fixtureError("The writer never took the still's moment.")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard moments.append(AVTimedMetadataGroup(items: [moment], timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 3)))) else {
            throw writer.error ?? fixtureError("Could not mark the still's moment.")
        }
        momentInput.markAsFinished()

        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32ARGB, nil, &buffer) == kCVReturnSuccess,
              let buffer else { throw fixtureError("Could not allocate a synthetic video frame.") }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let address = CVPixelBufferGetBaseAddress(buffer) {
            memset(address, 0, CVPixelBufferGetBytesPerRow(buffer) * 64)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        for frame in 0..<3 {
            let deadline = Date().addingTimeInterval(10)
            while !input.isReadyForMoreMediaData {
                guard Date() < deadline, writer.status == .writing else {
                    writer.cancelWriting()
                    throw fixtureError("Video fixture writer stopped accepting frames.")
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 3)) else {
                throw writer.error ?? fixtureError("Could not append a synthetic video frame.")
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? fixtureError("Video fixture did not finish.") }
        return try Data(contentsOf: url)
    }

    private func fixtureError(_ message: String) -> NSError {
        NSError(domain: "SimulatorFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private final class FixtureDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Data()
    func append(_ piece: Data) { lock.lock(); value.append(piece); lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return value }
}
#endif
