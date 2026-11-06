// Synthetic fixtures are created only in the iOS simulator, never on an iPhone.
#if targetEnvironment(simulator)
import XCTest
import Photos
import UIKit
import AVFoundation
import CoreVideo
import CryptoKit
@testable import SmartPhotoVault

final class PhotosIntegrationTests: XCTestCase {
    @MainActor
    func testRealPhotosAndVideosAreHashedGroupedAndPersisted() async throws {
        print("Photos integration host: \(Bundle.main.bundleIdentifier ?? "unknown")")
        let access = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        XCTAssertEqual(access, .authorized,
                       "Grant simulator Photos access before integration tests; see README.")
        guard access == .authorized else { return }
        let red = png(.red)
        let blue = png(.blue)
        let video = try await movie()
        var identifiers: [String] = []
        let prefix = "SPV-test-\(UUID().uuidString)"
        try await PHPhotoLibrary.shared().performChanges {
            for (index, bytes) in [red, red, blue, video, video].enumerated() {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = "\(prefix)-\(index).\(index < 3 ? "png" : "mov")"
                options.uniformTypeIdentifier = index < 3 ? "public.png" : "com.apple.quicktime-movie"
                request.addResource(with: index < 3 ? .photo : .video, data: bytes, options: options)
                request.isFavorite = index == 0
                if let identifier = request.placeholderForCreatedAsset?.localIdentifier {
                    identifiers.append(identifier)
                }
            }
        }
        XCTAssertEqual(identifiers.count, 5)
        let progress = ScanProgressRecorder()
        let records = try await DuplicateScanner().scan(allowNetwork: false) { done, total in
            await progress.record(done: done, total: total)
        }
        let fixtures = records.filter { identifiers.contains($0.id) }
        XCTAssertEqual(fixtures.count, 5)
        for asset in fixtures {
            XCTAssertNil(asset.issue, "\(asset.filename): \(asset.issue ?? "")")
            XCTAssertNotNil(asset.fingerprint)
            XCTAssertEqual(asset.resources.count, 1)
        }
        let byID = Dictionary(uniqueKeysWithValues: fixtures.map { ($0.id, $0) })
        for (index, original) in [red, red, blue, video, video].enumerated() {
            guard identifiers.indices.contains(index) else { continue }
            let asset = try XCTUnwrap(byID[identifiers[index]])
            let resource = try XCTUnwrap(asset.resources.first)
            XCTAssertEqual(resource.bytes, Int64(original.count))
            XCTAssertEqual(resource.digest, digest(original), "Hash must match the original bytes supplied to Photos.")
        }
        let result = ScanSnapshot(date: Date(), limitedAccess: false, includedCloudDownloads: false, assets: fixtures)
        XCTAssertEqual(result.groups.count, 2, "One identical photo pair and one identical video pair.")
        XCTAssertEqual(result.verifiedCount, 5)
        XCTAssertEqual(result.candidateBytes, Int64(red.count + video.count))
        let photoGroup = try XCTUnwrap(result.groups.first { $0.assets.contains { $0.id == identifiers.first } })
        XCTAssertEqual(photoGroup.assets.first?.id, identifiers.first, "Favorite is preserved first in review order.")
        let updates = await progress.updates
        XCTAssertEqual(updates.last?.0, records.count)
        XCTAssertEqual(updates.last?.1, records.count)
        XCTAssertEqual(updates.map(\.0), (0..<records.count).map { $0 + 1 })
        let counts = await PhotoLibraryService.inventory()
        XCTAssertGreaterThanOrEqual(counts.photos, 3)
        XCTAssertGreaterThanOrEqual(counts.videos, 2)
        XCTAssertGreaterThanOrEqual(counts.favorites, 1)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try InventoryStore(url: url)
        try store.save(result)
        let restored = try XCTUnwrap(store.load())
        XCTAssertEqual(restored.groups.map(\.id), result.groups.map(\.id))
        XCTAssertEqual(restored.candidateBytes, result.candidateBytes)
        XCTAssertEqual(try store.activity().count, 1)
    }

    func testPreCancelledScanThrowsInsteadOfReturningPartialResults() async throws {
        let scanner = DuplicateScanner()
        let gate = ScanStartGate()
        let task = Task {
            await gate.wait()
            return try await scanner.scan(allowNetwork: false) { _, _ in }
        }
        task.cancel()
        await gate.release()
        do {
            _ = try await task.value
            XCTFail("Cancelled work must not return a completed scan.")
        } catch is CancellationError { }
    }

    @MainActor
    private func png(_ color: UIColor) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).pngData { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func movie() async throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
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
        guard writer.startWriting() else { throw writer.error ?? fixtureError("Could not start video writer.") }
        writer.startSession(atSourceTime: .zero)
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

private actor ScanProgressRecorder {
    var updates: [(Int, Int)] = []
    func record(done: Int, total: Int) { updates.append((done, total)) }
}

private actor ScanStartGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
#endif
