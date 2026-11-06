import SwiftUI
import Photos

struct DashboardView: View {
    @StateObject private var model = DashboardModel()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            List {
                if model.isDemo {
                    Section {
                        Label("Sample data — not your photo library", systemImage: "testtube.2")
                            .foregroundStyle(.orange)
                    }
                }
                Section {
                    Label("Your memories, accounted for", systemImage: "photo.on.rectangle.angled")
                        .font(.title2.bold())
                    Text("Keep full-resolution copies on your iPhone, in iCloud Photos, and in Google Photos.")
                        .foregroundStyle(.secondary)
                    Label("Read-only · No photos are changed or deleted", systemImage: "lock.shield")
                        .font(.footnote)
                }

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
                    if model.authorization == .limited {
                        Text("Limited access: counts cover only your selected items.").foregroundStyle(.orange)
                    }
                    if model.authorization == .denied || model.authorization == .restricted {
                        Text("Photo access is unavailable. You can review access in Settings; device restrictions may prevent changes.")
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                    }
                    Button(model.inventory == nil ? "Scan Apple Photos" : "Rescan Apple Photos") {
                        model.startMetadataScan()
                    }
                    .disabled(model.isScanning)
                }

                Section("Exact duplicate scan") {
                    Toggle("Allow iCloud resource downloads", isOn: $model.allowCloudDownloads)
                        .disabled(model.isScanning)
                    Text("Off by default. Cloud-only resources stay unverified. Enabling downloads can use mobile data and temporary device storage.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if model.isScanning {
                        ProgressView(value: Double(model.completed), total: Double(max(model.total, 1)))
                        Text("Checked \(model.completed) of \(model.total) assets")
                        Button("Cancel scan", role: .cancel) { model.cancel() }
                        Text("Cancellation completes when the current resource finishes reading.").font(.footnote)
                    } else {
                        Button("Find exact duplicates") { model.startDuplicateScan() }
                        Button("Explore sample results") { model.showDemo() }
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

                Section("Desired full-resolution copies") {
                    LabeledContent("iPhone originals", value: "Unverified")
                    LabeledContent("iCloud Photos", value: "Unverified")
                    LabeledContent("Google Photos", value: "Not connected")
                    Text("Library visibility does not verify a full-resolution copy. iPhone Photos and iCloud Photos can synchronize changes and are not independent backups.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("Activity") {
                    NavigationLink("View local activity log") {
                        List(model.activity) { entry in
                            VStack(alignment: .leading) {
                                Text(entry.message)
                                Text(entry.date.formatted()).font(.caption).foregroundStyle(.secondary)
                            }
                        }.navigationTitle("Activity log")
                    }
                    Text("Google Photos integration and visually similar matching are planned for later releases.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.borderless)
            .navigationTitle("SmartPhotoVault")
            .task {
                if ProcessInfo.processInfo.arguments.contains("--demo") { model.showDemo() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { model.refreshAuthorization() }
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

