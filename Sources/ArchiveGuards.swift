import Foundation

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
