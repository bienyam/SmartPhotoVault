import SwiftUI
import UniformTypeIdentifiers

struct CloudDownloadRemovalPlan: Equatable, Sendable {
    let url: URL
    let name: String
    let size: Int64
    let modifiedAt: Date

    enum CheckError: LocalizedError {
        case ineligible, changed

        var errorDescription: String? {
            switch self {
            case .ineligible:
                "Choose a downloaded iCloud Drive file whose current version has finished syncing. Other providers, local-only files, and files with pending changes are unavailable for this action."
            case .changed:
                "The file changed after review. Choose it again to review the current version."
            }
        }
    }

    static func inspect(_ url: URL) throws -> Self {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        return try inspectAccessibleURL(url)
    }

    private static func inspectAccessibleURL(_ url: URL) throws -> Self {
        var refreshed = url
        refreshed.removeAllCachedResourceValues()
        let values = try refreshed.resourceValues(forKeys: [
            .localizedNameKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
            .isUbiquitousItemKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey,
            .ubiquitousItemHasUnresolvedConflictsKey, .ubiquitousItemDownloadingStatusKey
        ])
        guard values.isRegularFile == true, values.isSymbolicLink == false,
              values.isUbiquitousItem == true, values.ubiquitousItemIsUploaded == true,
              values.ubiquitousItemIsUploading == false, values.ubiquitousItemHasUnresolvedConflicts == false,
              values.ubiquitousItemDownloadingStatus == .current,
              let size = values.fileSize, size >= 0, let date = values.contentModificationDate else {
            throw CheckError.ineligible
        }
        return Self(url: url, name: values.localizedName ?? url.lastPathComponent, size: Int64(size), modifiedAt: date)
    }

    func removeDownload() throws {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let current = try Self.inspectAccessibleURL(url)
        guard current == self else { throw CheckError.changed }
        try FileManager.default.evictUbiquitousItem(at: url)
    }
}

struct CloudDownloadRemovalView: View {
    @State private var selecting = false
    @State private var busy = false
    @State private var confirms = false
    @State private var plan: CloudDownloadRemovalPlan?
    @State private var outcome: String?

    var body: some View {
        List {
            Section {
                Button("Choose an iCloud Drive file") { selecting = true }
                Text("Free phone space by removing a synced file’s downloaded copy. You can download the file again from iCloud Drive when you need it.")
                    .foregroundStyle(.secondary)
            }
            if let plan {
                Section("Review this download") {
                    LabeledContent("Selected file", value: plan.name)
                    LabeledContent("File size", value: ByteCountFormatter.string(fromByteCount: plan.size, countStyle: .file))
                    LabeledContent("Original stays in", value: "iCloud Drive")
                    Text("This file will need an internet connection to open again on this iPhone. The file size is not a promise of how much space iOS will reclaim.")
                    Toggle("I understand and authorize removing this iPhone download", isOn: $confirms)
                    Button("Remove this download") { authorize(plan) }
                        .disabled(!confirms)
                    Button("Cancel review", role: .cancel) {
                        self.plan = nil
                        confirms = false
                    }
                }
            }
            if busy { ProgressView("Checking iCloud Drive…") }
            if let outcome { Text(outcome) }
        }
        .disabled(busy)
        .navigationTitle("Remove a file download")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $selecting, allowedContentTypes: [.data]) { result in
            if case .success(let url) = result { inspect(url) }
        }
    }

    private func inspect(_ url: URL) {
        busy = true
        plan = nil
        confirms = false
        outcome = nil
        Task {
            defer { busy = false }
            do {
                plan = try await Task.detached(priority: .userInitiated) {
                    try CloudDownloadRemovalPlan.inspect(url)
                }.value
            } catch {
                outcome = error.localizedDescription
            }
        }
    }

    private func authorize(_ approved: CloudDownloadRemovalPlan) {
        guard confirms, !busy, plan == approved else { return }
        busy = true
        plan = nil
        confirms = false
        outcome = nil
        Task {
            defer { busy = false }
            let store: InventoryStore
            let operation = UUID().uuidString
            do {
                store = try InventoryStore.openDefault()
                try store.log("Authorized iCloud Drive local download removal (\(operation)). Disclosure v1: iCloud file retained, internet required to reopen. Selected size: \(approved.size) bytes.")
            } catch {
                outcome = "Couldn’t record your authorization. The download was kept."
                return
            }
            do {
                try await Task.detached(priority: .userInitiated) { try approved.removeDownload() }.value
                outcome = "iCloud Drive accepted the request to remove this download. You can download it again from Files."
                try? store.log("iCloud Drive accepted local download removal (\(operation)).")
            } catch {
                outcome = "Couldn’t remove the download. \(error.localizedDescription)"
                try? store.log("iCloud Drive local download removal failed (\(operation)).")
            }
        }
    }
}
