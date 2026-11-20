import SwiftUI
import UniformTypeIdentifiers

struct SelectedFilesAnalysisView: View {
    private struct FileEntry: Identifiable, Sendable {
        let id: URL
        let name: String
        let bytes: Int64?

        init(url: URL) {
            id = url
            let needsRelease = url.startAccessingSecurityScopedResource()
            defer { if needsRelease { url.stopAccessingSecurityScopedResource() } }
            let metadata = try? url.resourceValues(forKeys: [.localizedNameKey, .isRegularFileKey, .fileSizeKey])
            name = metadata?.localizedName ?? url.lastPathComponent
            bytes = metadata?.isRegularFile == true ? metadata?.fileSize.map(Int64.init) : nil
        }
    }

    @State private var selecting = false
    @State private var analyzing = false
    @State private var entries: [FileEntry] = []
    @State private var error: String?

    var body: some View {
        List {
            Section {
                Button {
                    selecting = true
                } label: {
                    Label(entries.isEmpty ? "Choose files to analyze" : "Choose another selection", systemImage: "folder")
                        .frame(minHeight: 44)
                }
                .disabled(analyzing)
                Text("Choose individual files from locations available in the Files picker. The app checks reported sizes for this selection. Your provider controls which files are available to select.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if analyzing {
                ProgressView("Checking file sizes…")
            }
            if let error { Text(error).foregroundStyle(.secondary) }
            if !entries.isEmpty {
                Section("Your selection") {
                    let known = entries.compactMap(\.bytes)
                    LabeledContent("Selected files", value: entries.count.formatted())
                    if !known.isEmpty {
                        LabeledContent("Combined known size", value: formatted(known.reduce(0, +)))
                    }
                    if known.count < entries.count {
                        LabeledContent("Size unavailable", value: (entries.count - known.count).formatted())
                    }
                }
                Section("Largest files first") {
                    ForEach(entries) { entry in
                        LabeledContent(entry.name, value: entry.bytes.map(formatted) ?? "Size unknown")
                    }
                }
                Section {
                    NavigationLink("Remove a synced iCloud Drive download") { CloudDownloadRemovalView() }
                    NavigationLink("Archive selected files") { PhotoArchiveView(snapshot: nil, selectedFiles: entries.map(\.id)) }
                } footer: {
                    Text("A listed size doesn’t confirm how much space a file uses on this iPhone or whether a second copy exists.")
                }
            }
        }
        .navigationTitle("Analyze selected files")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $selecting, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                guard !urls.isEmpty else { return }
                analyzing = true
                error = nil
                entries = []
                Task {
                    entries = await Task.detached(priority: .userInitiated) {
                        Set(urls).map { FileEntry(url: $0) }.sorted {
                            if $0.bytes == $1.bytes { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                            return ($0.bytes ?? -1) > ($1.bytes ?? -1)
                        }
                    }.value
                    analyzing = false
                }
            case .failure(let failure):
                guard (failure as NSError).code != NSUserCancelledError else { return }
                error = "Couldn’t open the selection. Try choosing the files again."
            }
        }
    }

    private func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
