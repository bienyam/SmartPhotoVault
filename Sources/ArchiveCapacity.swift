import Foundation
import Network

struct ArchiveCapacity {
    let selected: Int64
    let available: Int64?

    var fits: Bool? { available.map { selected <= $0 } }
}

/// What TidyAway can tell about a chosen archive folder the moment it's picked, so problems show
/// up before copying rather than halfway through.
struct FolderCheck: Equatable, Sendable {
    let format: String?
    let readOnly: Bool
    let available: Int64?
    let writable: Bool

    /// Windows-formatted drives: iPhone can read them but not save to them.
    var isNTFS: Bool { format?.localizedCaseInsensitiveContains("NTFS") ?? false }
    /// FAT32 ("MS-DOS (FAT)") can't hold a single file over 4 GB. ExFAT can.
    var isFAT32: Bool {
        guard let format = format?.uppercased() else { return false }
        return format.contains("FAT") && !format.contains("EXFAT")
    }
    static let fat32FileLimit: Int64 = 4_294_967_295

    var problem: String? {
        if isNTFS {
            return "This drive is formatted for Windows (NTFS). iPhone can read it but can't save to it. To use it here, it has to be erased as ExFAT. On an iPhone with USB-C, do that in the Files app: touch and hold the drive, then tap Erase. With Lightning, use a computer. Erasing deletes everything on the drive, so copy anything you need first."
        }
        if readOnly || !writable {
            return "TidyAway can't save to this folder. It may be read-only or need you to sign in again in the Files app. Choose another folder."
        }
        return nil
    }

    /// Reads the volume details and tries a tiny write that is removed straight away.
    /// The test file is TidyAway's own; nothing already in the folder is touched.
    static func run(on folder: URL) -> FolderCheck {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let values = try? folder.resourceValues(forKeys: [.volumeLocalizedFormatDescriptionKey, .volumeIsReadOnlyKey,
                                                          .volumeAvailableCapacityKey])
        let probe = folder.appendingPathComponent(".tidyaway-write-check-\(UUID().uuidString)")
        var writable = false
        if FileManager.default.createFile(atPath: probe.path, contents: Data("ok".utf8)) {
            writable = true
            try? FileManager.default.removeItem(at: probe)
        }
        return FolderCheck(format: values?.volumeLocalizedFormatDescription,
                           readOnly: values?.volumeIsReadOnly ?? false,
                           available: values?.volumeAvailableCapacity.map(Int64.init),
                           writable: writable)
    }
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
