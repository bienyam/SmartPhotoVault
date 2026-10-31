import SwiftUI
import Photos

struct DashboardView: View {
    @StateObject private var model = DashboardModel()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            List {
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
                        Task { await model.scan() }
                    }
                    .disabled(model.isScanning)
                }

                Section("Desired full-resolution copies") {
                    LabeledContent("iPhone originals", value: "Unverified")
                    LabeledContent("iCloud Photos", value: "Unverified")
                    LabeledContent("Google Photos", value: "Not connected")
                    Text("Library visibility does not verify a full-resolution copy. iPhone Photos and iCloud Photos can synchronize changes and are not independent backups.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("Coming next") {
                    LabeledContent("Exact duplicates", value: "Not scanned")
                    LabeledContent("Recoverable storage", value: "Not calculated")
                    Text("This first build counts metadata only. Duplicate hashing, local database storage, and Google Photos integration are not implemented yet.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("SmartPhotoVault")
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { model.refreshAuthorization() }
            }
        }
    }
}

