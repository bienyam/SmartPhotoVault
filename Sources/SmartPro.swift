import Foundation
import Photos
import UIKit
import Vision

// MARK: - Safe because it's archived

/// Photos still on this iPhone whose copy was verified at one archive place.
struct ArchivedPlace: Identifiable, Equatable {
    let place: String
    let records: [ArchivedRecord]
    var id: String { place }
    var bytes: Int64 { records.reduce(0) { $0 + $1.bytes } }
}

/// Finds originals that already have a verified archive copy. Removing them always goes through the
/// usual removal after archiving: every copy proved again, one brought back, the sign-off, then Apple.
enum ArchivedOnPhone {
    /// Where a copy lives, in the words the removal sign-off uses.
    static func place(of record: ArchivedRecord) -> String {
        if let cloud = record.cloud { return cloud.name }
        if record.driveFileID != nil { return "Google Drive" }
        return record.folderName
    }

    /// One list per place, biggest first. Only photos still in the library (and not favorites) count;
    /// each photo is listed once per place, with its latest copy there.
    static func places(records: [ArchivedRecord], onPhone: Set<String>) -> [ArchivedPlace] {
        var latest: [String: ArchivedRecord] = [:]
        for record in records {
            guard let photo = record.photoID, onPhone.contains(photo) else { continue }
            let key = place(of: record) + "|" + photo
            if let seen = latest[key], seen.date >= record.date { continue }
            latest[key] = record
        }
        return Dictionary(grouping: latest.values, by: place(of:))
            .map { ArchivedPlace(place: $0.key, records: $0.value.sorted { ($0.date, $0.id) > ($1.date, $1.id) }) }
            .sorted { $0.bytes == $1.bytes ? $0.place < $1.place : $0.bytes > $1.bytes }
    }

    /// The same hand-over an archive run gives the removal screen.
    static func completion(for place: ArchivedPlace) -> ArchiveCompletion {
        var copies: [String: ArchivedRecord] = [:]
        let items = place.records.compactMap { record -> ArchiveItem? in
            guard let photo = record.photoID else { return nil }
            copies[record.id] = record
            return ArchiveItem(id: record.id, name: record.name, source: .photo(photo, expected: nil), size: record.bytes)
        }
        return ArchiveCompletion(items: items, bytes: place.bytes, place: place.place, driveFolderID: nil, copies: copies)
    }

    /// Reads the archive list and the library. Favorites are left out.
    static func load() -> [ArchivedPlace] {
        let access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard access == .authorized || access == .limited,
              let records = try? InventoryStore.openDefault().archived() else { return [] }
        let ids = Array(Set(records.compactMap(\.photoID)))
        guard !ids.isEmpty else { return [] }
        var onPhone = Set<String>()
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { asset, _, _ in
            if !asset.isFavorite { onPhone.insert(asset.localIdentifier) }
        }
        return places(records: records, onPhone: onPhone)
    }
}

// MARK: - Best shot, with the reason

/// What on-device Vision saw in one photo of a look-alike set.
struct ShotScore: Equatable, Sendable {
    let id: String
    var sharpness: Double
    var faces = 0
    /// Faces with both eyes open.
    var eyesOpen = 0
    /// Apple's face capture quality, 0 to 1, averaged over faces. Nil without faces.
    var faceQuality: Double?
}

enum BestShot {
    /// Above this, an eye is open: height over width of the eye outline.
    static let openEye = 0.18

    /// How open an eye is, from its outline points.
    static func openness(_ points: [CGPoint]) -> Double {
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max(), maxX > minX else { return 0 }
        return Double((maxY - minY) / (maxX - minX))
    }

    /// The photo to keep and why. With faces: everyone's eyes open first, then the clearest faces,
    /// then the sharpest. Without faces: the sharpest.
    static func pick(_ scores: [ShotScore]) -> (id: String, reason: String)? {
        guard !scores.isEmpty else { return nil }
        let hasFaces = scores.contains { $0.faces > 0 }
        func allOpen(_ score: ShotScore) -> Bool { score.faces > 0 && score.eyesOpen == score.faces }
        let best = scores.max { a, b in
            if hasFaces {
                if allOpen(a) != allOpen(b) { return allOpen(b) }
                if a.eyesOpen != b.eyesOpen { return a.eyesOpen < b.eyesOpen }
                let qa = a.faceQuality ?? 0, qb = b.faceQuality ?? 0
                if abs(qa - qb) > 0.05 { return qa < qb }
            }
            return a.sharpness == b.sharpness ? a.id > b.id : a.sharpness < b.sharpness
        }!
        var parts: [String] = []
        if best.sharpness >= (scores.map(\.sharpness).max() ?? 0) { parts.append("sharpest") }
        if allOpen(best) { parts.append(best.faces == 1 ? "eyes open" : "everyone's eyes open") }
        if let quality = best.faceQuality, quality >= (scores.compactMap(\.faceQuality).max() ?? 0) {
            parts.append(best.faces == 1 ? "clearest face" : "clearest faces")
        }
        let reason = parts.isEmpty ? "best overall" : parts.joined(separator: ", ")
        return (best.id, reason)
    }
}

/// Looks at faces in small copies of photos, on this iPhone. Nothing is kept but the scores.
enum BestShotReader {
    static func score(_ id: String, sharpness: Double) -> ShotScore {
        var score = ShotScore(id: id, sharpness: sharpness)
        guard let image = picture(id, side: 640) else { return score }
        let quality = VNDetectFaceCaptureQualityRequest()
        let landmarks = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([quality, landmarks])) != nil else { return score }
        let faces = landmarks.results ?? []
        score.faces = faces.count
        score.eyesOpen = faces.filter { face in
            guard let left = face.landmarks?.leftEye?.normalizedPoints, let right = face.landmarks?.rightEye?.normalizedPoints else { return false }
            return BestShot.openness(left) > BestShot.openEye && BestShot.openness(right) > BestShot.openEye
        }.count
        let qualities = (quality.results ?? []).compactMap(\.faceCaptureQuality).map(Double.init)
        if !qualities.isEmpty { score.faceQuality = qualities.reduce(0, +) / Double(qualities.count) }
        return score
    }

    static func picture(_ id: String, side: CGFloat) -> CGImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        var image: UIImage?
        PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: side, height: side),
                                              contentMode: .aspectFit, options: options) { picture, _ in image = picture }
        return image?.cgImage
    }
}

// MARK: - Screenshots, read on this iPhone

enum ScreenshotKind: String, Codable, CaseIterable, Identifiable {
    case loginCode, expiredPass, receipt, chat, map, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .loginCode: "Login codes"
        case .expiredPass: "Expired tickets"
        case .receipt: "Receipts"
        case .chat: "Chats"
        case .map: "Maps"
        case .other: "Other"
        }
    }
    var info: String {
        switch self {
        case .loginCode: "Screenshots of one-time sign-in and verification codes. They stop working within minutes."
        case .expiredPass: "Tickets, boarding passes and passes whose dates have passed."
        case .receipt: "Receipts and order confirmations. Keep any you need for returns or taxes."
        case .chat: "Screenshots of conversations."
        case .map: "Directions and maps."
        case .other: "Screenshots that didn't fit another group."
        }
    }
}

/// Sorts a screenshot by the words in it. The words are used once and never kept.
enum ScreenshotClassifier {
    static let codeWords = ["verification code", "security code", "login code", "sign-in code", "sign in code", "your code",
                            "passcode", "one-time", "one time", "otp", "code is", "use code", "code:", "enter code", "confirmation code", "authentication code", "2fa"]
    static let passWords = ["boarding pass", "ticket", "admit one", "e-ticket", "event pass", "entry pass", "general admission"]
    static let tripWords = ["gate", "seat", "flight", "departure", "departs", "boarding", "section", "row", "terminal"]
    static let receiptWords = ["total", "subtotal", "tax", "receipt", "order", "paid", "amount", "payment", "invoice",
                               "visa", "mastercard", "amex", "change due", "tip"]
    static let mapWords = ["directions", "route", "eta", "arrive", "arrival", "min", "mi", "km", "exit", "turn",
                           "navigation", "maps", "fastest", "traffic", "walk", "drive", "miles"]
    static let chatWords = ["imessage", "text message", "delivered", "read", "whatsapp", "messenger", "typing",
                            "reply", "today", "yesterday", "message", "sent"]

    static func classify(_ text: String, now: Date = .now) -> ScreenshotKind {
        let lower = text.lowercased()
        let words = Set(lower.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        func has(_ phrase: String) -> Bool {
            phrase.contains { !$0.isLetter && !$0.isNumber } ? lower.contains(phrase) : words.contains(phrase)
        }
        func count(_ list: [String]) -> Int { list.filter(has).count }

        if count(codeWords) > 0, matches(#"(?<![\d.,:/$])\d{4,8}(?![\d:/])"#, in: lower) || matches(#"\b[a-z]-\d{5,6}\b"#, in: lower) {
            return .loginCode
        }
        if count(passWords) > 0 || count(tripWords) >= 2 {
            let dates = self.dates(in: text)
            let today = Calendar.current.startOfDay(for: now)
            if let latest = dates.max(), latest < today { return .expiredPass }
        }
        if count(receiptWords) > 0, matches(#"([$€£¥]\s?\d[\d,]*[.,]\d{2})|(\d[\d,]*[.,]\d{2}\s?(usd|eur|gbp|cad|aud))"#, in: lower) {
            return .receipt
        }
        if count(mapWords) >= 3 { return .map }
        if count(chatWords) >= 2 || occurrences(#"\b\d{1,2}:\d{2}\s?(am|pm)?\b"#, in: lower) >= 3 { return .chat }
        return .other
    }

    static func matches(_ pattern: String, in text: String) -> Bool { occurrences(pattern, in: text) > 0 }

    static func occurrences(_ pattern: String, in text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    static func dates(in text: String) -> [Date] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return [] }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.date)
    }
}

/// Reads the words in screenshots on this iPhone, a few at a time, and keeps only the group each belongs to.
@MainActor
final class ScreenshotSorter: ObservableObject {
    static let shared = ScreenshotSorter()

    @Published private(set) var kinds: [String: ScreenshotKind] = [:]
    @Published private(set) var done = 0
    @Published private(set) var total = 0
    @Published private(set) var running = false
    private var task: Task<Void, Never>?
    private var loaded = false

    private static var file: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("SmartPhotoVault", isDirectory: true)
            .appendingPathComponent("screenshot-kinds.json")
    }

    func start(_ ids: [String]) {
        guard !running else { return }
        if !loaded {
            loaded = true
            if let file = Self.file, let data = try? Data(contentsOf: file),
               let saved = try? JSONDecoder().decode([String: ScreenshotKind].self, from: data) {
                kinds = saved.filter { Set(ids).contains($0.key) }
            }
        }
        let waiting = ids.filter { kinds[$0] == nil && !$0.hasPrefix("sample-") }
        total = ids.count
        done = ids.count - waiting.count
        guard !waiting.isEmpty else { return }
        running = true
        task = Task { [weak self] in
            var index = 0
            while index < waiting.count, !Task.isCancelled {
                if ProcessInfo.processInfo.isLowPowerModeEnabled || ProcessInfo.processInfo.thermalState == .serious {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    continue
                }
                let batch = Array(waiting[index..<min(index + 8, waiting.count)])
                index += batch.count
                let found = await Task.detached(priority: .utility) {
                    batch.map { id in (id, ScreenshotSorter.read(id)) }
                }.value
                guard let self else { return }
                for (id, kind) in found { self.kinds[id] = kind }
                self.done += batch.count
                self.save()
            }
            self?.running = false
        }
    }

    func stop() { task?.cancel() }

    private func save() {
        guard let file = Self.file, let data = try? JSONEncoder().encode(kinds) else { return }
        try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// The words go straight to the classifier and are dropped.
    nonisolated static func read(_ id: String) -> ScreenshotKind {
        guard let image = BestShotReader.picture(id, side: 1_600) else { return .other }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return .other }
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        return ScreenshotClassifier.classify(text)
    }
}
