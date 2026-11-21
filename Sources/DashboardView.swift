import SwiftUI
import Photos

enum DashboardDestination {
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
    @ObservedObject var model: DashboardModel
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
                        Text("Your photos are safe. Nothing is removed until you confirm it.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
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
                        StorageGuideView(snapshot: model.isDemo ? nil : model.snapshot)
                    } label: {
                        action("Analyze storage & cost", icon: "internaldrive")
                    }
                    NavigationLink {
                        ProUpgradeView()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "sparkles").accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("TidyAway Pro").font(.subheadline.weight(.semibold))
                                Text("One-time unlock. Never a subscription.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
                        }
                        .foregroundStyle(Color.primary)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(RoundedRectangle(cornerRadius: 17).stroke(Color.secondary.opacity(0.25), lineWidth: 1))
                    }
                    .accessibilityIdentifier("home-pro")
                    .padding(.top, 8)
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
            .background(colorScheme == .dark ? Color(uiColor: .systemBackground) : Color(red: 0.99, green: 0.98, blue: 0.96))
            .navigationTitle("TidyAway")
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

struct PhotoDetailsView: View {
    @ObservedObject var model: DashboardModel
    let destination: DashboardDestination
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme

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
                        if let screenshots = inventory.screenshots {
                            LabeledContent("Screenshots", value: screenshots.formatted())
                        }
                    } else {
                        Text("Scan to count the photos and videos you allow this app to see.")
                    }
                    Button(model.inventory == nil ? "Scan Apple Photos" : "Rescan Apple Photos") {
                        model.startMetadataScan()
                    }
                    .disabled(model.isScanning)
                    if let snapshot = model.snapshot {
                        NavigationLink("Review videos by size") { VideoSizesView(snapshot: snapshot) }
                    } else {
                        NavigationLink("Find large videos") {
                            PhotoDetailsView(model: model, destination: .duplicates)
                        }
                        Text("Video sizes are measured during the full resource scan.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
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
                Section {
                    NavigationLink("Decide which copies to keep") {
                        PhotoCopyOptionsView(snapshot: model.isDemo ? nil : model.snapshot)
                    }
                }
                Section("Exact duplicate scan") {
                    if model.isScanning {
                        if model.total > 0 {
                            ProgressView(value: Double(model.completed), total: Double(model.total)) {
                                Text("Checked \(model.completed) of \(model.total) items")
                            }
                        } else {
                            ProgressView("Checking photos available on this iPhone…")
                        }
                        Button("Cancel scan", role: .cancel) { model.cancel() }
                    } else {
                        Button("Find exact duplicates") { model.startDuplicateScan() }
                        Text("Scans files already available on this iPhone. Originals that require an iCloud download are left unverified.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("Explore sample results") { model.showDemo() }
                    }
                    if let status = model.duplicateScanStatus { Text(status) }
                    if let error = model.errorMessage {
                        Text(error).foregroundStyle(.red).accessibilityLabel("Error: \(error)")
                    }
                    if model.authorization == .denied || model.authorization == .restricted {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
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
                        Text("Estimated matching resource bytes, not guaranteed recoverable device space. Review a group to remove its extra copies. Results describe the library at scan time; rescan after library changes.")
                            .font(.footnote).foregroundStyle(.secondary)
                        NavigationLink("Review duplicate groups") { DuplicateResultsView(snapshot: snapshot, model: model) }
                        NavigationLink("Review videos by size") { VideoSizesView(snapshot: snapshot) }
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
                if model.snapshot != nil {
                    CleanCategoriesSection(summaries: model.categorySummaries)
                }
                CleanElsewhereSection()
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
                                Text("TidyAway reads the Apple Photos items you authorize. Scanning and exact duplicate matching run on your device.")
                                Text("The app stores the latest completed inventory and its activity log locally. The inventory can include Photos identifiers, file names, dates, favorite status, resource sizes and hashes. The app does not transmit this information to the developer or include advertising or analytics.")
                                Text("Scans read originals already available on your iPhone. If you approve an archive or restore, the app writes a copy to your chosen Files folder. The source stays in place and the Files provider may sync the copy.")
                                Text("After a verified archive copy, the app keeps a local list of the file name, folder, size, checksum and date, with a reference to the folder you chose, so the Archived tab can find and restore it.")
                                Text("If you authorize removing exact duplicates, the app asks Apple Photos to delete the items you approved. Apple shows its own confirmation and normally keeps deleted items in Recently Deleted for up to 30 days. The authorization, item count and outcome are recorded in the local activity log.")
                                Text("You can change Photos access in Settings. To remove the local inventory and activity log from this device, delete the app.")
                                Text("Saved storage comparisons stay in the app’s local storage. You can remove them in the app or by deleting the app. If you share a comparison, you choose where the report goes. Apple handles in-app purchases.")
                                Text("When you select files for size analysis, the app reads their names and reported sizes for that session.")
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
    }
}

private struct VideoSizesView: View {
    let snapshot: ScanSnapshot

    var body: some View {
        let videos = snapshot.assets.filter { $0.mediaType == PHAssetMediaType.video.rawValue }
        let readable = videos.filter { $0.fingerprint != nil }.sorted {
            $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes
        }
        List {
            Section {
                if readable.isEmpty { Text("No fully readable videos in this scan.") }
                ForEach(readable) { video in
                    LabeledContent(video.filename, value: ByteCountFormatter.string(fromByteCount: video.bytes, countStyle: .file))
                }
            } footer: {
                Text("\(videos.count - readable.count) unverified videos excluded. Sizes reflect resources read during the scan.")
            }
        }
        .navigationTitle("Videos by size")
    }
}

struct DuplicateResultsView: View {
    let snapshot: ScanSnapshot
    var model: DashboardModel? = nil
    var body: some View {
        List {
            Section {
                Text("All resource hashes and resource types must match. Favorites appear first and are always kept. Nothing is deleted until you authorize it for a group and confirm Apple’s own prompt.")
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
                    if let model {
                        if let plan = DuplicateRemovalPlan(group: group) {
                            DuplicateRemovalControls(plan: plan, model: model)
                        } else {
                            Text("The extra copies here are favorites, so TidyAway leaves them alone.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }.navigationTitle("Exact duplicates")
    }
}

