import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct PhotoArchiveView: View {
    let snapshot: ScanSnapshot?

    private enum Age: String, CaseIterable {
        case any = "Any time"
        case one = "Over 1 year old"
        case two = "Over 2 years old"
        case five = "Over 5 years old"

        var years: Int? {
            switch self {
            case .any: nil
            case .one: 1
            case .two: 2
            case .five: 5
            }
        }
    }

    private enum SizeFloor: String, CaseIterable {
        case any = "Any size"
        case five = "Over 5 MB"
        case ten = "Over 10 MB"
        case twentyFive = "Over 25 MB"

        var bytes: Int64 {
            switch self {
            case .any: 0
            case .five: 5_000_000
            case .ten: 10_000_000
            case .twentyFive: 25_000_000
            }
        }
    }


    private static let suggestionLimit = 200

    private enum PickerPurpose {
        case files, archive, restore
    }

    private enum Destination: String, CaseIterable {
        case drive = "Drive plugged into this iPhone"
        case iCloud = "iCloud Drive"
        case shared = "Another Apple Account"
        case google = "Google Drive"
        case home = "Home file server"
        case other = "Other Files location"

        var detail: String {
            switch self {
            case .drive: "Plug a USB-C drive or memory stick into your iPhone (older iPhones need Apple's camera adapter), then choose it under Locations. ExFAT drives work best."
            case .iCloud: "Choose a folder from iCloud Drive in Files."
            case .shared: "Choose a folder the other Apple Account has shared with you with permission to make changes."
            case .google: "Choose Google Drive under Locations in Files. Install and sign in to Google Drive if it’s missing."
            case .home: "In Files, connect to your server from Browse → More → Connect to Server, then choose its shared folder. Stay on the same Wi-Fi as your server for copying, verification and restore. This workflow has no background sync."
            case .other: "Choose a folder from another provider in Files, an attached drive, or On My iPhone."
            }
        }

        var icon: String {
            switch self {
            case .drive: "externaldrive.connected.to.line.below"
            case .iCloud, .shared: "icloud"
            case .google: "externaldrive"
            case .home: "server.rack"
            case .other: "folder"
            }
        }
    }

    @Environment(\.locale) private var locale
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var photoAccess = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var items: [ArchiveItem] = []
    @State private var destination: URL?
    @State private var destinationKind: Destination?
    @State private var availableGB = ""
    @State private var measuredBytes: [String: Int64] = [:]
    @State private var checkedPhotos: [String: ResourceFingerprint] = [:]
    @State private var wifi = ArchiveWiFi()
    @State private var restoreFolder: URL?
    @State private var picker: PickerPurpose = .files
    @State private var showFiles = false
    @State private var age: Age = .two
    @State private var sizeFloor: SizeFloor = .any
    @State private var kind: ArchiveKind = .photos
    @State private var albumID: String?
    @State private var place: PlaceArea?
    @State private var showPlacePicker = false
    @State private var showSuggested = false
    @State private var suggested: [ArchiveItem] = []
    @State private var archiveConsent = false
    @State private var restoreConsent = false
    @State private var busy = false
    @State private var checkingSizes = false
    @State private var message: String?
    @State private var receipts: [ArchiveReceipt] = []
    @State private var restoreTarget: ArchiveReceipt?
    @State private var restored: Set<String> = []
    @State private var homeReceipts: Set<String> = []
    @State private var failures: [String] = []
    @State private var archivedBytes: Int64 = 0
    @State private var folderCheck: FolderCheck?
    @State private var checkingFolder = false
    @State private var showPro = false
    @EnvironmentObject private var pro: ProStore

    private let accent = Brand.primary

    init(snapshot: ScanSnapshot?, selectedFiles: [URL] = []) {
        self.snapshot = snapshot
        _items = State(initialValue: selectedFiles.map {
            ArchiveItem(id: $0.absoluteString, name: $0.lastPathComponent, source: .file($0))
        })
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Make an archive copy", systemImage: "externaldrive.badge.plus")
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text("Copy full-resolution originals or files, then test a restore. Your source items stay where they are.")
                        .foregroundStyle(.secondary)
                    Label("TidyAway only adds copies to your archive. It never deletes or changes anything there, by design.",
                          systemImage: "lock.shield")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Brand.safe)
                        .accessibilityIdentifier("archive-write-only")
                }
                .padding(.vertical, 8)
            }
            if busy {
                Section { ProgressView(checkingSizes ? "Checking selected sizes…" : "Copying and verifying…") }
            }
            Group {
                destinationSection
                selectionSection
                if !items.isEmpty { reviewSection }
                if !receipts.isEmpty || !failures.isEmpty { resultsSection }
                if let restoreTarget { restoreSection(restoreTarget) }
            }
            .disabled(busy)
            if let message {
                Section { Text(message).accessibilityAddTraits(.updatesFrequently) }
            }
        }
        .tint(accent)
        .navigationTitle("Archive originals")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(busy)
        .sheet(isPresented: $showPro) {
            NavigationStack {
                ProUpgradeView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Not now") { showPro = false } }
                    }
            }
            .environmentObject(pro)
        }
        .onAppear { refreshArchivedBytes() }
        .sheet(isPresented: $showPlacePicker) {
            if let snapshot { PlacePickerSheet(place: $place, snapshot: snapshot) }
        }
        .onChange(of: snapshot?.date) {
            // A new scan can drop albums or places, so start the album and place choices fresh.
            albumID = nil
            place = nil
        }
        .fileImporter(isPresented: $showFiles,
                      allowedContentTypes: picker == .files ? [.data] : [.folder],
                      allowsMultipleSelection: picker == .files,
                      onCompletion: handlePicker)
        .onChange(of: photoSelection) { _, selection in addPhotos(selection) }
    }

    private var destinationSection: some View {
        Section("1. Connect an archive folder") {
            Picker("Storage location", selection: $destinationKind) {
                Text("Choose a destination").tag(nil as Destination?)
                ForEach(Destination.allCases, id: \.self) { kind in
                    Label(kind.rawValue, systemImage: kind.icon).tag(Optional(kind))
                }
            }
            .onChange(of: destinationKind) {
                destination = nil
                availableGB = ""
                archiveConsent = false
                folderCheck = nil
            }
            if let destinationKind {
                HStack(alignment: .top, spacing: 4) {
                    Text(destinationKind.detail).font(.footnote).foregroundStyle(.secondary)
                    if destinationKind == .drive {
                        InfoButton(title: "Which drive?",
                                   text: "Any drive you already have can work. No drive yet? A portable USB-C SSD formatted as ExFAT works best. Spinning hard drives may need their own power supply to run from an iPhone.")
                    }
                }
                Button { openPicker(.archive) } label: {
                    Label(destination.map { "Change folder (\($0.lastPathComponent))" } ?? "Choose archive folder in Files",
                          systemImage: "folder.badge.plus")
                }
                if checkingFolder {
                    ProgressView("Checking this folder…")
                } else if let folderCheck {
                    if let problem = folderCheck.problem {
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Brand.caution)
                            .accessibilityIdentifier("folder-problem")
                    } else {
                        Label(folderCheck.available.map { "Ready. \(formattedBytes($0)) free here." } ?? "Ready to save here.",
                              systemImage: "checkmark.circle")
                            .foregroundStyle(Brand.safe)
                            .accessibilityIdentifier("folder-ready")
                        if folderCheck.isFAT32 {
                            Text("This drive uses FAT32, which can't hold a single file over 4 GB. Long videos need an ExFAT drive.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                if destination != nil, folderCheck?.available == nil {
                    TextField("Available space shown by provider (GB, optional)", text: $availableGB)
                        .keyboardType(.decimalPad)
                        .onChange(of: availableGB) { archiveConsent = false }
                    Text("Files doesn’t supply a verified account quota. Use the available space shown by your provider for an estimate.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var selectionSection: some View {
        Section("2. Choose what to copy") {
            switch photoAccess {
            case .authorized, .limited:
                PhotosPicker(selection: $photoSelection, maxSelectionCount: 25, matching: .any(of: [.images, .videos]), photoLibrary: .shared()) {
                    Label("Pick photos or videos myself", systemImage: "photo.on.rectangle")
                }
            case .notDetermined:
                Button {
                    Task { photoAccess = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
                } label: {
                    Label("Allow Photos access to pick originals", systemImage: "photo.on.rectangle")
                }
            default:
                Text("Allow Photos access in Settings to pick originals, or choose an item from Files.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button { openPicker(.files) } label: {
                Label("Pick files myself", systemImage: "folder")
            }
            if let snapshot, !snapshot.includedCloudDownloads {
                Picker("Taken", selection: $age) {
                    ForEach(Age.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Picker("Size", selection: $sizeFloor) {
                    ForEach(SizeFloor.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Picker("Kind", selection: $kind) {
                    ForEach(ArchiveKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                if !pro.unlocked {
                    Button { showPro = true } label: {
                        LabeledContent {
                            Text("Pro").font(.caption.bold()).foregroundStyle(Brand.primary)
                        } label: {
                            Label("Choose by album or place", systemImage: "lock")
                        }
                    }
                    .accessibilityIdentifier("archive-filters-pro")
                } else if let albums = snapshot.albums {
                    if !albums.isEmpty {
                        Picker("Album", selection: $albumID) {
                            Text("Any album").tag(String?.none)
                            ForEach(albums) { Text($0.title).tag(Optional($0.id)) }
                        }
                    }
                    if snapshot.assets.contains(where: { $0.latitude != nil }) {
                        Button { showPlacePicker = true } label: {
                            LabeledContent {
                                Text(place == nil ? "Anywhere" : "Area on map")
                            } label: {
                                Label("Place", systemImage: "map")
                            }
                        }
                        .accessibilityIdentifier("archive-place")
                        if place != nil {
                            Button("Clear place") { place = nil }
                        }
                    }
                } else {
                    Text("Scan again to also choose by album or place.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button { showSuggestions(from: snapshot) } label: {
                    Label(kind == .videos ? "Show matching videos" : "Show matching photos", systemImage: "line.3.horizontal.decrease.circle")
                }
                Button {
                    kind = .videos
                    sizeFloor = .twentyFive
                    age = .any
                    albumID = nil
                    place = nil
                    showSuggestions(from: snapshot)
                } label: {
                    Label("Suggest large videos", systemImage: "film.stack")
                }
                .accessibilityIdentifier("archive-suggest-videos")
                if showSuggested {
                    let matchingBytes = suggested.compactMap { bytes(for: $0) }.reduce(Int64(0), +)
                    LabeledContent(kind == .videos ? "Matching videos" : "Matching photos", value: "\(suggested.count.formatted()) · \(formattedBytes(matchingBytes))")
                    if suggested.isEmpty {
                        Text("Nothing from your last scan matches. Try a wider choice.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Button("Add all \(suggested.count.formatted()) to the selection") {
                            for item in suggested { add(item) }
                        }
                        if suggested.count == Self.suggestionLimit {
                            Text("Showing the \(Self.suggestionLimit) largest matches. Archive these, then choose again for more.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(suggested) { item in
                        Button { toggle(item) } label: {
                            Label {
                                VStack(alignment: .leading) {
                                    Text(item.name)
                                    Text(item.sourceLabel).font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: items.contains { $0.id == item.id } ? "checkmark.circle.fill" : "plus.circle")
                            }
                        }
                    }
                }
            }
            Text("Photos supports JPEG and HEIC photos and single-file videos already on this iPhone. Live Photos, slo-mo and edited videos aren't supported yet. Use Files for documents. Suggestions leave out favorites.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var reviewSection: some View {
        Section("3. Review space and approve") {
            ForEach(items) { item in
                Button { toggle(item) } label: {
                    HStack {
                        if case .photo(let id, _) = item.source {
                            AssetThumbnail(assetID: id)
                        }
                        VStack(alignment: .leading) {
                            Text(item.name).foregroundStyle(.primary)
                            Text(item.sourceLabel).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "minus.circle").accessibilityHidden(true)
                    }
                }
                .accessibilityLabel("Remove \(item.name) from selection")
            }
            let unmeasured = items.filter { bytes(for: $0) == nil }.count
            let selectedBytes = items.compactMap { bytes(for: $0) }.reduce(Int64(0), +)
            let comparison = ArchiveCapacity(selected: selectedBytes, available: availableBytes)
            LabeledContent(unmeasured == 0 ? "Selected size" : "Known selected size", value: formattedBytes(selectedBytes))
            if unmeasured > 0 {
                Button("Check sizes of \(unmeasured) items", action: measureSelection)
            }
            if let available = comparison.available {
                LabeledContent("Available space you entered", value: formattedBytes(available))
            }
            if comparison.fits == false {
                Label("This selection exceeds the space entered. Remove items or choose a different folder.", systemImage: "exclamationmark.triangle")
            } else if unmeasured == 0, comparison.fits == true {
                Text("The selection fits the space entered. Your provider makes the final capacity check.")
            } else if destination != nil {
                Text(unmeasured > 0 && comparison.available != nil
                     ? "Check the remaining item sizes for a complete comparison, or try a small batch."
                     : "Capacity is unconfirmed. You can enter the available space shown by your provider or try a small batch.")
            }
            if !availableGB.isEmpty && availableBytes == nil {
                Text("Enter available space as a number in GB.").foregroundStyle(.secondary)
            }
            let allowance = ProStore.archiveAllowance(used: archivedBytes, selection: selectedBytes, unlocked: pro.unlocked)
            switch allowance {
            case .unlimited:
                EmptyView()
            case .fits(let left):
                Text("Free archive: \(formattedBytes(left)) of 5 GB left.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("archive-allowance")
            case .over(let left):
                VStack(alignment: .leading, spacing: 8) {
                    Text("This selection is \(formattedBytes(selectedBytes)). \(formattedBytes(left)) of your free 5 GB archive is left. Remove some items, or unlock Pro to archive without a limit.")
                    Button("See TidyAway Pro") { showPro = true }
                }
                .accessibilityIdentifier("archive-allowance")
            }
            if let destination {
                LabeledContent("Archive folder", value: destination.lastPathComponent)
                Toggle("I authorize copying these items to this folder. Files providers may download selected files and sync these copies. Source items stay where they are and this step frees no space.", isOn: $archiveConsent)
                Button("Copy and verify", action: beginCopy)
                    .fontWeight(.semibold)
                    .disabled(!archiveConsent || comparison.fits == false || (!availableGB.isEmpty && availableBytes == nil)
                              || { if case .over = allowance { return true } else { return false } }()
                              || folderCheck?.problem != nil || checkingFolder || !tooBigForDrive.isEmpty)
                if !tooBigForDrive.isEmpty {
                    Text("\(tooBigForDrive.count) selected \(tooBigForDrive.count == 1 ? "item is" : "items are") over 4 GB, too big for this FAT32 drive. Remove \(tooBigForDrive.count == 1 ? "it" : "them") or use an ExFAT drive.")
                        .font(.footnote).foregroundStyle(Brand.caution)
                }
            } else {
                Text("Choose an archive folder above to continue.")
            }
        }
    }

    private var availableBytes: Int64? {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        guard let gb = formatter.number(from: availableGB)?.doubleValue, gb >= 0, gb < 9_000_000_000 else { return nil }
        return Int64(gb * 1_000_000_000)
    }

    private func bytes(for item: ArchiveItem) -> Int64? {
        if case .photo(_, let expected?) = item.source { return expected.bytes }
        return measuredBytes[item.id]
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func measureSelection() {
        let selection = items.filter { bytes(for: $0) == nil }
        busy = true
        checkingSizes = true
        archiveConsent = false
        message = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                var sizes: [String: Int64] = [:]
                var photos: [String: ResourceFingerprint] = [:]
                let scanner = DuplicateScanner()
                for item in selection {
                    switch item.source {
                    case .photo(let id, _):
                        if let fingerprint = try? await scanner.archiveFingerprint(for: id) {
                            sizes[item.id] = fingerprint.bytes
                            photos[item.id] = fingerprint
                        }
                    case .file(let url):
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                            sizes[item.id] = Int64(size)
                        }
                    }
                }
                return (sizes, photos)
            }.value
            measuredBytes.merge(result.0) { _, new in new }
            checkedPhotos.merge(result.1) { _, new in new }
            if result.0.count < selection.count {
                message = "Some sizes couldn’t be read. Photos are checked without downloading iCloud originals."
            }
            checkingSizes = false
            busy = false
        }
    }

    private var resultsSection: some View {
        Section("Copy results") {
            ForEach(receipts) { receipt in
                VStack(alignment: .leading, spacing: 6) {
                    Label(receipt.url.lastPathComponent, systemImage: "checkmark.circle")
                    Text(restored.contains(receipt.id) ? "Restored bytes verified" : "Copied bytes verified")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Test restore") {
                        restoreTarget = receipt
                        restoreFolder = nil
                        restoreConsent = false
                        message = nil
                    }
                }
            }
            ForEach(failures.indices, id: \.self) { index in
                Label(failures[index], systemImage: "exclamationmark.circle")
            }
            if !receipts.isEmpty {
                Text("Verification checks the bytes this iPhone could read back. It cannot confirm provider sync. Keep this screen open to test a restore.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func restoreSection(_ receipt: ArchiveReceipt) -> some View {
        Section("Test restore") {
            Text(receipt.url.lastPathComponent)
            Button { openPicker(.restore) } label: {
                Label(restoreFolder.map { "Change folder (\($0.lastPathComponent))" } ?? "Choose a different restore folder", systemImage: "folder")
            }
            if let restoreFolder {
                Text(restoreFolder.path(percentEncoded: false))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Toggle("I authorize creating a test copy here. It uses storage and the folder’s provider may sync it. The archive copy stays in place.", isOn: $restoreConsent)
                Button("Restore and verify", action: beginRestore)
                    .fontWeight(.semibold)
                    .disabled(!restoreConsent)
            }
        }
    }

    private func openPicker(_ purpose: PickerPurpose) {
        picker = purpose
        showFiles = true
    }

    private func handlePicker(_ result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            switch picker {
            case .files:
                for url in urls {
                    let item = ArchiveItem(id: url.absoluteString, name: url.lastPathComponent, source: .file(url))
                    add(item)
                }
            case .archive:
                destination = urls.first
                availableGB = ""
                archiveConsent = false
                if let folder = urls.first { checkFolder(folder) }
            case .restore:
                restoreFolder = urls.first
                restoreConsent = false
            }
        } catch {
            message = "Could not open the selection. \(error.localizedDescription)"
        }
    }

    private func addPhotos(_ selection: [PhotosPickerItem]) {
        guard !selection.isEmpty else { return }
        var skipped = 0
        for photo in selection {
            guard let id = photo.itemIdentifier,
                  let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject,
                  let resource = VerifiedArchive.original(for: asset) else {
                skipped += 1
                continue
            }
            add(ArchiveItem(id: id, name: resource.originalFilename, source: .photo(id, expected: nil)))
        }
        message = skipped == 0 ? nil : "\(skipped.formatted()) selected items were unavailable with current Photos access or had an unsupported format. Run a local scan to check Photos access."
        photoSelection = []
    }

    private func showSuggestions(from snapshot: ScanSnapshot) {
        let filter = ArchiveSuggestionFilter(olderThanYears: age.years, minimumBytes: sizeFloor.bytes, kind: kind,
                                             albumID: albumID, place: place, limit: Self.suggestionLimit)
        let records = filter.matches(in: snapshot)
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: records.map(\.id), options: nil)
        var names: [String: String] = [:]
        assets.enumerateObjects { asset, _, _ in
            names[asset.localIdentifier] = VerifiedArchive.original(for: asset)?.originalFilename
        }
        suggested = records.compactMap { record -> ArchiveItem? in
            guard let name = names[record.id] else { return nil }
            return ArchiveItem(id: record.id, name: name, source: .photo(record.id, expected: record.resources.first))
        }
        showSuggested = true
    }

    private func add(_ item: ArchiveItem) {
        guard !items.contains(where: { $0.id == item.id }) else { return }
        items.append(item)
        archiveConsent = false
    }

    private func toggle(_ item: ArchiveItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items.remove(at: index)
            measuredBytes[item.id] = nil
            checkedPhotos[item.id] = nil
            archiveConsent = false
        } else {
            add(item)
        }
    }

    private func beginCopy() {
        guard !busy, archiveConsent, let destination, !items.isEmpty,
              availableGB.isEmpty || availableBytes != nil,
              folderCheck?.problem == nil, tooBigForDrive.isEmpty else { return }
        let selectedBytes = items.compactMap { bytes(for: $0) }.reduce(Int64(0), +)
        guard ArchiveCapacity(selected: selectedBytes, available: availableBytes).fits != false else { return }
        let home = destinationKind == .home
        let wifiCheck = wifi
        let selection = items.map { item in
            if case let .photo(id, nil) = item.source, let measured = checkedPhotos[item.id] {
                return ArchiveItem(id: item.id, name: item.name, source: .photo(id, expected: measured))
            }
            return item
        }
        archiveConsent = false
        guard let operation = authorize("archive copy", count: selection.count) else { return }
        busy = true
        message = nil
        restoreTarget = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                var successes: [ArchiveReceipt] = []
                var failures: [String] = []
                for item in selection {
                    do {
                        successes.append(try VerifiedArchive.copy(item, to: destination, wifi: home ? wifiCheck : nil))
                    }
                    catch { failures.append("\(item.name) — \(error.localizedDescription)") }
                }
                return (successes, failures)
            }.value
            let copied = Set(result.0.map(\.id))
            receipts.removeAll { copied.contains($0.id) }
            receipts.append(contentsOf: result.0)
            let bookmark = Self.bookmark(for: destination)
            let archivedAt = Date()
            try? InventoryStore.openDefault().saveArchived(result.0.map { receipt in
                ArchivedRecord(id: UUID().uuidString, name: receipt.url.lastPathComponent,
                               folderName: destination.lastPathComponent, bytes: receipt.fingerprint.bytes,
                               digest: receipt.fingerprint.digest, date: archivedAt,
                               viaHomeServer: home, folderBookmark: bookmark)
            })
            refreshArchivedBytes()
            homeReceipts.subtract(copied)
            if home { homeReceipts.formUnion(copied) }
            restored.subtract(copied)
            failures = result.1
            items.removeAll { copied.contains($0.id) }
            for id in copied {
                measuredBytes[id] = nil
                checkedPhotos[id] = nil
            }
            recordOutcome("Archive copy \(operation) completed. Verified \(copied.count) of \(selection.count) items.")
            busy = false
        }
    }

    private func beginRestore() {
        guard !busy, restoreConsent, let restoreTarget, let restoreFolder else { return }
        let home = homeReceipts.contains(restoreTarget.id)
        let wifiCheck = wifi
        restoreConsent = false
        guard let operation = authorize("archive test restore", count: 1) else { return }
        busy = true
        message = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try VerifiedArchive.restore(restoreTarget, to: restoreFolder, wifi: home ? wifiCheck : nil)
                }
            }.value
            switch result {
            case .success(let url):
                restored.insert(restoreTarget.id)
                message = "Restored and verified \(url.lastPathComponent) in \(restoreFolder.lastPathComponent). Open the copy in Files to confirm it opens as expected."
                recordOutcome("Archive test restore \(operation) verified.")
            case .failure(let error):
                message = "Restore failed. \(error.localizedDescription)"
                recordOutcome("Archive test restore \(operation) failed.")
            }
            busy = false
        }
    }

    /// Checks the chosen folder right away: format, read-only, free space, and a test write.
    private func checkFolder(_ folder: URL) {
        folderCheck = nil
        checkingFolder = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { FolderCheck.run(on: folder) }.value
            guard destination == folder else { return }
            folderCheck = result
            checkingFolder = false
            if let available = result.available, availableGB.isEmpty {
                let formatter = NumberFormatter()
                formatter.locale = locale
                formatter.numberStyle = .decimal
                formatter.maximumFractionDigits = 1
                availableGB = formatter.string(from: NSNumber(value: Double(available) / 1_000_000_000)) ?? ""
            }
        }
    }

    /// Items too big for a FAT32 drive.
    private var tooBigForDrive: [ArchiveItem] {
        guard folderCheck?.isFAT32 == true else { return [] }
        return items.filter { (bytes(for: $0) ?? 0) > FolderCheck.fat32FileLimit }
    }

    /// Everything archived so far counts toward the free 5 GB.
    private func refreshArchivedBytes() {
        archivedBytes = ((try? InventoryStore.openDefault().archived()) ?? []).reduce(0) { $0 + $1.bytes }
    }

    /// Lets the Archived tab reopen the folder later without asking the user to pick it again.
    private static func bookmark(for folder: URL) -> Data? {
        let active = folder.startAccessingSecurityScopedResource()
        defer { if active { folder.stopAccessingSecurityScopedResource() } }
        return try? folder.bookmarkData()
    }

    private func authorize(_ action: String, count: Int) -> UUID? {
        let operation = UUID()
        do {
            try InventoryStore.openDefault().log("Authorized \(action) (\(operation)), disclosure v1, \(count) items.")
            return operation
        } catch {
            message = "The app could not save your authorization. Try again."
            return nil
        }
    }

    private func recordOutcome(_ entry: String) {
        try? InventoryStore.openDefault().log(entry)
    }
}
