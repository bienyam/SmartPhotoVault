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

/// Lists verified archive copies and restores one after sign-off.
struct ArchivedView: View {
    @State private var records: [ArchivedRecord] = []
    @State private var selected: ArchivedRecord?
    @State private var restoreFolder: URL?
    @State private var restoreConsent = false
    @State private var showFolders = false
    @State private var busy = false
    @State private var message: String?
    @State private var wifi = ArchiveWiFi()

    private let accent = Brand.primary

    var body: some View {
        List {
            if records.isEmpty {
                Section {
                    Text("Nothing archived yet.")
                        .font(.headline)
                    Text("Copies you make in the Archive tab appear here, so you can find them and restore one when you need it.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    Text("These copies were verified when they were made. Choose one to restore a copy of it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Archived items") {
                    ForEach(records) { record in
                        Button { select(record) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(record.name).foregroundStyle(.primary)
                                    Text("\(record.folderName) · \(ByteCountFormatter.string(fromByteCount: record.bytes, countStyle: .file)) · \(record.date.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: selected?.id == record.id ? "checkmark.circle.fill" : "arrow.uturn.backward.circle")
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                }
                .disabled(busy)
            }
            if let selected {
                restoreSection(selected)
            }
            if busy {
                Section { ProgressView("Restoring and verifying…") }
            }
            if let message {
                Section { Text(message).accessibilityAddTraits(.updatesFrequently) }
            }
        }
        .tint(accent)
        .navigationTitle("Archived")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $showFolders, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url):
                restoreFolder = url
                restoreConsent = false
            case .failure(let error):
                message = "Could not open the folder. \(error.localizedDescription)"
            }
        }
        .onAppear(perform: reload)
    }

    private func restoreSection(_ record: ArchivedRecord) -> some View {
        Section("Restore a copy") {
            Text(record.name)
            Button { showFolders = true } label: {
                Label(restoreFolder.map { "Change folder (\($0.lastPathComponent))" } ?? "Choose where to restore it", systemImage: "folder")
            }
            if restoreFolder != nil {
                Toggle("I authorize creating a copy here. It uses storage and the folder’s provider may sync it. The archive copy stays in place.", isOn: $restoreConsent)
                Button("Restore and verify") { beginRestore(record) }
                    .fontWeight(.semibold)
                    .disabled(!restoreConsent)
            }
        }
        .disabled(busy)
    }

    /// Downloads the archived copy from Google Drive, checks it against the fingerprint taken when it
    /// was archived, and saves it as a new file in the chosen folder. Nothing in Drive changes.
    private func restoreFromDrive(_ record: ArchivedRecord, fileID: String, to folder: URL) {
        let operation = UUID()
        do {
            try InventoryStore.openDefault().log("Authorized archive restore from Google Drive (\(operation)), disclosure v1, 1 items.")
        } catch {
            message = "The app could not save your authorization. Try again."
            return
        }
        busy = true
        message = nil
        Task {
            do {
                let token = try await GoogleDriveAccount.shared.accessToken()
                let downloaded = try await GoogleDriveClient.download(fileID, token: token)
                defer { try? FileManager.default.removeItem(at: downloaded.url) }
                guard downloaded.digest == record.digest.lowercased() else { throw GoogleDriveError.verification }
                let scoped = folder.startAccessingSecurityScopedResource()
                defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
                let destination = folder.appendingPathComponent(record.name)
                guard !FileManager.default.fileExists(atPath: destination.path) else { throw ArchiveError.conflict }
                try FileManager.default.copyItem(at: downloaded.url, to: destination)
                guard try GoogleDriveClient.sha256(of: destination) == record.digest.lowercased() else {
                    try? FileManager.default.removeItem(at: destination)
                    throw ArchiveError.verification
                }
                message = "Restored and verified \(record.name) in \(folder.lastPathComponent)."
                try? InventoryStore.openDefault().log("Archive restore \(operation) verified.")
            } catch {
                message = "Restore failed. \(error.localizedDescription)"
                try? InventoryStore.openDefault().log("Archive restore \(operation) failed.")
            }
            busy = false
        }
    }

    private func reload() {
        records = (try? InventoryStore.openDefault().archived()) ?? []
    }

    private func select(_ record: ArchivedRecord) {
        selected = record
        restoreFolder = nil
        restoreConsent = false
        message = nil
    }

    private func beginRestore(_ record: ArchivedRecord) {
        guard !busy, restoreConsent, let restoreFolder else { return }
        restoreConsent = false
        if let fileID = record.driveFileID {
            restoreFromDrive(record, fileID: fileID, to: restoreFolder)
            return
        }
        var stale = false
        guard let bookmark = record.folderBookmark,
              let folder = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale) else {
            message = "TidyAway can no longer open that archive folder. Your copy is still in \(record.folderName): open it in Files to find \(record.name)."
            return
        }
        let receipt = ArchiveReceipt(id: record.id, url: folder.appendingPathComponent(record.name), folder: folder,
                                     fingerprint: ArchiveFingerprint(bytes: record.bytes, digest: record.digest))
        let wifiCheck: ArchiveWiFi? = record.viaHomeServer ? wifi : nil
        let operation = UUID()
        do {
            try InventoryStore.openDefault().log("Authorized archive restore (\(operation)), disclosure v1, 1 items.")
        } catch {
            message = "The app could not save your authorization. Try again."
            return
        }
        busy = true
        message = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try VerifiedArchive.restore(receipt, to: restoreFolder, wifi: wifiCheck) }
            }.value
            switch result {
            case .success(let url):
                message = "Restored and verified \(url.lastPathComponent) in \(restoreFolder.lastPathComponent)."
                try? InventoryStore.openDefault().log("Archive restore \(operation) verified.")
            case .failure(let error):
                message = "Restore failed. \(error.localizedDescription)"
                try? InventoryStore.openDefault().log("Archive restore \(operation) failed.")
            }
            busy = false
        }
    }
}
