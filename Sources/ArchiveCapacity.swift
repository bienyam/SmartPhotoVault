import Foundation
import Network

struct ArchiveCapacity {
    let selected: Int64
    let available: Int64?

    var fits: Bool? { available.map { selected <= $0 } }
}

final class ArchiveWiFi: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var connected = false

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self.connected = path.status == .satisfied && path.usesInterfaceType(.wifi)
            self.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "SmartPhotoVault.ArchiveWiFi"))
    }

    deinit { monitor.cancel() }

    func requireConnection() throws {
        lock.lock()
        defer { lock.unlock() }
        guard connected else { throw ArchiveError.wifi }
    }
}
