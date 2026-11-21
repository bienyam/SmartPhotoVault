import Photos
import SwiftUI
import UniformTypeIdentifiers

/// One verified archive copy, kept so the user can find it and restore it later.
struct ArchivedRecord: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let folderName: String
    let bytes: Int64
    let digest: String
    let date: Date
    let viaHomeServer: Bool
    let folderBookmark: Data?
    /// Set when the copy is in Google Drive rather than a Files folder.
    var driveFileID: String? = nil
}

/// Archived items grouped by the day they were archived.
struct ArchiveDay: Identifiable, Equatable {
    let day: Date
    let records: [ArchivedRecord]
    var id: Date { day }
    var bytes: Int64 { records.reduce(0) { $0 + $1.bytes } }
    var places: String { Array(Set(records.map(\.folderName))).sorted().joined(separator: ", ") }

    /// Newest day first; files within a day in name order.
    static func group(_ records: [ArchivedRecord], calendar: Calendar = .current) -> [ArchiveDay] {
        Dictionary(grouping: records) { calendar.startOfDay(for: $0.date) }
            .map { ArchiveDay(day: $0.key, records: $0.value.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) }
            .sorted { $0.day > $1.day }
    }
}

/// Get back: archived items by date. Tap a day to see its files and restore them.
struct ArchivedView: View {
    @State private var records: [ArchivedRecord] = []

    var body: some View {
        List {
            if records.isEmpty {
                Section {
                    Text("Nothing archived yet.").font(.headline)
                    Text("Copies you make with Move out appear here, grouped by date, so you can put any of them back.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(ArchiveDay.group(records)) { day in
                        NavigationLink {
                            ArchivedDayView(day: day, reload: reload)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(day.day.formatted(date: .complete, time: .omitted)).font(.headline)
                                Text("\(day.records.count) \(day.records.count == 1 ? "item" : "items") · \(day.bytes.fileSize) · \(day.places)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                        .accessibilityIdentifier("archive-day")
                    }
                } header: {
                    Text("Archived")
                } footer: {
                    Text("Every copy was checked when it was made. Tap a date to see its files and put any of them back.")
                }
            }
        }
        .navigationTitle("Archived")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
    }

    private func reload() {
        records = (try? InventoryStore.openDefault().archived()) ?? []
    }
}

/// The files archived on one day, with restore back into Photos (default) or to a folder in Files.
struct ArchivedDayView: View {
    let day: ArchiveDay
    let reload: () -> Void

    enum Target: String, CaseIterable { case photos = "Photos", folder = "A folder in Files" }

    @State private var selected: Set<String> = []
    @State private var target = Target.photos
    @State private var folder: URL?
    @State private var showFolders = false
    @State private var consent = false
    @State private var busy = false
    @State private var progress = ""
    @State private var problems: [String] = []
    @State private var done: (count: Int, target: Target)?
    @State private var wifi = ArchiveWiFi()
    @Environment(\.openURL) private var openURL

    private var chosen: [ArchivedRecord] { day.records.filter { selected.contains($0.id) } }
    private var allSelected: Bool { selected.count == day.records.count }

    var body: some View {
        List {
            Section {
                ForEach(day.records) { record in
                    Button { toggle(record) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selected.contains(record.id) ? "checkmark.circle.fill" : "circle")
                                .font(.title2)
                                .foregroundStyle(selected.contains(record.id) ? Brand.primary : Color.secondary)
                            Image(systemName: Self.isVideo(record.name) ? "video" : "photo")
                                .foregroundStyle(.secondary).frame(width: 24)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(record.name).foregroundStyle(.primary).lineLimit(1)
                                Text("\(record.bytes.fileSize) · \(record.folderName) · \(record.date.formatted(date: .omitted, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("archived-\(record.id)")
                }
            }
            if !chosen.isEmpty {
                Section("Put back") {
                    Picker("Put back to", selection: $target) {
                        ForEach(Target.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: target) { consent = false }
                    .accessibilityIdentifier("restore-target")
                    if target == .folder {
                        Button { showFolders = true } label: {
                            Label(folder.map { "Folder: \($0.lastPathComponent)" } ?? "Choose a folder", systemImage: "folder")
                        }
                    }
                    Toggle(consentText, isOn: $consent).accessibilityIdentifier("restore-consent")
                    Button {
                        restore()
                    } label: {
                        Text(busy ? progress : "Put back \(chosen.count) \(chosen.count == 1 ? "item" : "items")")
                            .font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.primary)
                    .disabled(!consent || busy || (target == .folder && folder == nil))
                    .accessibilityIdentifier("restore-go")
                }
            }
            if !problems.isEmpty {
                Section("Couldn't put back") {
                    ForEach(problems, id: \.self) { Text($0).font(.footnote).foregroundStyle(Brand.caution) }
                }
            }
        }
        .navigationTitle(day.day.formatted(date: .abbreviated, time: .omitted))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(allSelected ? "Deselect all" : "Select all") {
                    selected = allSelected ? [] : Set(day.records.map(\.id))
                    consent = false
                }
                .accessibilityIdentifier("select-all")
            }
        }
        .fileImporter(isPresented: $showFolders, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { folder = url; consent = false }
        }
        .fullScreenCover(isPresented: Binding(get: { done != nil }, set: { if !$0 { done = nil } })) {
            if let done {
                CompletionView(
                    title: done.target == .photos ? "Back in Photos" : "Put back",
                    detail: "\(done.count) \(done.count == 1 ? "item is" : "items are") back \(done.target == .photos ? "in your Photos library" : "in \(folder?.lastPathComponent ?? "your folder")"), checked against the archive. The archive copies stay where they are.",
                    actions: [])
            }
        }
    }

    private var consentText: String {
        target == .photos
            ? "I authorize adding these items back to Apple Photos. They use space on this iPhone, and the archive copies stay in place."
            : "I authorize creating copies in this folder. They use storage and the folder's provider may sync them. The archive copies stay in place."
    }

    private func toggle(_ record: ArchivedRecord) {
        if selected.contains(record.id) { selected.remove(record.id) } else { selected.insert(record.id) }
        consent = false
    }

    static func isVideo(_ name: String) -> Bool {
        UTType(filenameExtension: (name as NSString).pathExtension)?.conforms(to: .movie) ?? false
    }

    private func restore() {
        guard consent, !busy else { return }
        let records = chosen
        let target = self.target
        let folder = self.folder
        let wifiCheck = wifi
        consent = false
        busy = true
        problems = []
        let operation = UUID()
        try? InventoryStore.openDefault().log("Authorized putting back \(records.count) archived item(s) to \(target == .photos ? "Apple Photos" : "a Files folder") (\(operation)), disclosure v1.")
        Task {
            var restored = 0
            if target == .photos, PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined {
                _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            }
            for (index, record) in records.enumerated() {
                progress = "Putting back \(index + 1) of \(records.count)…"
                do {
                    switch target {
                    case .photos: try await ArchiveRestore.toPhotos(record, wifi: wifiCheck)
                    case .folder:
                        guard let folder else { throw ArchiveError.unavailable }
                        try await ArchiveRestore.toFolder(record, folder: folder, wifi: wifiCheck)
                    }
                    restored += 1
                } catch {
                    problems.append("\(record.name) — \(error.localizedDescription)")
                }
            }
            try? InventoryStore.openDefault().log("Put back \(operation) finished: \(restored) of \(records.count) verified.")
            busy = false
            selected = []
            if restored > 0 { done = (restored, target) }
        }
    }
}

/// Puts an archived copy back, always checking it against the fingerprint taken when it was archived.
enum ArchiveRestore {
    /// A verified local copy of the archived file, in a temporary folder.
    static func verifiedCopy(_ record: ArchivedRecord, wifi: ArchiveWiFi) async throws -> URL {
        if let fileID = record.driveFileID {
            let token = try await GoogleDriveAccount.shared.accessToken()
            let downloaded = try await GoogleDriveClient.download(fileID, token: token)
            guard downloaded.digest == record.digest.lowercased() else {
                try? FileManager.default.removeItem(at: downloaded.url)
                throw GoogleDriveError.verification
            }
            let named = downloaded.url.deletingLastPathComponent().appendingPathComponent("\(UUID().uuidString)-\(record.name)")
            try FileManager.default.moveItem(at: downloaded.url, to: named)
            return named
        }
        var stale = false
        guard let bookmark = record.folderBookmark,
              let source = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale) else {
            throw ArchiveRestoreError.folderGone(record.folderName, record.name)
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("TidyAwayRestore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let receipt = ArchiveReceipt(id: record.id, url: source.appendingPathComponent(record.name), folder: source,
                                     fingerprint: ArchiveFingerprint(bytes: record.bytes, digest: record.digest))
        let wifiCheck: ArchiveWiFi? = record.viaHomeServer ? wifi : nil
        return try await Task.detached(priority: .userInitiated) {
            try VerifiedArchive.restore(receipt, to: temporary, wifi: wifiCheck)
        }.value
    }

    /// Adds the archived original back to Apple Photos as a new item.
    static func toPhotos(_ record: ArchivedRecord, wifi: ArchiveWiFi) async throws {
        let file = try await verifiedCopy(record, wifi: wifi)
        defer { try? FileManager.default.removeItem(at: file) }
        let video = ArchivedDayView.isVideo(record.name)
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = record.name
            request.addResource(with: video ? .video : .photo, fileURL: file, options: options)
        }
    }

    /// Saves the archived original as a new file in a chosen folder, never overwriting.
    static func toFolder(_ record: ArchivedRecord, folder: URL, wifi: ArchiveWiFi) async throws {
        let file = try await verifiedCopy(record, wifi: wifi)
        defer { try? FileManager.default.removeItem(at: file) }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let destination = folder.appendingPathComponent(record.name)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw ArchiveError.conflict }
        try FileManager.default.copyItem(at: file, to: destination)
        guard try GoogleDriveClient.sha256(of: destination) == record.digest.lowercased() else {
            try? FileManager.default.removeItem(at: destination)
            throw ArchiveError.verification
        }
    }
}

enum ArchiveRestoreError: LocalizedError {
    case folderGone(String, String)
    var errorDescription: String? {
        switch self {
        case let .folderGone(folder, name):
            "TidyAway can no longer open that archive folder. Your copy is still in \(folder): open it in Files to find \(name)."
        }
    }
}
