import SwiftUI
import Photos

/// The launch tab: one button to find space, then the biggest wins, largest first.
struct FreeUpView: View {
    @ObservedObject var model: DashboardModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    @State private var storage = DeviceStorage.current()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if model.isScanning {
                        scanning
                    } else if let rescue = model.rescue {
                        results(rescue)
                    } else {
                        start
                    }
                    if let error = model.errorMessage {
                        Text(error).font(.subheadline).foregroundStyle(Brand.caution)
                    }
                    if model.authorization == .denied || model.authorization == .restricted {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("TidyAway needs access to your photos to find space.")
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                .frame(maxWidth: 520)
                .padding(20)
                .frame(maxWidth: .infinity)
            }
            .background(colorScheme == .dark ? Color(uiColor: .systemBackground) : Brand.background)
            .navigationTitle("TidyAway")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { storage = DeviceStorage.current() }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Storage full? Get your camera back.")
                .font(.title.bold())
                .accessibilityAddTraits(.isHeader)
            if let storage {
                StorageBar(storage: storage)
            }
        }
    }

    private var start: some View {
        VStack(spacing: 12) {
            Button { model.startDuplicateScan() } label: {
                Label("Free up space", systemImage: "sparkles")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .foregroundStyle(Color.white)
                    .background(Brand.primary, in: RoundedRectangle(cornerRadius: 18))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("free-up-space")
            HStack(spacing: 4) {
                Text("Nothing is removed until you approve it.")
                    .font(.footnote).foregroundStyle(.secondary)
                InfoButton(title: "How it works",
                           text: "TidyAway looks through the photos and videos on this iPhone and lists the biggest things you could remove. It reads them on your iPhone and sends nothing anywhere. You choose what goes, sign off, and Apple asks you to confirm.")
            }
            Button("Try it with sample photos") { model.showDemo() }
                .font(.subheadline)
                .accessibilityIdentifier("try-samples")
        }
    }

    private var scanning: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.total > 0 {
                ProgressView(value: Double(model.completed), total: Double(model.total)) {
                    Text("Looking through \(model.completed.formatted()) of \(model.total.formatted())")
                }
            } else {
                ProgressView("Looking through your photos…")
            }
            Button("Cancel", role: .cancel) { model.cancel() }
        }
        .padding(16)
        .background(Brand.surface, in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private func results(_ rescue: RescueSummary) -> some View {
        if model.isDemo {
            Label("Sample photos, not your library", systemImage: "testtube.2")
                .font(.subheadline.weight(.semibold))
        }
        VStack(alignment: .leading, spacing: 4) {
            Text("You could free up to").font(.subheadline).foregroundStyle(.secondary)
            Text(rescue.upToBytes.fileSize).font(.system(size: 40, weight: .bold))
        }
        VStack(spacing: 0) {
            NavigationLink {
                CleanupListView(title: "Large videos",
                                guidance: "Videos are usually the biggest files on an iPhone. These are the ones on this iPhone, largest first.",
                                items: rescue.videos, source: "Large videos", allowsRemoval: true, model: model)
            } label: {
                row("Large videos", icon: "video", detail: rescue.videos.isEmpty ? "None" : rescue.videoBytes.fileSize)
            }
            .accessibilityIdentifier("row-videos")
            Divider()
            NavigationLink { DuplicatesListView(model: model) } label: {
                row("Duplicates", icon: "square.on.square",
                    detail: rescue.duplicateCopies == 0 ? "None" : rescue.duplicateBytes.fileSize)
            }
            .accessibilityIdentifier("row-duplicates")
            Divider()
            NavigationLink {
                CleanupListView(title: "Screenshots", guidance: CleanCategory.screenshots.guidance,
                                items: rescue.screenshots.items, source: "Screenshots", allowsRemoval: true, model: model)
            } label: {
                row("Screenshots", icon: "camera.viewfinder",
                    detail: rescue.screenshots.items.isEmpty ? "None" : rescue.screenshots.knownBytes.fileSize)
            }
            .accessibilityIdentifier("row-screenshots")
            Divider()
            NavigationLink { MoreTypesView(types: rescue.otherTypes, model: model) } label: {
                row("More types", icon: "square.grid.2x2", detail: rescue.otherBytes.fileSize)
            }
            .accessibilityIdentifier("row-more")
        }
        .buttonStyle(.plain)
        .background(Brand.surface, in: RoundedRectangle(cornerRadius: 16))
        if model.libraryChanged {
            Text("Your photos changed since this check.").font(.footnote).foregroundStyle(.secondary)
        }
        if let status = model.duplicateScanStatus, status != "Scan complete." {
            Text(status).font(.footnote).foregroundStyle(.secondary)
        }
        Button(model.isDemo ? "Check my photos instead" : "Check again") { model.startDuplicateScan() }
            .font(.subheadline)
            .accessibilityIdentifier("check-again")
    }

    private func row(_ title: String, icon: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title3).frame(width: 30).foregroundStyle(Brand.primary)
                .accessibilityHidden(true)
            Text(title).font(.headline)
            Spacer()
            Text(detail).foregroundStyle(.secondary)
            Image(systemName: "chevron.right").font(.footnote.bold()).foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 60)
        .contentShape(Rectangle())
    }
}

/// Used and free space on this iPhone, like the bar in Settings.
struct StorageBar: View {
    let storage: DeviceStorage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule().fill(Brand.primary)
                        .frame(width: max(8, proxy.size.width * storage.usedFraction))
                }
            }
            .frame(height: 10)
            Text("\(storage.available.fileSize) free of \(storage.total.fileSize)")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// GIFs, Live Photos, slo-mo and the rest, each opening its own list.
struct MoreTypesView: View {
    let types: [CleanCategorySummary]
    @ObservedObject var model: DashboardModel

    var body: some View {
        List {
            if types.isEmpty {
                Text("Check your photos again to sort them by type.")
            }
            ForEach(types, id: \.category) { summary in
                NavigationLink {
                    CleanupListView(title: summary.category.title, guidance: summary.category.guidance,
                                    items: summary.items, source: summary.category.title,
                                    allowsRemoval: summary.category.allowsRemoval, model: model)
                } label: {
                    HStack {
                        Label(summary.category.title, systemImage: summary.category.systemImage)
                        Spacer()
                        Text(detail(summary)).foregroundStyle(.secondary)
                    }
                }
                .disabled(summary.items.isEmpty)
                .accessibilityIdentifier("category-\(summary.category.rawValue)")
            }
        }
        .navigationTitle("More types")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func detail(_ summary: CleanCategorySummary) -> String {
        guard !summary.items.isEmpty else { return "None" }
        if summary.category == .bursts { return "\(summary.items.count.formatted()) · view only" }
        return "\(summary.items.count.formatted()) · \(summary.knownBytes.fileSize)"
    }
}

/// Everything that isn't cleanup or archiving, one row each.
struct MoreView: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { LedgerView(model: model) } label: {
                        Label("Activity", systemImage: "checkmark.shield")
                    }
                    .accessibilityIdentifier("more-activity")
                    NavigationLink { StorageGuideView(snapshot: model.isDemo ? nil : model.snapshot) } label: {
                        Label("Analyze storage", systemImage: "internaldrive")
                    }
                    .accessibilityIdentifier("more-analyze")
                    NavigationLink { ProUpgradeView() } label: {
                        Label("TidyAway Pro", systemImage: "sparkles")
                    }
                    .accessibilityIdentifier("more-pro")
                }
                Section("Tips") {
                    NavigationLink { MessagesAttachmentsGuide() } label: {
                        Label("Photos and videos in Messages", systemImage: "message")
                    }
                    .accessibilityIdentifier("guide-messages")
                    NavigationLink { CloudDownloadRemovalView() } label: {
                        Label("Free iCloud Drive downloads", systemImage: "icloud.and.arrow.down")
                    }
                    .accessibilityIdentifier("more-icloud-downloads")
                    NavigationLink { SelectedFilesAnalysisView() } label: {
                        Label("Find large files", systemImage: "doc.text.magnifyingglass")
                    }
                    .accessibilityIdentifier("more-large-files")
                    NavigationLink { OptimizeStorageTip() } label: {
                        Label("Keep smaller copies with iCloud", systemImage: "iphone")
                    }
                    .accessibilityIdentifier("more-optimize")
                }
                Section {
                    NavigationLink { HelpPrivacyView(model: model) } label: {
                        Label("Help & privacy", systemImage: "questionmark.circle")
                    }
                    .accessibilityIdentifier("more-help")
                }
            }
            .navigationTitle("More")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// Apple doesn't let apps switch on Optimize Storage, so this is the one setting to change yourself.
struct OptimizeStorageTip: View {
    var body: some View {
        List {
            Section {
                Text("If you use iCloud Photos, your iPhone can keep smaller versions of photos and videos and leave the full-size originals in iCloud. It frees space without deleting anything.")
            }
            Section("Turn it on") {
                Text("1. Open Settings and tap your name.")
                Text("2. Tap iCloud, then Photos.")
                Text("3. Choose Optimize iPhone Storage.")
            }
            Section {
                Text("You need enough iCloud storage to hold your whole library. Menu names can differ slightly between iOS versions.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Keep smaller copies")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct HelpPrivacyView: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        List {
            Section("How TidyAway works") {
                Text("Free up finds the biggest things on this iPhone. You pick what goes, sign off, and Apple asks you to confirm. Deleted items wait in Recently Deleted for 30 days; empty it in Photos to get the space back.")
                Text("Archive copies photos and files to a place you choose and checks every copy. It only adds copies there; it never deletes or changes anything in your archive.")
            }
            Section("Privacy") {
                Text("TidyAway reads the Apple Photos items you authorize. Scanning and exact duplicate matching run on your device.")
                Text("The app stores the latest completed check and its activity log locally. The check can include Photos identifiers, file names, dates, favorite status, resource sizes and hashes, the names of your albums, and an approximate location rounded to about 1 km. The app does not transmit this information to the developer or include advertising or analytics.")
                Text("When you choose a place on the Archive tab, the map is loaded from Apple Maps. Your photo locations stay on your iPhone.")
                Text("Checks read originals already available on your iPhone. If you approve an archive or restore, the app writes a copy to your chosen folder. The source stays in place and the provider may sync the copy.")
                Text("After a verified archive copy, the app keeps a local list of the file name, folder, size, checksum and date, with a reference to the folder you chose, so you can find and restore it.")
                Text("If you approve deleting items, the app asks Apple Photos to delete exactly those items. Apple shows its own confirmation and normally keeps deleted items in Recently Deleted for up to 30 days. The approval, item count and outcome are recorded in the local activity log.")
                Text("You can change Photos access in Settings. To remove the local data and activity log from this device, delete the app.")
                Text("Saved storage comparisons stay in the app's local storage. If you share a comparison, you choose where the report goes. Apple handles in-app purchases.")
                Text("When you select files for size analysis, the app reads their names and reported sizes for that session.")
            }
        }
        .navigationTitle("Help & privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}
