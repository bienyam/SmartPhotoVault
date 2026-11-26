import Foundation
import Photos
import SwiftUI
import Vision

/// What TidyAway recognized in one photo or video, on this iPhone. Labels and numbers only, never a picture.
struct PhotoInsight: Codable, Equatable, Sendable {
    /// Raised when recognition changes, so old results are read again.
    static let current = 2

    let id: String
    var version = PhotoInsight.current
    /// Confident labels that TidyAway groups by. Nothing else is kept.
    var labels: [String] = []
    /// Higher is sharper. Only compared within one series.
    var sharpness: Double = 0
    /// True when a face fills a good part of the picture.
    var closeFace = false
    /// The photo just before this one, when they look nearly the same.
    var sameAs: String?
    /// Average light, 0 (black) to 255. Nil for results read before it was measured.
    var brightness: Double?
    /// True when a face of any size was found. Nil for results read before this was checked.
    var anyFace: Bool?

    /// Whether there is a face in the photo. A close face always counts; otherwise nil until checked.
    var hasFace: Bool? { closeFace ? true : anyFace }
}

/// Facts Photos gives for free, read again each time groups are made.
struct AssetFacts: Equatable, Sendable {
    var duration: Double = 0
    var edited = false

    static func all(for records: [AssetRecord]) -> [String: AssetFacts] {
        let access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard access == .authorized || access == .limited else { return [:] }
        var facts: [String: AssetFacts] = [:]
        PHAsset.fetchAssets(with: nil).enumerateObjects { asset, _, _ in
            if asset.mediaType == .video || asset.hasAdjustments {
                facts[asset.localIdentifier] = AssetFacts(duration: asset.duration, edited: asset.hasAdjustments)
            }
        }
        return facts
    }
}

/// Saves results as they come in, one line each, so an interruption loses almost nothing.
actor InsightStore {
    private let url: URL

    init(url: URL) { self.url = url }

    static func standard() -> InsightStore? {
        guard let folder = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("SmartPhotoVault", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return InsightStore(url: folder.appendingPathComponent("insights.jsonl"))
    }

    func load() -> [String: PhotoInsight] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        var found: [String: PhotoInsight] = [:]
        for line in data.split(separator: UInt8(ascii: "\n")) {
            if let insight = try? decoder.decode(PhotoInsight.self, from: Data(line)), insight.version == PhotoInsight.current {
                found[insight.id] = insight
            }
        }
        return found
    }

    func append(_ insights: [PhotoInsight]) {
        let encoder = JSONEncoder()
        var data = Data()
        for insight in insights {
            guard let line = try? encoder.encode(insight) else { continue }
            data.append(line)
            data.append(UInt8(ascii: "\n"))
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Keeps only photos that are still in the library.
    func keep(only ids: Set<String>) {
        let all = load()
        let kept = all.values.filter { ids.contains($0.id) }
        guard kept.count < all.count else { return }
        let encoder = JSONEncoder()
        var data = Data()
        for insight in kept.sorted(by: { $0.id < $1.id }) {
            guard let line = try? encoder.encode(insight) else { continue }
            data.append(line)
            data.append(UInt8(ascii: "\n"))
        }
        try? data.write(to: url, options: .atomic)
    }
}

/// Reads small pictures already on the iPhone, in the order they were taken. Never downloads anything.
actor InsightReader {
    struct Item: Sendable {
        let id: String
        let date: Date
        let image: Bool
    }

    /// Photos this far apart or more are never called the same shot.
    static let seriesGap: TimeInterval = 20
    /// How alike two pictures must be, on Apple's own scale (0 is identical). Cautious until tried on real libraries.
    static let sameShot: Float = 0.30

    private var previous: (item: Item, print: VNFeaturePrintObservation)?

    func read(_ items: [Item]) -> [PhotoInsight] {
        items.map { item in autoreleasepool { read(item) } }
    }

    private func read(_ item: Item) -> PhotoInsight {
        var insight = PhotoInsight(id: item.id)
        guard let picture = Self.picture(item.id) else {
            previous = nil
            return insight
        }
        let classify = VNClassifyImageRequest()
        let faces = VNDetectFaceRectanglesRequest()
        let print = VNGenerateImageFeaturePrintRequest()
        let requests: [VNRequest] = item.image ? [classify, faces, print] : [classify]
        try? VNImageRequestHandler(cgImage: picture).perform(requests)
        insight.labels = (classify.results ?? [])
            .filter { Recognition.known.contains($0.identifier) && $0.hasMinimumRecall(0.01, forPrecision: 0.9) }
            .map(\.identifier)
            .sorted()
        guard item.image else { return insight }
        insight.closeFace = (faces.results ?? []).contains { $0.boundingBox.width * $0.boundingBox.height > 0.08 }
        insight.anyFace = !(faces.results ?? []).isEmpty
        insight.sharpness = Self.sharpness(of: picture)
        insight.brightness = Self.brightness(of: picture)
        guard let mark = print.results?.first else {
            previous = nil
            return insight
        }
        if let before = previous, item.date.timeIntervalSince(before.item.date) < Self.seriesGap {
            var distance: Float = .greatestFiniteMagnitude
            if (try? mark.computeDistance(&distance, to: before.print)) != nil, distance <= Self.sameShot {
                insight.sameAs = before.item.id
            }
        }
        previous = (item, mark)
        return insight
    }

    /// Face check only, on the same small picture, for photos read before faces of any size were
    /// noted. Nil when the picture can't be read right now, so it is tried again later.
    func faces(in ids: [String]) -> [String: Bool] {
        var found: [String: Bool] = [:]
        for id in ids {
            autoreleasepool {
                guard let picture = Self.picture(id) else { return }
                let request = VNDetectFaceRectanglesRequest()
                guard (try? VNImageRequestHandler(cgImage: picture).perform([request])) != nil else { return }
                found[id] = !(request.results ?? []).isEmpty
            }
        }
        return found
    }

    private static func picture(_ id: String) -> CGImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        var image: UIImage?
        PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 360, height: 360),
                                              contentMode: .aspectFit, options: options) { picture, _ in image = picture }
        return image?.cgImage
    }

    /// Average light over the whole picture, 0 to 255.
    static func brightness(of image: CGImage) -> Double {
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 0 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return Double(pixels.reduce(0) { $0 + Int($1) }) / Double(pixels.count)
    }

    /// How much fine detail there is: the spread of the differences between neighboring points.
    static func sharpness(of image: CGImage) -> Double {
        let side = 128
        var pixels = [UInt8](repeating: 0, count: side * side)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 0 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        var sum = 0.0, squares = 0.0, count = 0.0
        for y in 1..<(side - 1) {
            for x in 1..<(side - 1) {
                let at = y * side + x
                let value = Double(4 * Int(pixels[at]) - Int(pixels[at - 1]) - Int(pixels[at + 1]) - Int(pixels[at - side]) - Int(pixels[at + side]))
                sum += value
                squares += value * value
                count += 1
            }
        }
        let mean = sum / count
        return squares / count - mean * mean
    }
}

/// Runs recognition while TidyAway is open, a little at a time. It rests when the iPhone is hot or saving power.
@MainActor
final class InsightModel: ObservableObject {
    static let shared = InsightModel()

    @Published private(set) var insights: [String: PhotoInsight] = [:]
    @Published private(set) var done = 0
    @Published private(set) var total = 0
    @Published private(set) var running = false
    @Published private(set) var resting = false
    /// Changes when enough new results are in to make the groups again.
    @Published private(set) var revision = 0

    /// Results as they come in. They reach `insights` in batches, so screens redraw a few times
    /// during a long read instead of once per photo.
    private var gathered: [String: PhotoInsight] = [:]
    private var task: Task<Void, Never>?
    private let reader = InsightReader()
    private let store = InsightStore.standard()
    private var loaded = false

    /// For UI tests: made-up results, nothing is read.
    func show(_ sample: [String: PhotoInsight]) {
        guard insights != sample else { return }
        insights = sample
        done = sample.count
        total = sample.count
        revision += 1
    }

    func start(_ assets: [AssetRecord]) {
        let access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard !running, access == .authorized || access == .limited else { return }
        let items = assets
            .filter { !$0.id.hasPrefix("sample-") && $0.createdAt != nil && $0.isScreenshot != true }
            .sorted { $0.createdAt! == $1.createdAt! ? $0.id < $1.id : $0.createdAt! < $1.createdAt! }
            .map { InsightReader.Item(id: $0.id, date: $0.createdAt!, image: $0.mediaType == PHAssetMediaType.image.rawValue) }
        guard !items.isEmpty else { return }
        running = true
        task = Task { await run(items) }
    }

    func stop() { task?.cancel() }

    private func run(_ items: [InsightReader.Item]) async {
        defer {
            running = false
            resting = false
        }
        if !loaded, let store {
            await store.keep(only: Set(items.map(\.id)))
            gathered = await store.load()
            insights = gathered
            loaded = true
            if !insights.isEmpty { revision += 1 }
        } else {
            gathered = insights
        }
        total = items.count
        var finished = items.reduce(0) { $0 + (gathered[$1.id] == nil ? 0 : 1) }
        done = finished
        let waiting = items.filter { gathered[$0.id] == nil }
        var sinceRevision = 0
        var sinceProgress = 0
        // New results waiting to be shown. They are added to what is on screen, never swapped in
        // whole, so results shown meanwhile (sample data in tests) are not lost.
        var fresh: [String: PhotoInsight] = [:]
        var index = 0
        while index < waiting.count, !Task.isCancelled {
            let state = ProcessInfo.processInfo
            if state.isLowPowerModeEnabled || state.thermalState == .serious || state.thermalState == .critical {
                resting = true
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                continue
            }
            resting = false
            let batch = Array(waiting[index..<min(index + 24, waiting.count)])
            index += batch.count
            let found = await reader.read(batch)
            for insight in found {
                gathered[insight.id] = insight
                fresh[insight.id] = insight
            }
            await store?.append(found)
            finished += found.count
            sinceRevision += found.count
            sinceProgress += found.count
            // The count moves about every hundred photos; the results themselves every six hundred.
            if sinceProgress >= 96 {
                sinceProgress = 0
                done = finished
            }
            if sinceRevision >= 600 {
                sinceRevision = 0
                insights.merge(fresh) { _, new in new }
                fresh = [:]
                done = finished
                revision += 1
            }
        }
        done = finished
        if sinceRevision > 0 {
            insights.merge(fresh) { _, new in new }
            revision += 1
        }
        await checkFaces(items)
    }

    /// Receipts & documents leaves out any photo with a face. Results read before faces of any size
    /// were noted get that one check here, only for photos with a paper label, so nothing else is
    /// read again. Until a photo is checked it stays out of the group.
    private func checkFaces(_ items: [InsightReader.Item]) async {
        let waiting = items.filter { item in
            guard item.image, let insight = gathered[item.id], insight.hasFace == nil else { return false }
            return !CleanupGrouper.paperLabels.isDisjoint(with: insight.labels)
        }
        guard !waiting.isEmpty else { return }
        var changed: [PhotoInsight] = []
        var index = 0
        while index < waiting.count, !Task.isCancelled {
            let batch = waiting[index..<min(index + 24, waiting.count)].map(\.id)
            index += batch.count
            let found = await reader.faces(in: batch)
            for (id, face) in found {
                guard var insight = gathered[id] else { continue }
                insight.anyFace = face
                gathered[id] = insight
                changed.append(insight)
            }
        }
        guard !changed.isEmpty else { return }
        // A later line for the same photo replaces the earlier one when results are loaded.
        await store?.append(changed)
        insights.merge(Dictionary(changed.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })) { _, new in new }
        revision += 1
    }
}
