import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct PhotoArchiveView: View {
    let snapshot: ScanSnapshot?

    private enum Filter: String, CaseIterable {
        case large = "Largest photos"
        case old = "Photos over two years old"
    }

    private enum PickerPurpose {
        case files, archive, restore
    }

    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var items: [ArchiveItem] = []
    @State private var destination: URL?
    @State private var restoreFolder: URL?
    @State private var picker: PickerPurpose = .files
    @State private var showFiles = false
    @State private var filter: Filter?
    @State private var suggested: [ArchiveItem] = []
    @State private var archiveConsent = false
    @State private var restoreConsent = false
    @State private var busy = false
    @State private var message: String?
    @State private var receipts: [ArchiveReceipt] = []
    @State private var restoreTarget: ArchiveReceipt?
    @State private var restored: Set<String> = []
    @State private var failures: [String] = []

    private let blue = Color(red: 0.22, green: 0.40, blue: 0.59)

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Make an archive copy", systemImage: "externaldrive.badge.plus")
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text("Copy full-resolution originals or files, then test a restore. Your source items stay where they are.")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }
            if busy {
                Section { ProgressView("Copying and verifying…") }
            }
            Group {
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
        .tint(blue)
        .navigationTitle("Archive originals")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(busy)
        .fileImporter(isPresented: $showFiles,
                      allowedContentTypes: picker == .files ? [.data] : [.folder],
                      allowsMultipleSelection: picker == .files,
                      onCompletion: handlePicker)
        .onChange(of: photoSelection) { _, selection in addPhotos(selection) }
    }

    private var selectionSection: some View {
        Section("Choose what to copy") {
            PhotosPicker(selection: $photoSelection, maxSelectionCount: 25, matching: .images, photoLibrary: .shared()) {
                Label("Pick photos myself", systemImage: "photo.on.rectangle")
            }
            Button { openPicker(.files) } label: {
                Label("Pick files myself", systemImage: "folder")
            }
            if let snapshot, !snapshot.includedCloudDownloads {
                ForEach(Filter.allCases, id: \.self) { option in
                    Button { showSuggestions(option, from: snapshot) } label: {
                        Label(option.rawValue, systemImage: option == .large ? "arrow.down.to.line" : "calendar")
                    }
                }
                if let filter {
                    LabeledContent(filter.rawValue, value: suggested.count.formatted())
                    ForEach(suggested) { item in
                        Button { toggle(item) } label: {
                            Label(item.name, systemImage: items.contains { $0.id == item.id } ? "checkmark.circle.fill" : "plus.circle")
                        }
                    }
                }
            }
            Text("Photos supports single-resource JPEG and HEIC originals readable on this iPhone. Use Files for selected videos or documents. Photos suggestions leave out favorites.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var reviewSection: some View {
        Section("Review your copy") {
            ForEach(items) { item in
                Button { toggle(item) } label: {
                    HStack {
                        Text(item.name).foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "minus.circle").accessibilityHidden(true)
                    }
                }
                .accessibilityLabel("Remove \(item.name) from selection")
            }
            Button { openPicker(.archive) } label: {
                Label(destination.map { "Change folder (\($0.lastPathComponent))" } ?? "Choose archive folder", systemImage: "folder.badge.plus")
            }
            if let destination {
                Text(destination.path(percentEncoded: false))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Toggle("I authorize copying these items to this folder. The Files provider may sync them to its account. Source items stay where they are and this step frees no space.", isOn: $archiveConsent)
                Button("Copy and verify", action: beginCopy)
                    .fontWeight(.semibold)
                    .disabled(!archiveConsent)
            }
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
                archiveConsent = false
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
        message = skipped == 0 ? nil : "\(skipped.formatted()) selected photos were unavailable with current Photos access or had an unsupported format. Run a local scan to check Photos access."
        photoSelection = []
    }

    private func showSuggestions(_ option: Filter, from snapshot: ScanSnapshot) {
        let cutoff = Calendar.current.date(byAdding: .year, value: -2, to: .now) ?? .distantPast
        let records = snapshot.assets.filter { record in
            record.issue == nil && !record.favorite && record.mediaType == PHAssetMediaType.image.rawValue &&
                record.resources.count == 1 && record.resources.first?.type == PHAssetResourceType.photo.rawValue &&
                (option == .large || (record.createdAt.map { $0 < cutoff } ?? false))
        }.sorted { left, right in
            if option == .old { return (left.createdAt ?? .distantFuture) < (right.createdAt ?? .distantFuture) }
            return left.bytes > right.bytes
        }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: records.map(\.id), options: nil)
        var names: [String: String] = [:]
        assets.enumerateObjects { asset, _, _ in
            names[asset.localIdentifier] = VerifiedArchive.original(for: asset)?.originalFilename
        }
        suggested = records.lazy.compactMap { record -> ArchiveItem? in
            guard let name = names[record.id] else { return nil }
            return ArchiveItem(id: record.id, name: name, source: .photo(record.id, expected: record.resources.first))
        }.prefix(20).map { $0 }
        filter = option
    }

    private func add(_ item: ArchiveItem) {
        guard !items.contains(where: { $0.id == item.id }) else { return }
        items.append(item)
        archiveConsent = false
    }

    private func toggle(_ item: ArchiveItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items.remove(at: index)
            archiveConsent = false
        } else {
            add(item)
        }
    }

    private func beginCopy() {
        guard !busy, archiveConsent, let destination else { return }
        let selection = items
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
                    do { successes.append(try VerifiedArchive.copy(item, to: destination)) }
                    catch { failures.append("\(item.name) — \(error.localizedDescription)") }
                }
                return (successes, failures)
            }.value
            let copied = Set(result.0.map(\.id))
            receipts.removeAll { copied.contains($0.id) }
            receipts.append(contentsOf: result.0)
            restored.subtract(copied)
            failures = result.1
            items.removeAll { copied.contains($0.id) }
            recordOutcome("Archive copy \(operation) completed. Verified \(copied.count) of \(selection.count) items.")
            busy = false
        }
    }

    private func beginRestore() {
        guard !busy, restoreConsent, let restoreTarget, let restoreFolder else { return }
        restoreConsent = false
        guard let operation = authorize("archive test restore", count: 1) else { return }
        busy = true
        message = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try VerifiedArchive.restore(restoreTarget, to: restoreFolder) }
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
