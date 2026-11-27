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
