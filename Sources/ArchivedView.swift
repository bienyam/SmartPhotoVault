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
    /// Which photo this came from, kept on this iPhone only to show its picture while it is still there.
    var photoID: String? = nil
    /// Set when the copy is in OneDrive or Dropbox; `driveFileID` then holds that service's file ID.
    var cloud: CloudService? = nil
    /// That service's own fingerprint of the copy, matched when it was archived.
    var cloudHash: String? = nil
    /// A Live Photo or an edited photo: its other files, stored beside this one and each checked the
    /// same way. Everything above then describes the original still. Nil for a single-file copy and in
    /// every record saved before these could be archived.
    var parts: [ArchivedPart]? = nil
}

/// Archived items grouped by the day they were archived.
struct ArchiveDay: Identifiable, Equatable {
    let day: Date
    let records: [ArchivedRecord]
    var id: Date { day }
    var bytes: Int64 { records.reduce(0) { $0 + $1.totalBytes } }
    var places: String { Array(Set(records.map(\.folderName))).sorted().joined(separator: ", ") }

    /// Newest day first; files within a day in name order.
    static func group(_ records: [ArchivedRecord], calendar: Calendar = .current) -> [ArchiveDay] {
        Dictionary(grouping: records) { calendar.startOfDay(for: $0.date) }
            .map { ArchiveDay(day: $0.key, records: $0.value.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) }
            .sorted { $0.day > $1.day }
    }
}

/// Get back: archived items by date, as picture cards. Tap a day to see its files and restore them.
struct ArchivedView: View {
    @State private var records: [ArchivedRecord] = []
    @State private var year: Int?
    @State private var loaded = false

    private var years: [Int] {
        Array(Set(records.map { Calendar.current.component(.year, from: $0.date) })).sorted(by: >)
    }

    private var days: [ArchiveDay] {
        ArchiveDay.group(records.filter { year == nil || Calendar.current.component(.year, from: $0.date) == year })
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if loaded, records.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "arrow.uturn.backward.circle.fill")
                            .font(.system(size: 72)).foregroundStyle(ArchiveStyle.link).accessibilityHidden(true)
                        Text("Nothing archived yet.").font(.title3.bold())
                        Text("What you move out appears here by day, ready to put back.")
                            .foregroundStyle(ArchiveStyle.muted)
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else if !records.isEmpty {
                    Text("What do you want back?").font(.title3.weight(.heavy)).foregroundStyle(ArchiveStyle.ink)
                        .accessibilityAddTraits(.isHeader)
                    if years.count > 1 {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                pill("All", on: year == nil) { year = nil }
                                ForEach(years, id: \.self) { value in
                                    pill(String(value), on: year == value) { year = value }
                                }
                            }
                        }
                    }
                    ForEach(days) { day in
                        NavigationLink {
                            ArchivedDayView(day: day, reload: reload)
                        } label: {
                            card(day)
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityIdentifier("archive-day")
                    }
                    Text("Every copy was checked when it was made.")
                        .font(.footnote).foregroundStyle(ArchiveStyle.muted)
                }
            }
            .frame(maxWidth: 640)
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity)
            .reportsArchiveScroll()
        }
        .coordinateSpace(name: ArchiveScroll.space)
        .background(Brand.background)
        .onAppear(perform: reload)
    }

    private func pill(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.subheadline.weight(.bold))
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .foregroundStyle(on ? ArchiveStyle.onSelected : ArchiveStyle.ink)
            .background(on ? ArchiveStyle.selected : Color.clear, in: Capsule())
            .overlay(Capsule().stroke(on ? Color.clear : ArchiveStyle.border, lineWidth: 1.5))
            .buttonStyle(.plain)
            .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func card(_ day: ArchiveDay) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            let pictures = day.records.prefix(4)
            if !pictures.isEmpty {
                HStack(spacing: 4) {
                    ForEach(Array(pictures)) { record in
                        ArchivedThumb(record: record, side: 240)
                            .frame(height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            Text(day.day.formatted(date: .complete, time: .omitted)).font(.headline).foregroundStyle(ArchiveStyle.ink)
            Text("\(day.records.count.formatted()) \(day.records.count == 1 ? "item" : "items") · \(day.bytes.fileSize) · \(day.places)")
                .font(.footnote).foregroundStyle(ArchiveStyle.muted)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.surface, in: RoundedRectangle(cornerRadius: 18))
        .contentShape(Rectangle())
    }

    private func reload() {
        // App Store pictures show stand-in records. Nil everywhere else.
        if let sample = DemoLibrary.archivedRecords {
            records = sample
            loaded = true
            return
        }
        records = (try? InventoryStore.openDefault().archived()) ?? []
        loaded = true
        // Keep pictures of archived photos that are still in the library, for after they're removed.
        ArchiveThumbnails.rememberSoon(records.compactMap(\.photoID))
        if let year, !years.contains(year) { self.year = nil }
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
                            ArchivedThumb(record: record, side: 140)
                                .frame(width: 48, height: 48)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(record.name).foregroundStyle(.primary).lineLimit(1)
                                Text("\(record.totalBytes.fileSize)\(record.filesNote.map { " · \($0)" } ?? "") · \(record.folderName) · \(record.date.formatted(date: .omitted, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(selected.contains(record.id) ? "Deselect" : "Select") { toggle(record) }
                    } preview: {
                        // The saved small copy when the original has left this iPhone.
                        ArchivedThumb(record: record, side: 1000).frame(width: 320, height: 420)
                    }
                    .accessibilityIdentifier("archived-\(record.id)")
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
        .safeAreaInset(edge: .bottom) {
            if !chosen.isEmpty {
                VStack(spacing: 8) {
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
                        .buttonStyle(ArchiveOutlineStyle())
                    }
                    Toggle(consentText, isOn: $consent)
                        .font(.footnote)
                        .accessibilityIdentifier("restore-consent")
                    Button(busy ? progress : "Put back \(chosen.count.formatted()) \(chosen.count == 1 ? "item" : "items")") { restore() }
                        .buttonStyle(ArchiveButtonStyle())
                        .disabled(!consent || busy || (target == .folder && folder == nil))
                        .accessibilityIdentifier("restore-go")
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.regularMaterial)
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
            ? "I authorize adding these items back to Apple Photos. They use space on this \(Device.name), and the archive copies stay in place."
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
        if let service = record.cloud, let fileID = record.driveFileID {
            let account = await CloudAccount.shared(service)
            let token = try await account.accessToken()
            let downloaded = try await CloudArchive.download(fileID, from: service, token: token)
            guard downloaded.digest == record.digest.lowercased() else {
                try? FileManager.default.removeItem(at: downloaded.url)
                throw CloudError.verification(service.name)
            }
            let named = downloaded.url.deletingLastPathComponent().appendingPathComponent("\(UUID().uuidString)-\(record.name)")
            try FileManager.default.moveItem(at: downloaded.url, to: named)
            return named
        }
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

    /// A verified local copy of every file of the item, original first. Each is checked against its own
    /// fingerprint; if any one fails, none is returned.
    static func verifiedCopies(_ record: ArchivedRecord, wifi: ArchiveWiFi) async throws -> [URL] {
        var copies: [URL] = []
        do {
            for file in record.files { copies.append(try await verifiedCopy(file, wifi: wifi)) }
        } catch {
            for copy in copies { try? FileManager.default.removeItem(at: copy) }
            throw error
        }
        return copies
    }

    /// True when Photos on this iPhone says it can build one item out of these kinds of files.
    static func photosCanRebuild(_ types: [Int]) -> Bool {
        !types.isEmpty && types.allSatisfy { PHAssetResourceType(rawValue: $0) != nil }
            && PHAssetCreationRequest.supportsAssetResourceTypes(types.map { NSNumber(value: $0) })
    }

    /// Puts a Live Photo or an edited photo back as one item: the original still with its video, its edit
    /// instructions and its edited picture, so it comes back live, edited and able to revert. Afterwards
    /// the new item must hold every kind of file that was archived.
    /// Returns the new item's Photos ID.
    @discardableResult
    static func everyPartToPhotos(_ record: ArchivedRecord, wifi: ArchiveWiFi) async throws -> String {
        let types = record.partTypes
        guard photosCanRebuild(types) else { throw ArchiveRestoreError.photosCannotRebuild(record.name) }
        let files = try await verifiedCopies(record, wifi: wifi)
        defer { for file in files { try? FileManager.default.removeItem(at: file) } }
        guard files.count == types.count else { throw ArchiveError.verification }
        let created = ArchiveCreatedBox()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            for (index, file) in files.enumerated() {
                guard let type = PHAssetResourceType(rawValue: types[index]) else { continue }
                let options = PHAssetResourceCreationOptions()
                if index == 0 { options.originalFilename = record.name }
                request.addResource(with: type, fileURL: file, options: options)
            }
            created.id = request.placeholderForCreatedAsset?.localIdentifier
        }
        guard let id = created.id,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            throw ArchiveRestoreError.partsMissing(record.name)
        }
        try requireEveryPart(PHAssetResource.assetResources(for: asset).map { $0.type.rawValue }, of: types, name: record.name)
        return id
    }

    /// The item Photos built must hold every kind of file that was archived, or it is reported as incomplete.
    static func requireEveryPart(_ found: [Int], of wanted: [Int], name: String) throws {
        guard !wanted.isEmpty, Set(found).isSuperset(of: wanted) else { throw ArchiveRestoreError.partsMissing(name) }
    }

    /// Adds the archived original back to Apple Photos as a new item.
    static func toPhotos(_ record: ArchivedRecord, wifi: ArchiveWiFi) async throws {
        if record.hasParts {
            try await everyPartToPhotos(record, wifi: wifi)
            return
        }
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

    /// Saves the archived original as a new file in a chosen folder, never overwriting. A Live Photo or
    /// an edited photo is saved as all its files, side by side under the names they have in the archive.
    static func toFolder(_ record: ArchivedRecord, folder: URL, wifi: ArchiveWiFi) async throws {
        let files = record.files
        guard files.count > 1 else { return try await fileToFolder(record, folder: folder, wifi: wifi) }
        // Nothing is written unless every name is free.
        let taken: Bool = {
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            return files.contains { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.name).path) }
        }()
        guard !taken else { throw ArchiveError.conflict }
        // If a later file fails, the ones this attempt just wrote are taken back, so the folder never
        // keeps half an item and a second try isn't stopped by its own leftovers. Only files written
        // here, moments ago, are removed; anything that was already in the folder is never touched.
        var written: [String] = []
        do {
            for file in files {
                try await fileToFolder(file, folder: folder, wifi: wifi)
                written.append(file.name)
            }
        } catch {
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            for name in written { try? FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }
            throw error
        }
    }

    private static func fileToFolder(_ record: ArchivedRecord, folder: URL, wifi: ArchiveWiFi) async throws {
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

/// Carries the new item's ID out of the Photos change.
final class ArchiveCreatedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    var id: String? {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

enum ArchiveRestoreError: LocalizedError {
    case folderGone(String, String)
    /// Photos on this iPhone won't build one item out of these files.
    case photosCannotRebuild(String)
    /// Photos took the item but didn't keep every file.
    case partsMissing(String)
    var errorDescription: String? {
        switch self {
        case .photosCannotRebuild:
            "Photos on this \(Device.name) can't rebuild this Live Photo or edited photo as one item. Put it back to a folder in Files instead to get every part. The archive copies stay where they are."
        case .partsMissing:
            "Photos took the picture but didn't keep its Live Photo or edit part. The archive copies are unchanged: put it back to a folder in Files to get every part."

        case let .folderGone(folder, name):
            "TidyAway can no longer open that archive folder. Your copy is still in \(folder): open it in Files to find \(name)."
        }
    }
}
