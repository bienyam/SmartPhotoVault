import SwiftUI
import Photos

private enum DashboardDestination {
    case inventory, duplicates, help

    var title: String {
        switch self {
        case .inventory: "Apple Photos inventory"
        case .duplicates: "Find duplicates"
        case .help: "Help and privacy"
        }
    }
}

struct DashboardView: View {
    @StateObject private var model = DashboardModel()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    private let slate = Color(red: 0.19, green: 0.32, blue: 0.44)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Photos & storage")
                            .font(.largeTitle.bold())
                            .accessibilityAddTraits(.isHeader)
                        Image("PorcelainHero")
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: 170)
                            .accessibilityHidden(true)
                    }
                    .padding(18)
                    .background(.linearGradient(
                        colors: colorScheme == .dark ? [slate, .clear] : [Color(red: 0.80, green: 0.87, blue: 0.94), .clear],
                        startPoint: .top, endPoint: .bottom
                    ), in: RoundedRectangle(cornerRadius: 24))

                    NavigationLink {
                        PhotoDetailsView(model: model, destination: .inventory)
                    } label: {
                        action("Check my photos", icon: "photo", prominent: true)
                    }
                    NavigationLink {
                        PhotoDetailsView(model: model, destination: .duplicates)
                    } label: {
                        action("Find duplicates", icon: "square.on.square")
                    }
                    NavigationLink {
                        StorageGuideView()
                    } label: {
                        action("Analyze storage & cost", icon: "internaldrive")
                    }
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
            .background(colorScheme == .dark ? Color(uiColor: .systemBackground) : Color(red: 0.99, green: 0.98, blue: 0.96))
            .navigationTitle("SmartPhotoVault")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        PhotoDetailsView(model: model, destination: .help)
                    } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .accessibilityLabel("Help and privacy")
                }
            }
            .task {
                if ProcessInfo.processInfo.arguments.contains("--demo") { model.showDemo() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { model.refreshAuthorization() }
            }
        }
        .tint(colorScheme == .dark ? Color(red: 0.69, green: 0.82, blue: 0.95) : slate)
    }

    private func action(_ title: String, icon: String, prominent: Bool = false) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").accessibilityHidden(true)
        }
        .font(.headline)
        .foregroundStyle(prominent ? Color.white : Color.primary)
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
        .frame(minHeight: 56)
        .background(
            prominent ? slate : (colorScheme == .dark ? Color(uiColor: .secondarySystemBackground) : Color(red: 0.88, green: 0.92, blue: 0.96)),
            in: RoundedRectangle(cornerRadius: 17)
        )
    }
}

private struct PhotoDetailsView: View {
    @ObservedObject var model: DashboardModel
    let destination: DashboardDestination
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    @State private var showsDownloadConsent = false
    @State private var acknowledgesDownloads = false

    private var porcelain: Color {
        colorScheme == .dark ? Color(red: 0.08, green: 0.13, blue: 0.19) : Color(red: 0.99, green: 0.98, blue: 0.96)
    }

    private var slate: Color { Color(red: 0.19, green: 0.32, blue: 0.44) }

    var body: some View {
        List {
            switch destination {
            case .inventory:
                Section("Apple Photos inventory") {
                    if model.isScanning {
                        ProgressView("Counting accessible photos and videos…")
                    } else if let inventory = model.inventory {
                        LabeledContent("Photos", value: inventory.photos.formatted())
                        LabeledContent("Videos", value: inventory.videos.formatted())
                        LabeledContent("Favorites", value: inventory.favorites.formatted())
                    } else {
                        Text("Scan to count the photos and videos you allow this app to see.")
                    }
                    Button(model.inventory == nil ? "Scan Apple Photos" : "Rescan Apple Photos") {
                        model.startMetadataScan()
                    }
                    .disabled(model.isScanning)
                    if model.authorization == .limited {
                        Text("Limited access: counts cover only your selected items.").foregroundStyle(.orange)
                    }
                    if model.authorization == .denied || model.authorization == .restricted {
                        Text("Photo access is unavailable. You can review access in Settings; device restrictions may prevent changes.")
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                    }
                }
            case .duplicates:
                Section("Exact duplicate scan") {
                    if model.isScanning {
                        ProgressView(value: Double(model.completed), total: Double(max(model.total, 1)))
                        Text("Checked \(model.completed) of \(model.total) assets")
                        Button("Cancel scan", role: .cancel) { model.cancel() }
                        Text("Cancellation completes when the current resource finishes reading.").font(.footnote)
                    } else {
                        Button("Find exact duplicates") { model.startDuplicateScan() }
                        Button("Explore sample results") { model.showDemo() }
                        Button("Scan with iCloud downloads") {
                            acknowledgesDownloads = false
                            showsDownloadConsent = true
                        }
                    }
                    if let error = model.errorMessage {
                        Text(error).foregroundStyle(.red).accessibilityLabel("Error: \(error)")
                    }
                    if let snapshot = model.snapshot {
                        if model.isDemo { Label("Sample data — not your photo library", systemImage: "testtube.2") }
                        Text("Scanned \(snapshot.date.formatted())").font(.footnote)
                        if snapshot.limitedAccess { Text("Only selected photos are included.").foregroundStyle(.orange) }
                        LabeledContent("Assets inventoried", value: snapshot.assets.count.formatted())
                        LabeledContent("Fully hashed at scan time", value: snapshot.verifiedCount.formatted())
                        LabeledContent("Unverified or unreadable", value: (snapshot.assets.count - snapshot.verifiedCount).formatted())
                        LabeledContent("Exact duplicate groups", value: snapshot.groups.count.formatted())
                        LabeledContent("Extra duplicate resource bytes (estimate)", value: ByteCountFormatter.string(fromByteCount: snapshot.candidateBytes, countStyle: .file))
                        Text("Estimated matching resource bytes, not guaranteed recoverable device space. No cleanup is available. Results describe the library at scan time; rescan after library changes.")
                            .font(.footnote).foregroundStyle(.secondary)
                        NavigationLink("Review duplicate groups") { DuplicateResultsView(snapshot: snapshot) }
                        NavigationLink("Review unverified assets") {
                            List(snapshot.assets.filter { $0.fingerprint == nil }) { asset in
                                VStack(alignment: .leading) {
                                    Text(asset.filename)
                                    Text(asset.issue ?? "No complete resource evidence").font(.footnote).foregroundStyle(.secondary)
                                }
                            }.navigationTitle("Unverified assets")
                        }
                    }
                }
            case .help:
                Section("Activity") {
                    NavigationLink("View local activity log") {
                        List(model.activity) { entry in
                            VStack(alignment: .leading) {
                                Text(entry.message)
                                Text(entry.date.formatted()).font(.caption).foregroundStyle(.secondary)
                            }
                        }.navigationTitle("Activity log")
                    }
                }
                Section("About") {
                    NavigationLink("Privacy Policy") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                Text("SmartPhotoVault reads the Apple Photos items you authorize. Scanning and exact duplicate matching run on your device.")
                                Text("The app stores the latest completed inventory and its activity log locally. The inventory can include Photos identifiers, file names, dates, favorite status, resource sizes and hashes. The app does not transmit this information to the developer or include advertising or analytics.")
                                Text("If you authorize iCloud resource downloads for a scan, Apple Photos may retrieve originals from your iCloud library. Your authorization is recorded in the local activity log. SmartPhotoVault does not upload, edit or delete your photos.")
                                Text("You can change Photos access in Settings. To remove the local inventory and activity log from this device, delete the app.")
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                        }
                        .navigationTitle("Privacy Policy")
                    }
                }
            }
        }
        .buttonStyle(.borderless)
        .scrollContentBackground(.hidden)
        .background(porcelain)
        .tint(colorScheme == .dark ? Color(red: 0.69, green: 0.82, blue: 0.95) : slate)
        .navigationTitle(destination.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsDownloadConsent) {
            NavigationStack {
                List {
                    Text("Apple Photos may download full-resolution originals from iCloud for this scan. This can use mobile data and temporary storage on your iPhone.")
                    Button {
                        acknowledgesDownloads.toggle()
                    } label: {
                        Label(
                            "I understand and authorize downloads for this scan",
                            systemImage: acknowledgesDownloads ? "checkmark.square.fill" : "square"
                        )
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .accessibilityAddTraits(acknowledgesDownloads ? .isSelected : [])
                    Button("Authorize and start scan") {
                        guard acknowledgesDownloads else { return }
                        showsDownloadConsent = false
                        model.startDuplicateScan(allowCloudDownloads: true)
                    }
                    .disabled(!acknowledgesDownloads)
                }
                .navigationTitle("Scan with iCloud downloads")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showsDownloadConsent = false }
                    }
                }
            }
        }
    }
}

struct DuplicateResultsView: View {
    let snapshot: ScanSnapshot
    var body: some View {
        List {
            Section {
                Text("All resource hashes and resource types must match. Favorites appear first for review. Keep all desired destination copies. No deletion actions are available.")
                    .font(.footnote)
                Text("Scan from \(snapshot.date.formatted()). Rescan after changing your library.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if snapshot.groups.isEmpty {
                Text("No exact duplicates found among fully readable assets. Unverified assets were excluded.")
            }
            ForEach(Array(snapshot.groups.enumerated()), id: \.element.id) { index, group in
                Section("Group \(index + 1) · \(group.assets.count) matching assets") {
                    ForEach(group.assets) { asset in
                        HStack(alignment: .top, spacing: 12) {
                            AssetThumbnail(assetID: asset.id)
                            VStack(alignment: .leading, spacing: 4) {
                                Label(asset.filename, systemImage: asset.favorite ? "heart.fill" : "photo")
                                if asset.favorite { Text("Favorite — preserve").font(.caption).foregroundStyle(.orange) }
                                Text("\(asset.resources.count) resources · \(ByteCountFormatter.string(fromByteCount: asset.bytes, countStyle: .file))")
                                    .font(.caption).foregroundStyle(.secondary)
                                if let date = asset.createdAt { Text(date.formatted()).font(.caption) }
                            }
                        }
                    }
                }
            }
        }.navigationTitle("Exact duplicates")
    }
}

