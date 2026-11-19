import SwiftUI

struct PhotoCopyOptionsView: View {
    var snapshot: ScanSnapshot? = nil
    private enum Option: String, CaseIterable, Identifiable {
        case optimize = "Keep smaller copies on my iPhone"
        case merge = "Review exact photo duplicates"
        case archive = "Archive a copy in another location"
        case documents = "Free space used by documents"

        var id: Self { self }

        var icon: String {
            switch self {
            case .optimize: "iphone"
            case .merge: "square.on.square"
            case .archive: "externaldrive"
            case .documents: "folder"
            }
        }

        var benefit: String {
            switch self {
            case .optimize: "Free phone space while browsing in Apple Photos."
            case .merge: "Find and compare exact matches in your Apple Photos library."
            case .archive: "Copy full-resolution originals and test a restore."
            case .documents: "Remove offline downloads while keeping cloud files."
            }
        }
    }

    private let slate = Color(red: 0.19, green: 0.32, blue: 0.44)
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Where should your originals live?")
                    .font(.title.bold())
                    .accessibilityAddTraits(.isHeader)
                ForEach(Option.allCases) { option in
                    NavigationLink {
                        if option == .archive { PhotoArchiveView(snapshot: snapshot) } else { details(option) }
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: option.icon)
                                .font(.title2)
                                .frame(width: 32)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(option.rawValue).font(.headline)
                                Text(option.benefit).font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 6)
                            Image(systemName: "chevron.forward").accessibilityHidden(true)
                        }
                        .padding(16)
                        .foregroundStyle(.primary)
                        .background(colorScheme == .dark ? Color(uiColor: .secondarySystemBackground) :
                            Color(red: 0.88, green: 0.92, blue: 0.96), in: RoundedRectangle(cornerRadius: 17))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 540, alignment: .leading)
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .background(colorScheme == .dark ? Color(uiColor: .systemBackground) : Color(red: 0.99, green: 0.98, blue: 0.96))
        .navigationTitle("Decide which copies to keep")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func details(_ option: Option) -> some View {
        List {
            switch option {
            case .optimize:
                Section("What stays where") {
                    LabeledContent("Full-resolution originals", value: "iCloud Photos")
                    LabeledContent("Smaller copies", value: "Managed by Apple on this iPhone")
                    Text("iPhone and iCloud Photos are one synced library. Deleting an item in Photos also removes it from synced devices. Storage savings depend on what Apple keeps locally.")
                }
                Section("Actions available here") {
                    NavigationLink("Archive selected originals") { PhotoArchiveView(snapshot: snapshot) }
                    NavigationLink("Remove a synced document download") { CloudDownloadRemovalView() }
                    Link("Apple Photos storage settings help", destination: URL(string: "https://support.apple.com/en-us/105061")!)
                }
            case .merge:
                Section {
                    if let snapshot {
                        NavigationLink("Review exact matches") { DuplicateResultsView(snapshot: snapshot) }
                    } else {
                        NavigationLink("Scan for exact duplicates") { ArchiveDuplicateReview() }
                    }
                    Text("Merging in Apple Photos is managed by Apple and can affect the synced library.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            case .archive: EmptyView()
            case .documents:
                Section("What would you like to do?") {
                    NavigationLink("Remove a synced iCloud Drive download") { CloudDownloadRemovalView() }
                    NavigationLink("Find large files") { SelectedFilesAnalysisView() }
                    NavigationLink("Archive files to another folder") { PhotoArchiveView(snapshot: snapshot) }
                    Text("Offline copies from other providers are managed by those providers. You can analyze or archive their available files here.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .tint(slate)
        .navigationTitle(option.rawValue)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ArchiveDuplicateReview: View {
    @StateObject private var model = DashboardModel()

    var body: some View {
        Group {
            if let snapshot = model.snapshot {
                DuplicateResultsView(snapshot: snapshot)
            } else {
                List {
                    if model.isScanning {
                        ProgressView("Checking locally available originals…")
                        Button("Cancel scan") { model.cancel() }
                    } else {
                        Button("Scan local photos", action: model.startDuplicateScan)
                    }
                    if let status = model.duplicateScanStatus { Text(status) }
                    if let error = model.errorMessage { Text(error) }
                }
                .navigationTitle("Review exact duplicates")
            }
        }
        .onDisappear { model.cancel() }
    }
}
