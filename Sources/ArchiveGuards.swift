import Foundation
import Photos

/// The free 5 GB of archiving, kept to during a run (1.0.2, B4). Each item takes its size before it is
/// copied; an item that doesn't fit, or whose size isn't known on a free plan, isn't copied. Once a
/// copy is made its real size replaces the one it took; a failed copy gives its room back.
struct FreeArchiveBudget {
    /// What is left of the free allowance. Nil with Pro: no limit.
    private(set) var left: Int64?

    init(used: Int64, unlimited: Bool, limit: Int64 = ProStore.freeArchiveBytes) {
        left = unlimited ? nil : max(0, limit - used)
    }

    mutating func take(_ bytes: Int64?) -> Bool {
        guard let remaining = left else { return true }
        guard let bytes, bytes >= 0, bytes <= remaining else { return false }
        left = remaining - bytes
        return true
    }

    mutating func settle(took: Int64?, actual: Int64) {
        guard let remaining = left, let took else { return }
        left = max(0, remaining + took - actual)
    }

    mutating func giveBack(_ took: Int64?) {
        guard let remaining = left, let took else { return }
        left = remaining + took
    }

    /// Everything archived so far, read again from the archive list. Unreadable counts as nothing.
    static func usedNow() async -> Int64 {
        await Task.detached(priority: .userInitiated) { (try? InventoryStore.openDefault().archivedBytes()) ?? 0 }.value
    }

    /// The size Photos reports for each item (item ID, Photos ID), every file together, without
    /// downloading anything. Items Photos reports no size for are left out. Blocks: call it off the
    /// main thread.
    static func reportedSizes(_ items: [(String, String)]) -> [String: Int64] {
        guard !items.isEmpty else { return [:] }
        var byPhoto: [String: Int64] = [:]
        PHAsset.fetchAssets(withLocalIdentifiers: items.map(\.1), options: nil).enumerateObjects { asset, _, _ in
            if let size = DuplicateScanner.reportedSize(of: PHAssetResource.assetResources(for: asset)), size > 0 {
                byPhoto[asset.localIdentifier] = size
            }
        }
        var sizes: [String: Int64] = [:]
        for (item, photo) in items { if let size = byPhoto[photo] { sizes[item] = size } }
        return sizes
    }
}

/// Items that are already archived in the place a run is copying to, so they aren't copied a second
/// time under a numbered name (1.0.2). An item counts only when all of these hold:
/// - a confirmed record of it is for this same place (`matches`);
/// - that record still stands for the item as it is in Photos (`BackupLedger.covers`: not edited since);
/// - its copy is still there at exactly the recorded size (`ArchiveProver.copyStillThere`).
/// Files picked from Files have no Photos item and are always copied. Anything that can't be checked in
/// time is copied as usual. A different photo that happens to share a file name is a different item, so
/// it is never skipped and still gets the next free number.
enum AlreadyArchivedHere {
    static func find(_ selection: [ArchiveItem], wifi: ArchiveWiFi,
                     matches: @escaping @Sendable (ArchivedRecord) -> Bool) async -> Set<String> {
        var itemsByPhoto: [String: [String]] = [:]
        for item in selection {
            if case let .photo(id, _) = item.source { itemsByPhoto[id, default: []].append(item.id) }
        }
        guard !itemsByPhoto.isEmpty else { return [] }
        let photos = Array(itemsByPhoto.keys)
        let candidates = await Task.detached(priority: .userInitiated) { () -> [ArchivedRecord] in
            guard let records = try? InventoryStore.openDefault().archived() else { return [] }
            let wanted = Set(photos)
            let here = records.filter { record in
                guard let id = record.photoID, wanted.contains(id) else { return false }
                return matches(record)
            }
            guard !here.isEmpty else { return [] }
            return BackupLedger.covering(here, now: BackupLedger.originals(Array(Set(here.compactMap(\.photoID)))))
        }.value
        guard !candidates.isEmpty else { return [] }
        let present = await BackupLedger.present(candidates) { await ArchiveProver.copyStillThere($0, wifi: wifi) }
        return Set(present.flatMap { itemsByPhoto[$0] ?? [] })
    }

    /// A drive, folder or home-server record whose folder is `path`.
    static func inFolder(_ record: ArchivedRecord, _ path: String) -> Bool {
        guard record.cloud == nil, record.driveFileID == nil, let bookmark = record.folderBookmark else { return false }
        var stale = false
        guard let folder = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale) else { return false }
        return folder.standardizedFileURL.path == path
    }
}

/// An item that wasn't copied because it doesn't fit in what is left of the free 5 GB.
struct OverFreeArchive: LocalizedError {
    var errorDescription: String? {
        "It doesn't fit in what is left of your free 5 GB of archiving. Archiving more needs TidyAway Pro."
    }
}

/// Time limits for the quick checks that ask a destination whether a copy is still there.
enum ArchiveDeadline {
    /// One copy's files: a metadata call or a file's size. A copy that takes longer counts as not there.
    static let perCopy: TimeInterval = 8
    /// The whole not-backed-up check. Checks not started by then count as not backed up, so the
    /// check errs on the side of asking.
    static let wholeCheck: TimeInterval = 20

    /// The answer of `work`, or nil when it throws or takes longer than `seconds`. Returns as soon as
    /// the time is up, even if `work` is stuck in a call that can't be cancelled (a drive that stopped
    /// answering); `work` is told to cancel and its late answer is ignored.
    static func within<T: Sendable>(_ seconds: TimeInterval, _ work: @escaping @Sendable () async throws -> T) async -> T? {
        let once = AnswerOnce<T>()
        return await withCheckedContinuation { continuation in
            once.set(continuation)
            let job = Task.detached(priority: .userInitiated) { once.answer(try? await work()) }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                job.cancel()
                once.answer(nil)
            }
        }
    }
}

/// Which copies on a drive, folder or home server have been read back in full and matched their
/// fingerprint, and what each looked like then (size and modification date). While a copy still looks
/// exactly like that, later checks before removal stay size-only; any change reads it back again.
/// Kept on this iPhone, never with file names: each entry is keyed by the record's ID and the file's
/// size and fingerprint.
enum ReadBackLedger {
    static let key = "archive.readBack.v1"
    private static let lock = NSLock()

    /// One file of one record. The files of a Live Photo or edited photo share the record's ID and
    /// differ by their size and fingerprint.
    static func entry(_ record: ArchivedRecord) -> String {
        "\(record.id)#\(record.bytes)#\(record.digest.lowercased())"
    }

    static func value(_ stamp: CopyStamp) -> String {
        "\(stamp.bytes)@\(stamp.modified.map { String($0.timeIntervalSince1970) } ?? "-")"
    }

    /// True when this copy was read back in full and hasn't changed since.
    static func readBack(_ record: ArchivedRecord, stamp: CopyStamp, store: UserDefaults = .standard) -> Bool {
        guard stamp.modified != nil else { return false }
        lock.lock()
        defer { lock.unlock() }
        let known = store.dictionary(forKey: key) as? [String: String] ?? [:]
        return known[entry(record)] == value(stamp)
    }

    static func note(_ record: ArchivedRecord, stamp: CopyStamp, store: UserDefaults = .standard) {
        lock.lock()
        defer { lock.unlock() }
        var known = store.dictionary(forKey: key) as? [String: String] ?? [:]
        known[entry(record)] = value(stamp)
        store.set(known, forKey: key)
    }
}

/// Resumes a continuation once, with whichever answer comes first.
private final class AnswerOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?
    private var early: T??

    func set(_ continuation: CheckedContinuation<T?, Never>) {
        lock.lock()
        if let early {
            lock.unlock()
            continuation.resume(returning: early)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func answer(_ value: T?) {
        lock.lock()
        guard early == nil else { lock.unlock(); return }
        early = .some(value)
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(returning: value)
    }
}
