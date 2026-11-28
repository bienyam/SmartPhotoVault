import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Screens pushed from the Archive tab.
enum ArchiveRoute: Hashable {
    case group(String), albums, filter, destination, copy, drive
}

/// A folder picker that belongs to the screen showing it.
private struct FolderPicker: ViewModifier {
    @Binding var isPresented: Bool
    let pick: (URL) -> Void

    func body(content: Content) -> some View {
        content.fileImporter(isPresented: $isPresented, allowedContentTypes: [.folder]) { result in
            if case .success(let folder) = result { pick(folder) }
        }
    }
}

/// Offers the scan that groups come from, and shows its progress.
struct ArchiveScanCard: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.isScanning {
                if model.total > 0 {
                    ProgressView(value: Double(model.completed), total: Double(model.total)) {
                        Text("Looking through \(model.completed.formatted()) of \(model.total.formatted())")
                    }
                } else {
                    ProgressView("Looking through your photos…")
                }
            } else {
                Text("TidyAway groups your events, trips and large videos from your \(Device.name) and iCloud, so you can move a whole group in one go.")
                    .foregroundStyle(ArchiveStyle.muted)
                Button("Find my groups") { model.startDuplicateScan() }
                    .buttonStyle(ArchiveButtonStyle())
                    .accessibilityIdentifier("archive-scan")
                Text("Checked on your \(Device.name). Nothing is removed.").font(.footnote).foregroundStyle(ArchiveStyle.muted)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.surface, in: RoundedRectangle(cornerRadius: 18))
    }
}

/// Move out: choose a group or pick items, choose where to copy, approve, copy and check.
struct PhotoArchiveView: View {
    let snapshot: ScanSnapshot?

    private enum Age: String, CaseIterable {
        case any = "Any time"
        case one = "Over 1 year old"
        case two = "Over 2 years old"
        case five = "Over 5 years old"

        var years: Int? {
            switch self {
            case .any: nil
            case .one: 1
            case .two: 2
            case .five: 5
            }
        }
    }

    private enum SizeFloor: String, CaseIterable {
        case any = "Any size"
        case five = "Over 5 MB"
        case ten = "Over 10 MB"
        case twentyFive = "Over 25 MB"

        var bytes: Int64 {
            switch self {
            case .any: 0
            case .five: 5_000_000
            case .ten: 10_000_000
            case .twentyFive: 25_000_000
            }
        }
    }


    private static let suggestionLimit = 200

    private enum Destination: String, CaseIterable {
        case drive = "Drive plugged into this iPhone"
        case iCloud = "iCloud Drive"
        case shared = "Another Apple Account"
        case google = "Google Drive"
        case home = "Home file server"
        case other = "Other Files location"
        case oneDrive = "OneDrive"
        case dropbox = "Dropbox"

        /// What the picker shows; rawValue stays fixed as the identity.
        var title: String { self == .drive ? "Drive plugged into this \(Device.name)" : rawValue }

        /// Every destination stays available (owner rule: never drop an existing feature unasked).
        /// A plugged-in drive is listed first because most people own one.
        /// OneDrive and Dropbox appear once TidyAway is registered with them.
        static var offered: [Destination] {
            [.drive, .google, .iCloud, .other, .home, .shared] + [.oneDrive, .dropbox].filter { $0.cloud?.available == true }
        }

        var cloud: CloudService? {
            switch self {
            case .oneDrive: .oneDrive
            case .dropbox: .dropbox
            default: nil
            }
        }

        var detail: String {
            switch self {
            case .drive: "Plug a USB-C drive or memory stick into your \(Device.name) (older \(Device.name)s need Apple's camera adapter), then choose it under Locations. ExFAT drives work best."
            case .iCloud: "Choose a folder from iCloud Drive in Files."
            case .shared: "Choose a folder the other Apple Account has shared with you with permission to make changes."
            case .google: "Sign in with Google. TidyAway can only see and add the files it puts in a \"TidyAway Archive\" folder."
            case .home: "In Files, connect to your server from Browse → More → Connect to Server, then choose its shared folder. Stay on the same Wi-Fi as your server for copying, verification and restore. This workflow has no background sync."
            case .other: "Choose a folder from another provider in Files, an attached drive, or On My \(Device.name)."
            case .oneDrive: "Sign in with Microsoft. Copies go to a TidyAway folder in My files, where you can see them in OneDrive."
            case .dropbox: "Sign in with Dropbox. TidyAway can only see and add files in its own folder, Apps › TidyAway."
            }
        }

        var icon: String {
            switch self {
            case .drive: "externaldrive.connected.to.line.below"
            case .iCloud, .shared: "icloud"
            case .google: "externaldrive"
            case .home: "server.rack"
            case .other: "folder"
            case .oneDrive, .dropbox: "cloud"
            }
        }
    }

    @Environment(\.locale) private var locale
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var photoAccess = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var items: [ArchiveItem] = []
    @State private var destination: URL?
    @State private var destinationKind: Destination?
    @State private var availableGB = ""
    @State private var measuredBytes: [String: Int64] = [:]
    @State private var checkedPhotos: [String: ResourceFingerprint] = [:]
    /// Live Photos and edited photos picked by hand: the fingerprint of every file, measured before copying.
    @State private var checkedParts: [String: [ResourceFingerprint]] = [:]
    @State private var wifi = ArchiveWiFi()
    @State private var restoreFolder: URL?
    @State private var showFiles = false
    @State private var showArchiveFolder = false
    /// The online service whose folder picker is open.
    @State private var pickingFolder: OnlinePlace?
    /// Changes when a folder is picked, so the shown path updates.
    @State private var folderChoice = 0
    @State private var showRestoreFolder = false
    @State private var showDetails = false
    @State private var showRunDetails = false
    @State private var showReview = false
    @State private var showProPushed = false
    /// Which Pro feature the half sheet describes.
    @State private var lockedFeature = ProFeature.archiveGroups
    @State private var showRun = false
    @State private var ratingTrigger = 0
    @State private var groups: [SmartGroup] = []
    @State private var findingGroups = false
    @State private var section = SmartGroup.Section.forYou
    @State private var goal: Int64 = 10
    @State private var picks: [Int64: SmartGroup] = [:]
    @ObservedObject private var insights = InsightModel.shared
    @ObservedObject private var basket = ArchiveBasket.shared
    @StateObject private var run = ArchiveRun()
    @StateObject private var drive = DriveModel()
    @State private var showDriveHelp = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @Binding private var path: NavigationPath
    @Binding private var locked: Bool
    @Binding private var readyBytes: Int64
    @State private var age: Age = .two
    @State private var sizeFloor: SizeFloor = .any
    @State private var kind: ArchiveKind = .photos
    @State private var albumID: String?
    @State private var place: PlaceArea?
    @State private var showPlacePicker = false
    @State private var showSuggested = false
    @State private var findingSuggestions = false
    @State private var suggested: [ArchiveItem] = []
    @State private var archiveConsent = false
    @State private var restoreConsent = false
    @State private var busy = false
    @State private var checkingSizes = false
    @State private var message: String?
    @State private var receipts: [ArchiveReceipt] = []
    @State private var restoreTarget: ArchiveReceipt?
    @State private var restored: Set<String> = []
    @State private var homeReceipts: Set<String> = []
    @State private var failures: [String] = []
    @State private var archivedBytes: Int64 = 0
    /// Sizes Photos reports for items that couldn't be measured yet (usually kept only in iCloud), so
    /// the free 5 GB counts them too (1.0.2, B4). Never used to check a copy.
    @State private var estimatedBytes: [String: Int64] = [:]
    @State private var folderCheck: FolderCheck?
    @ObservedObject private var google = GoogleDriveAccount.shared
    @ObservedObject private var oneDrive = CloudAccount.oneDrive
    @ObservedObject private var dropbox = CloudAccount.dropbox
    @State private var checkingFolder = false
    @State private var showPro = false
    @EnvironmentObject private var pro: ProStore
    /// Groups, album and place choices and suggested videos: one rule, from `ProGate`.
    private var groupsOpen: Bool { pro.allows(.archiveGroups) }

    private let accent = Brand.primary

    /// Needed to remove originals from Photos after a verified archive.
    var model: DashboardModel?
    /// Switches the Archive tab to Get back.
    var showArchived: (() -> Void)?
    @State private var removal: ArchiveCompletion?
    @Environment(\.openURL) private var openURL

    init(snapshot: ScanSnapshot?, selectedFiles: [URL] = [], model: DashboardModel? = nil, showArchived: (() -> Void)? = nil,
         path: Binding<NavigationPath> = .constant(NavigationPath()), locked: Binding<Bool> = .constant(false),
         readyBytes: Binding<Int64> = .constant(0)) {
        _path = path
        _locked = locked
        _readyBytes = readyBytes
        self.snapshot = snapshot
        self.model = model
        self.showArchived = showArchived
        _items = State(initialValue: selectedFiles.map {
            ArchiveItem(id: $0.absoluteString, name: $0.lastPathComponent, source: .file($0))
        })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let message { Text(message).font(.subheadline).accessibilityAddTraits(.updatesFrequently) }
                groupsSection
                pickRow
                destinationChip
                HStack(spacing: 2) {
                    Label("Only adds. Never deletes there.", systemImage: "lock.shield")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(ArchiveStyle.safeText)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(ArchiveStyle.safeBack, in: Capsule())
                        .accessibilityIdentifier("archive-write-only")
                    InfoButton(title: "Your archive", text: Self.promise)
                }
                if !receipts.isEmpty || !failures.isEmpty {
                    Button("Last copy: results and test restore") { showDetails = true }
                        .buttonStyle(ArchiveOutlineStyle())
                        .accessibilityIdentifier("archive-details")
                }
            }
            .frame(maxWidth: 640)
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity)
            .reportsArchiveScroll()
        }
        .coordinateSpace(name: ArchiveScroll.space)
        .disabled(busy)
        .background(Brand.background)
        .safeAreaInset(edge: .bottom) {
            if !items.isEmpty { nextBar }
        }
        .tint(accent)
        .navigationDestination(for: ArchiveRoute.self) { route in
            switch route {
            case .group(let id): groupScreen(id)
            case .albums: albumsScreen
            case .filter: filterScreen
            case .destination: destinationScreen
            case .copy: copyScreen
            case .drive:
                DriveScreen(model: drive) { folder in
                    destinationKind = .drive
                    useSavedDrive(folder)
                    path = NavigationPath()
                }
            }
        }
        .fullScreenCover(isPresented: $showRun) { runCover }
        .asksForRating(when: ratingTrigger)
        .sheet(isPresented: $showDetails) { detailsSheet }
        .sheet(isPresented: $showPro) { proSheet($showPro) }
        .sheet(item: $pickingFolder) { place in
            OnlineFolderPicker(place: place, token: folderToken(place)) { folder in
                OnlineFolders.choose(folder, for: place)
                folderChoice += 1
                archiveConsent = false
            }
        }
        .onAppear { refreshArchivedBytes() }
        .onChange(of: snapshot?.date) {
            // A new scan can drop albums or places, so start the album and place choices fresh.
            albumID = nil
            place = nil
        }
        .onChange(of: busy) { locked = busy }
        .onChange(of: basket.request) { takeBasket() }
        .onAppear(perform: takeBasket)
        .task(id: groupKey) { await findGroups() }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.data], allowsMultipleSelection: true, onCompletion: addFiles)
        .onChange(of: photoSelection) { _, selection in addPhotos(selection) }
    }

    private static let promise = "TidyAway only adds copies to your archive. It never deletes or changes anything there, by design. Copies are full-resolution originals, checked against the originals on your \(Device.name). Your source items stay where they are."
    private static let supported = "Photos supports JPEG and HEIC photos and single-file videos. Live Photos and edited photos are copied with every part. Slo-mo, edited videos and RAW pairs aren't supported yet. Use Files for documents. Suggestions leave out favorites; events and trips include them, and they are never deleted."

    // MARK: - Home

    private var groupKey: String {
        "\(snapshot?.date.timeIntervalSince1970 ?? 0)-\(snapshot?.assets.count ?? 0)-\(insights.revision)"
    }

    /// What the chosen section shows. For you leads with same-shot extras and the biggest videos.
    private var shownGroups: [SmartGroup] {
        guard section == .forYou else { return groups.filter { $0.section == section } }
        return groups.filter { $0.kind == .sameShots } + groups.filter { $0.kind == .largeVideos }
            + Array(groups.filter { $0.kind == .event || $0.kind == .trip }.prefix(2))
    }

    @ViewBuilder
    private var groupsSection: some View {
        if let snapshot, !snapshot.includedCloudDownloads {
            sectionPills
            if section == .forYou { goalPicker }
            if findingGroups {
                ProgressView("Finding groups…")
            } else {
                let shown = shownGroups
                if section == .forYou {
                    if !shown.isEmpty { heading("Or start here") }
                    cards(shown)
                } else if let first = shown.first {
                    groupButton(first, tall: true)
                    cards(Array(shown.dropFirst()))
                } else {
                    Text(emptyText).foregroundStyle(ArchiveStyle.muted)
                }
            }
            recognitionNote
            if snapshot.albums != nil {
                HStack(spacing: 10) {
                    Button { if groupsOpen { path.append(ArchiveRoute.albums) } else { askPro(.archiveGroups) } } label: {
                        proLabel("Albums", systemImage: "rectangle.stack", locked: !groupsOpen)
                    }
                    .accessibilityIdentifier("archive-albums")
                    Button { if groupsOpen { path.append(ArchiveRoute.filter) } else { askPro(.archiveGroups) } } label: {
                        proLabel("Places", systemImage: "map", locked: !groupsOpen)
                    }
                    .accessibilityIdentifier("archive-places")
                }
                .buttonStyle(ArchiveOutlineStyle())
            } else {
                Text("Scan again to also choose by album or place.").font(.footnote).foregroundStyle(ArchiveStyle.muted)
            }
        } else {
            heading("Ready to move in one go")
            if let model { ArchiveScanCard(model: model) }
        }
    }

    private func heading(_ text: String) -> some View {
        HStack(spacing: 8) {
            Text(text).font(.title3.weight(.heavy)).foregroundStyle(ArchiveStyle.ink)
                .accessibilityAddTraits(.isHeader)
            if !groupsOpen { ProBadge() }
        }
    }

    private var sectionPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SmartGroup.Section.allCases, id: \.self) { value in
                    let on = section == value
                    Button(value.rawValue) { section = value }
                        .font(.subheadline.weight(.bold))
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .foregroundStyle(on ? ArchiveStyle.onSelected : ArchiveStyle.ink)
                        .background(on ? ArchiveStyle.selected : Color.clear, in: Capsule())
                        .overlay(Capsule().stroke(on ? Color.clear : ArchiveStyle.border, lineWidth: 1.5))
                        .contentShape(Capsule())
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                        .accessibilityIdentifier("section-\(value)")
                }
            }
        }
    }

    private func cards(_ list: [SmartGroup]) -> some View {
        LazyVGrid(columns: typeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
            ForEach(list) { groupButton($0, tall: false) }
        }
    }

    /// Say how much space is needed; get one pick that reaches it.
    @ViewBuilder
    private var goalPicker: some View {
        heading("How much space do you need?")
        HStack(spacing: 8) {
            ForEach(SmartGrouper.goals, id: \.self) { value in
                let on = goal == value
                Button("\(value) GB") { goal = value }
                    .font(.title3.weight(.heavy))
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .foregroundStyle(on ? ArchiveStyle.onSelected : ArchiveStyle.ink)
                    .background(on ? ArchiveStyle.selected : Color.clear, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(on ? Color.clear : ArchiveStyle.border, lineWidth: 1.5))
                    .contentShape(Rectangle())
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                    .accessibilityIdentifier("goal-\(value)")
            }
        }
        if let pick = picks[goal] {
            groupButton(pick, tall: true)
            if pick.bytes < goal * 1_000_000_000 {
                Text("That's everything TidyAway would pick. Favorites, recent photos and your albums are left out.")
                    .font(.footnote).foregroundStyle(ArchiveStyle.muted)
            }
        } else if !findingGroups {
            Text("Nothing to pick. Favorites, recent photos and your albums are left out.")
                .font(.footnote).foregroundStyle(ArchiveStyle.muted)
        }
    }

    private var emptyText: String {
        switch section {
        case .topics: insights.running ? "Topics appear as TidyAway looks through your photos." : "No topics with enough photos yet."
        case .moments: "No events in your last scan. Pick photos below, or use Filter."
        case .videos: "No large, long or old videos in your last scan."
        case .forYou: ""
        }
    }

    /// What recognition is doing. It runs while TidyAway is open and never sends anything.
    @ViewBuilder
    private var recognitionNote: some View {
        if insights.running, insights.total > 0 {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: Double(insights.done), total: Double(max(insights.total, 1))) {
                    Text(insights.resting ? "Resting. It continues when your \(Device.name) is cooler and not saving power."
                         : "Looking at what's in your photos: \(insights.done.formatted()) of \(insights.total.formatted())")
                        .font(.footnote)
                }
                Text("On your \(Device.name) only. Nothing is sent. Groups get better as it goes.").font(.footnote).foregroundStyle(ArchiveStyle.muted)
            }
            .padding(12)
            .background(Brand.surface, in: RoundedRectangle(cornerRadius: 14))
            .accessibilityIdentifier("recognition-progress")
        } else if section == .topics || section == .moments {
            HStack(spacing: 2) {
                Text("Recognized on your \(Device.name). Nothing is sent.")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(ArchiveStyle.safeText)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(ArchiveStyle.safeBack, in: Capsule())
                InfoButton(title: "How groups are made",
                           text: "TidyAway uses the image recognition built into your \(Device.name) to see what pictures show, such as a beach or a receipt. It can be wrong, so every group says why and opens for you to check. It keeps the labels, never a picture, and can't tell who is in a photo.")
            }
        }
    }

    private func groupButton(_ group: SmartGroup, tall: Bool) -> some View {
        Button {
            if groupsOpen { path.append(ArchiveRoute.group(group.id)) } else { askPro(.archiveGroups) }
        } label: {
            ArchiveCard(title: group.title,
                        detail: "\(group.records.count.formatted()) \(group.records.count == 1 ? "item" : "items")\(group.kind == .pick ? "" : " · \(group.bytes.fileSize)")\(group.when.map { "\n\($0)" } ?? "")",
                        coverID: group.records.first?.id, tall: tall)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("group-\(group.id)")
    }

    @ViewBuilder
    private var pickRow: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
        layout {
            switch photoAccess {
            case .authorized, .limited:
                PhotosPicker(selection: $photoSelection, maxSelectionCount: 200, matching: .any(of: [.images, .videos]), photoLibrary: .shared()) {
                    Label("Pick photos", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(ArchiveOutlineStyle())
                .accessibilityLabel("Pick photos or videos myself")
            case .notDetermined:
                Button {
                    Task { photoAccess = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
                } label: {
                    Label("Allow Photos", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(ArchiveOutlineStyle())
                .accessibilityLabel("Allow Photos access to pick originals")
            default:
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                } label: {
                    Label("Open Settings", systemImage: "gear")
                }
                .buttonStyle(ArchiveOutlineStyle())
            }
            Button { showFiles = true } label: { Label("Pick files", systemImage: "folder") }
                .buttonStyle(ArchiveOutlineStyle())
                .accessibilityLabel("Pick files myself")
        }
        if photoAccess == .denied || photoAccess == .restricted {
            Text("Allow Photos access in Settings to pick originals, or choose an item from Files.")
                .font(.footnote).foregroundStyle(ArchiveStyle.muted)
        }
        HStack(spacing: 2) {
            if let snapshot, !snapshot.includedCloudDownloads {
                Button { path.append(ArchiveRoute.filter) } label: { Label("Filter", systemImage: "line.3.horizontal.decrease.circle") }
                    .font(.subheadline.weight(.bold)).foregroundStyle(ArchiveStyle.link).frame(minHeight: 44)
                    .accessibilityIdentifier("archive-filter")
            }
            Spacer(minLength: 0)
            Text("What can be archived").font(.footnote).foregroundStyle(ArchiveStyle.muted)
            InfoButton(title: "What can be archived", text: Self.supported)
        }
    }

    private var destinationTitle: String {
        if destinationKind == .google, google.email != nil { return "Copy to Google Drive" }
        if let service = toCloud { return "Copy to \(service.name)" }
        if let destination { return "Copy to \(destination.lastPathComponent)" }
        return "Choose where to copy"
    }

    private var destinationDetail: String {
        if destinationKind == .google { return google.email ?? "Connect Google Drive" }
        if let service = destinationKind?.cloud { return account(service).name ?? "Connect \(service.name)" }
        if let problem = folderCheck?.problem { return problem }
        if let free = folderCheck?.available { return "\(formattedBytes(free)) free" }
        return destination == nil ? "A drive, a cloud, or your own server" : "Ready"
    }

    private var destinationChip: some View {
        Button { path.append(ArchiveRoute.destination) } label: {
            HStack(spacing: 12) {
                Image(systemName: destinationKind?.icon ?? "externaldrive.badge.plus").font(.title2).foregroundStyle(ArchiveStyle.link)
                VStack(alignment: .leading, spacing: 2) {
                    Text(destinationTitle).font(.headline).foregroundStyle(ArchiveStyle.ink)
                    Text(destinationDetail).font(.footnote).foregroundStyle(ArchiveStyle.muted)
                }
                Spacer(minLength: 0)
                Text(destination == nil && destinationKind == nil ? "Choose" : "Change").font(.subheadline.weight(.bold)).foregroundStyle(ArchiveStyle.link)
            }
            .multilineTextAlignment(.leading)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.surface, in: RoundedRectangle(cornerRadius: 16))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("storage-location")
    }

    private var nextBar: some View {
        HStack(spacing: 10) {
            Button("Clear", action: startOver)
            .font(.subheadline.weight(.bold)).foregroundStyle(ArchiveStyle.link).frame(minWidth: 56, minHeight: 44)
            .accessibilityIdentifier("archive-clear")
            Button("Next · \(items.count.formatted()) \(items.count == 1 ? "item" : "items")\(selectedBytes > 0 ? " · \(formattedBytes(selectedBytes))" : "")") {
                path.append(ArchiveRoute.copy)
            }
            .buttonStyle(ArchiveButtonStyle())
            .accessibilityIdentifier("archive-next")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.regularMaterial)
    }

    // MARK: - Groups and albums

    @ViewBuilder
    private func groupScreen(_ id: String) -> some View {
        if let group = groups.first(where: { $0.id == id }) ?? picks.values.first(where: { $0.id == id }) ?? albumGroup(id) {
            GroupSkimView(group: group) { records in
                startOver()
                add(records)
                path.append(ArchiveRoute.copy)
            }
        } else {
            Text("This group changed after the last scan. Go back and choose again.").padding()
        }
    }

    private func albumGroup(_ id: String) -> SmartGroup? {
        guard let snapshot, let album = snapshot.albums?.first(where: { "album-\($0.id)" == id }) else { return nil }
        return SmartGrouper.album(album, in: snapshot)
    }

    private var albumsScreen: some View {
        List {
            if let snapshot, let albums = snapshot.albums, !albums.isEmpty {
                ForEach(albums) { album in
                    Button { path.append(ArchiveRoute.group("album-\(album.id)")) } label: {
                        Label(album.title, systemImage: "rectangle.stack").foregroundStyle(.primary)
                    }
                }
            } else {
                Text("Your last scan found no albums.")
            }
        }
        .navigationTitle("Albums")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func findGroups() async {
        guard let snapshot, !snapshot.includedCloudDownloads else {
            groups = []
            picks = [:]
            readyBytes = 0
            return
        }
        findingGroups = groups.isEmpty
        let known = insights.insights
        let found = await Task.detached(priority: .userInitiated) { () -> ([SmartGroup], [Int64: SmartGroup]) in
            let facts = AssetFacts.all(for: snapshot.assets)
            let groups = SmartGrouper.groups(in: snapshot, insights: known, facts: facts)
            var picks: [Int64: SmartGroup] = [:]
            for goal in SmartGrouper.goals {
                picks[goal] = SmartGrouper.pick(goal: goal, in: snapshot.assets, insights: known, facts: facts)
            }
            return (groups, picks)
        }.value
        guard !Task.isCancelled else { return }
        groups = found.0
        picks = found.1
        var counted = Set<String>()
        readyBytes = found.0.flatMap(\.records).reduce(Int64(0)) { counted.insert($1.id).inserted ? $0 + $1.displayBytes : $0 }
        findingGroups = false
        insights.start(snapshot.assets)
    }

    /// Photos sent from a Free up list: added to the selection, straight to the copy screen.
    private func takeBasket() {
        let records = basket.take()
        guard !records.isEmpty, !busy else { return }
        let ready = records.filter(SmartGrouper.canArchive)
        startOver()
        add(ready)
        let left = records.count - ready.count
        message = left == 0 ? nil : "\(left.formatted()) of these can't be archived yet: slo-mo, edited videos and some formats."
        path = NavigationPath()
        if !items.isEmpty { path.append(ArchiveRoute.copy) }
    }

    /// Empties the selection, so what is chosen next is all that is copied.
    private func startOver() {
        items = []
        measuredBytes = [:]
        checkedPhotos = [:]
        checkedParts = [:]
        estimatedBytes = [:]
        archiveConsent = false
        message = nil
    }

    /// Adds a whole group. The scan already knows each item's size and, for local ones, its fingerprint.
    private func add(_ records: [AssetRecord]) {
        var known = Set(items.map(\.id))
        for record in records where known.insert(record.id).inserted {
            items.append(ArchiveItem(id: record.id, name: record.filename,
                                     source: .photo(record.id, expected: record.inICloud ? nil : ArchivePlan.primaryFingerprint(of: record)),
                                     size: record.displayBytes > 0 ? record.displayBytes : nil,
                                     expectedParts: record.inICloud ? nil : ArchivePlan.partFingerprints(of: record)))
            if record.inICloud, let size = record.cloudBytes { measuredBytes[record.id] = size }
        }
        archiveConsent = false
    }

    // MARK: - Destination

    private var destinationScreen: some View {
        List { destinationSection }
            .scrollContentBackground(.hidden)
            .background(Brand.background)
            .navigationTitle("Copy to")
            .navigationBarTitleDisplayMode(.inline)
            .disabled(busy)
            .modifier(FolderPicker(isPresented: $showArchiveFolder, pick: setDestination))
    }

    private var destinationSection: some View {
        Section("Copy to") {
            LazyVGrid(columns: typeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                ForEach(Destination.offered, id: \.self) { kind in
                    let on = destinationKind == kind
                    Button { destinationKind = kind } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Image(systemName: kind.icon).font(.title2).foregroundStyle(ArchiveStyle.link)
                            Text(kind.title).font(.subheadline.weight(.semibold)).foregroundStyle(ArchiveStyle.ink)
                        }
                        .multilineTextAlignment(.leading)
                        .padding(12)
                        .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
                        .background(Brand.surface, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(on ? ArchiveStyle.action : Color.clear, lineWidth: 2.5))
                        .overlay(alignment: .topTrailing) {
                            if on { Image(systemName: "checkmark.circle.fill").foregroundStyle(ArchiveStyle.action).padding(8) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(kind.title)
                    .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            .onChange(of: destinationKind) {
                destination = nil
                availableGB = ""
                archiveConsent = false
                folderCheck = nil
                // A drive chosen before is used straight away when it's plugged in.
                if destinationKind == .drive, let status = drive.status { useSavedDrive(status.url) }
            }
            .task { await drive.watch() }
            if let destinationKind {
                HStack(alignment: .top, spacing: 4) {
                    Text(destinationKind.detail).font(.footnote).foregroundStyle(.secondary)
                    if destinationKind == .drive {
                        InfoButton(title: "Which drive?",
                                   text: "Any drive you already have can work. No drive yet? A portable USB-C SSD formatted as ExFAT works best. Spinning hard drives may need their own power supply to run from an \(Device.name).")
                    }
                }
                if destinationKind == .drive { drivePanel }
                if destinationKind == .google {
                    googleConnection
                } else if let service = destinationKind.cloud {
                    cloudConnection(account(service))
                } else {
                Button { showArchiveFolder = true } label: {
                    Label(destination.map { "Change folder (\($0.lastPathComponent))" } ?? "Choose archive folder in Files",
                          systemImage: "folder.badge.plus")
                }
                }
                if checkingFolder {
                    ProgressView("Checking this folder…")
                } else if let folderCheck {
                    if let problem = folderCheck.problem {
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Brand.caution)
                            .accessibilityIdentifier("folder-problem")
                    } else {
                        Label(folderCheck.available.map { "Ready. \(formattedBytes($0)) free here." } ?? "Ready to save here.",
                              systemImage: "checkmark.circle")
                            .foregroundStyle(Brand.safe)
                            .accessibilityIdentifier("folder-ready")
                        if folderCheck.isFAT32 {
                            Text("This drive uses FAT32, which can't hold a single file over 4 GB. Long videos need an ExFAT drive.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                if destination != nil, folderCheck?.available == nil {
                    TextField("Available space shown by provider (GB, optional)", text: $availableGB)
                        .keyboardType(.decimalPad)
                        .onChange(of: availableGB) { archiveConsent = false }
                    Text("Files doesn’t supply a verified account quota. Use the available space shown by your provider for an estimate.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if destinationKind == .other || destinationKind == .home || destinationKind == .shared {
                    Text("Deleting from your \(Device.name) afterwards is offered only when TidyAway can confirm the copy is safe there. Cloud apps other than iCloud Drive and Google Drive can't confirm it.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var drivePanel: some View {
        if let saved = drive.drive {
            Button { path.append(ArchiveRoute.drive) } label: {
                DriveCard(name: saved.name, status: drive.status)
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .accessibilityIdentifier("drive-open")
            if let status = drive.status, destination == nil {
                Button("Use this drive") { useSavedDrive(status.url) }
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("drive-use")
            }
        }
        Button { showDriveHelp = true } label: { Label("Don't see your drive?", systemImage: "questionmark.circle") }
            .accessibilityIdentifier("drive-help")
            .sheet(isPresented: $showDriveHelp) { DriveHelpView() }
    }

    private func useSavedDrive(_ folder: URL) {
        destination = folder
        availableGB = ""
        archiveConsent = false
        checkFolder(folder)
    }

    @ViewBuilder
    private var googleConnection: some View {
        if let email = google.email {
            Label("Connected as \(email)", systemImage: "checkmark.circle")
                .foregroundStyle(Brand.safe)
                .accessibilityIdentifier("google-connected")
            savingTo(.google)
            Button("Disconnect Google Drive", role: .destructive) { Task { await google.disconnect() } }
                .font(.footnote)
        } else {
            Button {
                Task { await google.connect() }
            } label: {
                Label(google.busy ? "Waiting for Google…" : "Connect Google Drive", systemImage: "person.badge.key")
            }
            .disabled(google.busy)
            .accessibilityIdentifier("google-connect")
            Text("Google asks you to allow access. TidyAway can never see, change or delete your other Drive files.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        if let message = google.message {
            Text(message).font(.footnote).foregroundStyle(Brand.caution)
        }
    }

    private func account(_ service: CloudService) -> CloudAccount { service == .oneDrive ? oneDrive : dropbox }

    /// Where copies will be saved, with buttons to choose or make a folder and to open it.
    @ViewBuilder
    private func savingTo(_ place: OnlinePlace) -> some View {
        let folder = OnlineFolders.chosen(place)
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text("Saving to ").foregroundStyle(.secondary) + Text(folder.shown(in: place)).bold()
            } icon: {
                Image(systemName: "folder.fill").foregroundStyle(ArchiveStyle.link)
            }
            .font(.footnote)
            .id(folderChoice)
            .accessibilityIdentifier("online-folder-path")
            HStack(spacing: 16) {
                Button { pickingFolder = place } label: {
                    Label("Choose or create folder", systemImage: "folder.badge.plus")
                }
                .accessibilityIdentifier("online-folder-choose")
                Button {
                    Task {
                        // OneDrive is asked for the folder's real address; the others have fixed ones.
                        var link = OnlineFolders.link(folder, place: place)
                        if place == .oneDrive, let token = try? await folderToken(place)(),
                           let exact = await OnlineFolders.oneDriveWebLink(folder, token: token) {
                            link = exact
                        }
                        if let link { openURL(link) }
                    }
                } label: {
                    Label("Open in \(place.name)", systemImage: "arrow.up.right.square")
                }
                .accessibilityIdentifier("online-folder-open")
            }
            .font(.footnote.weight(.semibold))
        }
    }

    private func folderToken(_ place: OnlinePlace) -> () async throws -> String {
        switch place {
        case .google: { [google] in try await google.accessToken() }
        case .oneDrive: { [oneDrive] in try await oneDrive.accessToken() }
        case .dropbox: { [dropbox] in try await dropbox.accessToken() }
        }
    }

    @ViewBuilder
    private func cloudConnection(_ account: CloudAccount) -> some View {
        let name = account.service.name
        if account.connected {
            Label("Connected as \(account.name ?? name)", systemImage: "checkmark.circle")
                .foregroundStyle(Brand.safe)
                .accessibilityIdentifier("cloud-connected")
            savingTo(OnlinePlace(account.service))
            Button("Disconnect \(name)", role: .destructive) { Task { await account.disconnect() } }
                .font(.footnote)
        } else {
            Button {
                Task { await account.connect() }
            } label: {
                Label(account.busy ? "Waiting for \(name)…" : "Connect \(name)", systemImage: "person.badge.key")
            }
            .disabled(account.busy)
            .accessibilityIdentifier("cloud-connect")
            if account.needsReconnect {
                Text("Sign in to OneDrive again. TidyAway now saves to My files › TidyAway, so you can see your copies in OneDrive, its search and Media. Copies made before stay reachable in Get back.")
                    .font(.footnote).foregroundStyle(Brand.caution)
                    .accessibilityIdentifier("cloud-reconnect")
            }
            Text(account.service == .oneDrive
                 ? "Microsoft asks you to allow access to your files. TidyAway only adds files to its TidyAway folder in My files; it never opens, changes or deletes anything else."
                 : "\(name) asks you to allow access. TidyAway can never see, change or delete your other files there.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        if let message = account.message {
            Text(message).font(.footnote).foregroundStyle(Brand.caution)
        }
    }

    // MARK: - Filter

    private var filterScreen: some View {
        List {
            if let snapshot, !snapshot.includedCloudDownloads {
                Section("Filter") {
                    Picker("Taken", selection: $age) {
                        ForEach(Age.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Size", selection: $sizeFloor) {
                        ForEach(SizeFloor.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Kind", selection: $kind) {
                        ForEach(ArchiveKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    if !groupsOpen {
                        Button { askPro(.archiveGroups, pushed: true) } label: {
                            LabeledContent {
                                ProBadge()
                            } label: {
                                Label("Choose by album or place", systemImage: "line.3.horizontal.decrease.circle")
                            }
                        }
                        .accessibilityIdentifier("archive-filters-pro")
                    } else if let albums = snapshot.albums {
                        if !albums.isEmpty {
                            Picker("Album", selection: $albumID) {
                                Text("Any album").tag(String?.none)
                                ForEach(albums) { Text($0.title).tag(Optional($0.id)) }
                            }
                        }
                        if snapshot.assets.contains(where: { $0.latitude != nil }) {
                            Button { showPlacePicker = true } label: {
                                LabeledContent {
                                    Text(place == nil ? "Anywhere" : "Area on map")
                                } label: {
                                    Label("Place", systemImage: "map")
                                }
                            }
                            .accessibilityIdentifier("archive-place")
                            if place != nil {
                                Button("Clear place") { place = nil }
                            }
                        }
                    } else {
                        Text("Scan again to also choose by album or place.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Button { showSuggestions(from: snapshot) } label: {
                        HStack(spacing: 8) {
                            Label(kind == .videos ? "Show matching videos" : "Show matching photos", systemImage: "line.3.horizontal.decrease.circle")
                            if findingSuggestions { ProgressView().accessibilityLabel("Looking") }
                        }
                    }
                    .disabled(findingSuggestions)
                    Button {
                        guard groupsOpen else {
                            askPro(.archiveGroups, pushed: true)
                            return
                        }
                        kind = .videos
                        sizeFloor = .twentyFive
                        age = .any
                        albumID = nil
                        place = nil
                        showSuggestions(from: snapshot)
                    } label: {
                        proLabel("Suggest large videos", systemImage: "film.stack", locked: !groupsOpen)
                    }
                    .accessibilityIdentifier("archive-suggest-videos")
                }
                if showSuggested {
                    Section {
                        let matchingBytes = suggested.compactMap { bytes(for: $0) }.reduce(Int64(0), +)
                        LabeledContent(kind == .videos ? "Matching videos" : "Matching photos", value: "\(suggested.count.formatted()) · \(formattedBytes(matchingBytes))")
                        if suggested.isEmpty {
                            Text("Nothing from your last scan matches. Try a wider choice.")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            Button("Add all \(suggested.count.formatted()) to the selection") {
                                for item in suggested { add(item) }
                            }
                            if suggested.count == Self.suggestionLimit {
                                Text("Showing the \(Self.suggestionLimit) largest matches. Archive these, then choose again for more.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        let chosen = Set(items.map(\.id))
                        ForEach(suggested) { item in
                            Button { toggle(item) } label: {
                                Label {
                                    VStack(alignment: .leading) {
                                        Text(item.name)
                                        Text(item.sourceLabel).font(.caption).foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    Image(systemName: chosen.contains(item.id) ? "checkmark.circle.fill" : "plus.circle")
                                }
                            }
                        }
                    }
                }
            } else {
                Text("Scan your photos first.")
            }
        }
        .navigationTitle("Filter")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if !items.isEmpty { nextBar }
        }
        .sheet(isPresented: $showPlacePicker) {
            if let snapshot { PlacePickerSheet(place: $place, snapshot: snapshot) }
        }
        .sheet(isPresented: $showProPushed) { proSheet($showProPushed) }
    }

    // MARK: - Copy

    private var selectedBytes: Int64 { items.compactMap { bytes(for: $0) }.reduce(Int64(0), +) }
    private var unmeasured: Int { items.filter { bytes(for: $0) == nil }.count }
    private var comparison: ArchiveCapacity { ArchiveCapacity(selected: selectedBytes, available: availableBytes) }
    /// What an item counts for against the free 5 GB: its measured size, or else the size the scan or
    /// Photos reported. Nil when nothing is known yet.
    private func allowanceBytes(for item: ArchiveItem) -> Int64? {
        bytes(for: item) ?? item.size ?? estimatedBytes[item.id]
    }
    private var allowanceSelection: Int64 { items.compactMap { allowanceBytes(for: $0) }.reduce(Int64(0), +) }
    /// On a free plan, items whose size isn't known at all. Copying waits until they are measured,
    /// so the free 5 GB can't be passed by items it didn't count.
    private var unsizedForAllowance: Int {
        pro.allows(.unlimitedArchive) ? 0 : items.filter { allowanceBytes(for: $0) == nil }.count
    }
    private var allowance: ArchiveAllowance { ProStore.archiveAllowance(used: archivedBytes, selection: allowanceSelection, unlocked: pro.allows(.unlimitedArchive)) }
    private var overAllowance: Bool {
        if unsizedForAllowance > 0 { return true }
        if case .over = allowance { return true } else { return false }
    }
    /// The sizes the run keeps the free 5 GB with, by item.
    private var allowanceSizes: [String: Int64] {
        var sizes: [String: Int64] = [:]
        for item in items { if let size = allowanceBytes(for: item) { sizes[item.id] = size } }
        return sizes
    }
    private var toGoogle: Bool { destinationKind == .google && google.email != nil }
    /// OneDrive or Dropbox, once connected.
    private var toCloud: CloudService? {
        guard let service = destinationKind?.cloud, account(service).connected else { return nil }
        return service
    }
    private var toOnline: Bool { toGoogle || toCloud != nil }
    private var hasDestination: Bool {
        toOnline || (destinationKind != .google && destinationKind?.cloud == nil && destination != nil)
    }

    private var canCopy: Bool {
        guard archiveConsent, !busy, !items.isEmpty, hasDestination, !overAllowance else { return false }
        if toOnline { return true }
        return comparison.fits != false && (availableGB.isEmpty || availableBytes != nil)
            && folderCheck?.problem == nil && !checkingFolder && tooBigForDrive.isEmpty
    }

    private var consentLine: String {
        let count = "\(items.count.formatted()) \(items.count == 1 ? "item" : "items")"
        if toGoogle { return "I authorize copying \(count) to Google Drive (\(google.email ?? ""))." }
        if let service = toCloud { return "I authorize copying \(count) to \(service.name) (\(account(service).name ?? service.name))." }
        return "I authorize copying \(count) to \(destination?.lastPathComponent ?? "this folder")."
    }

    private var consentText: String {
        if let service = toCloud {
            return "I authorize copying these items to \(service.name) (\(account(service).name ?? service.name)), in \(OnlineFolders.chosen(OnlinePlace(service)).shown(in: OnlinePlace(service))). Source items stay where they are and this step frees no space."
        }
        return toGoogle
            ? "I authorize copying these items to Google Drive (\(google.email ?? "")), in \(OnlineFolders.chosen(.google).shown(in: .google)). Source items stay where they are and this step frees no space."
            : "I authorize copying these items to this folder. Files providers may download selected files and sync these copies. Source items stay where they are and this step frees no space."
    }

    private var copyScreen: some View {
        List {
            Section {
                Text("\(items.count.formatted()) \(items.count == 1 ? "item" : "items") · \(formattedBytes(selectedBytes))")
                    .font(.title.bold())
                    .accessibilityIdentifier("copy-summary")
                if let message { Text(message).font(.footnote) }
            }
            destinationSection
            Section("Check") { checks }
            Section {
                DisclosureGroup("Review \(items.count.formatted()) \(items.count == 1 ? "item" : "items")", isExpanded: $showReview) {
                    ForEach(items) { item in
                        Button { toggle(item) } label: {
                            HStack {
                                if case .photo(let id, _) = item.source {
                                    AssetThumbnail(assetID: id)
                                }
                                VStack(alignment: .leading) {
                                    Text(item.name).foregroundStyle(.primary)
                                    Text(item.sourceLabel).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "minus.circle").accessibilityHidden(true)
                            }
                        }
                        .contextMenu {
                            Button("Remove from selection") { toggle(item) }
                        } preview: {
                            if case .photo(let id, _) = item.source {
                                AssetCover(assetID: id, side: 1000).frame(width: 320, height: 420)
                            } else {
                                Label(item.name, systemImage: "doc").padding(30)
                            }
                        }
                        .accessibilityLabel("Remove \(item.name) from selection")
                    }
                }
                .accessibilityIdentifier("copy-review")
                Button(role: .destructive) {
                    startOver()
                    path = NavigationPath()
                } label: {
                    Label("Clear selection and start over", systemImage: "xmark.circle")
                }
                .accessibilityIdentifier("copy-clear")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Brand.background)
        .disabled(busy)
        .navigationTitle("Copy")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(busy)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if hasDestination {
                    HStack(spacing: 4) {
                        Button { archiveConsent.toggle() } label: {
                            Label(consentLine, systemImage: archiveConsent ? "checkmark.square.fill" : "square")
                                .font(.subheadline)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityAddTraits(archiveConsent ? .isSelected : [])
                        .accessibilityIdentifier("archive-consent")
                        InfoButton(title: "What you're agreeing to", text: consentText)
                    }
                }
                Button(hasDestination ? "Copy \(items.count.formatted()) \(items.count == 1 ? "item" : "items")" : "Choose where to copy above") {
                    if toGoogle { beginDriveCopy() } else if let service = toCloud { beginCloudCopy(service) } else { beginCopy() }
                }
                .buttonStyle(ArchiveButtonStyle())
                .disabled(!canCopy)
                .accessibilityIdentifier("archive-copy")
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.regularMaterial)
            .disabled(busy)
        }
        .modifier(FolderPicker(isPresented: $showArchiveFolder, pick: setDestination))
        .sheet(isPresented: $showProPushed) { proSheet($showProPushed) }
    }

    @ViewBuilder
    private var checks: some View {
        LabeledContent(unmeasured == 0 ? "Selected size" : "Known selected size", value: formattedBytes(selectedBytes))
        if checkingSizes {
            ProgressView("Checking selected sizes…")
        } else if unmeasured > 0 {
            Button("Check sizes of \(unmeasured) items", action: measureSelection)
        }
        if !toOnline, let available = comparison.available {
            LabeledContent("Available space", value: formattedBytes(available))
        }
        if !toOnline {
            if comparison.fits == false {
                Label("This selection doesn't fit. Remove items or choose a different folder.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Brand.caution)
            } else if unmeasured == 0, comparison.fits == true {
                Label("Fits. Your provider makes the final capacity check.", systemImage: "checkmark.circle").foregroundStyle(Brand.safe)
            } else if destination != nil {
                Text(unmeasured > 0 && comparison.available != nil
                     ? "Check the remaining item sizes for a complete comparison, or try a small batch."
                     : "Capacity is unconfirmed. You can enter the available space shown by your provider or try a small batch.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if !availableGB.isEmpty && availableBytes == nil {
                Text("Enter available space as a number in GB.").foregroundStyle(.secondary)
            }
        }
        if unsizedForAllowance > 0 {
            Text("Check the sizes of \(unsizedForAllowance.formatted()) \(unsizedForAllowance == 1 ? "item" : "items") first, or remove \(unsizedForAllowance == 1 ? "it" : "them"). Your free 5 GB counts every item.")
                .font(.footnote).foregroundStyle(Brand.caution)
                .accessibilityIdentifier("archive-allowance-unsized")
        }
        switch allowance {
        case .unlimited:
            EmptyView()
        case .fits(let left):
            Text("Free archive: \(formattedBytes(left)) of 5 GB left.")
                .font(.footnote).foregroundStyle(.secondary)
                .accessibilityIdentifier("archive-allowance")
        case .over(let left):
            VStack(alignment: .leading, spacing: 8) {
                Text("This selection is \(formattedBytes(allowanceSelection)). \(formattedBytes(left)) of your free 5 GB archive is left. Remove some items, or unlock Pro to archive without a limit.")
                Button("See TidyAway Pro") { askPro(.unlimitedArchive, pushed: true) }
            }
            .accessibilityIdentifier("archive-allowance")
        }
        if !toOnline, !tooBigForDrive.isEmpty {
            Text("\(tooBigForDrive.count) selected \(tooBigForDrive.count == 1 ? "item is" : "items are") over 4 GB, too big for this FAT32 drive. Remove \(tooBigForDrive.count == 1 ? "it" : "them") or use an ExFAT drive.")
                .font(.footnote).foregroundStyle(Brand.caution)
        }
    }

    // MARK: - Run and results

    @ViewBuilder
    private var runCover: some View {
        if let outcome = run.outcome {
            ArchiveDoneView(outcome: outcome,
                            note: outcome.completion.flatMap(completionNote),
                            canDelete: RemovalAfterArchive.enabled && model != nil && !(outcome.completion?.removable.isEmpty ?? true),
                            openDrive: driveLink(outcome.completion?.driveFolderID),
                            delete: { removal = outcome.completion },
                            getBack: {
                                closeRun()
                                showArchived?()
                            },
                            details: { showRunDetails = true },
                            close: closeRun)
                .sheet(item: $removal) { done in
                    if let model {
                        NavigationStack { ArchivedRemovalView(done: done, model: model) }
                    }
                }
                .sheet(isPresented: $showRunDetails) { detailsSheet }
        } else {
            ArchiveProgressView(run: run, usesDrive: destinationKind == .google || destinationKind?.cloud != nil)
        }
    }

    private func driveLink(_ folder: String?) -> (() -> Void)? {
        guard let folder, let url = URL(string: "https://drive.google.com/drive/folders/\(folder)") else { return nil }
        return { openURL(url) }
    }

    private func closeRun() {
        // The result screen is closing: an archive that copied something counts toward the rating
        // prompt, which may show now that nothing else is on screen.
        if run.outcome?.completion != nil {
            RatingPrompt.noteCompletion()
            ratingTrigger += 1
        }
        showRun = false
        path = NavigationPath()
    }

    private var detailsSheet: some View {
        NavigationStack {
            List {
                if let message { Section { Text(message) } }
                resultsSection
                if let restoreTarget { restoreSection(restoreTarget) }
            }
            .disabled(busy)
            .navigationTitle("Results")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        showDetails = false
                        showRunDetails = false
                    }
                    .disabled(busy)
                }
            }
            .modifier(FolderPicker(isPresented: $showRestoreFolder) { folder in
                restoreFolder = folder
                restoreConsent = false
            })
        }
    }

    /// A locked Archive feature opens the half sheet; "See all plans" there opens the Pro page.
    private func proSheet(_ shown: Binding<Bool>) -> some View {
        ProFeatureSheet(offer: .archive(lockedFeature))
            .environmentObject(pro)
    }

    private func askPro(_ feature: ProFeature, pushed: Bool = false) {
        lockedFeature = feature
        if pushed { showProPushed = true } else { showPro = true }
    }

    /// A Pro choice keeps its own icon and adds the PRO badge while it is locked, as on Free up.
    private func proLabel(_ title: String, systemImage: String, locked: Bool) -> some View {
        HStack(spacing: 6) {
            Label(title, systemImage: systemImage)
            if locked { ProBadge() }
        }
    }

    private func setDestination(_ folder: URL) {
        useSavedDrive(folder)
        if destinationKind == .drive {
            SavedDrive.remember(folder)
            Task { await drive.refresh() }
        }
    }

    private var availableBytes: Int64? {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        guard let gb = formatter.number(from: availableGB)?.doubleValue, gb >= 0, gb < 9_000_000_000 else { return nil }
        return Int64(gb * 1_000_000_000)
    }

    private func bytes(for item: ArchiveItem) -> Int64? {
        // A Live Photo or edited photo is every one of its files together.
        if let parts = item.expectedParts, !parts.isEmpty { return parts.reduce(0) { $0 + $1.bytes } }
        if let parts = checkedParts[item.id] { return parts.reduce(0) { $0 + $1.bytes } }
        if case .photo(_, let expected?) = item.source { return expected.bytes }
        return measuredBytes[item.id]
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Items copied side by side. Photos may be downloading from iCloud while others are written.
    static let copiesAtOnce = 6

    private func measureSelection() {
        let selection = items.filter { bytes(for: $0) == nil }
        busy = true
        checkingSizes = true
        archiveConsent = false
        message = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                var sizes: [String: Int64] = [:]
                var photos: [String: ResourceFingerprint] = [:]
                var parts: [String: [ResourceFingerprint]] = [:]
                let scanner = DuplicateScanner()
                for item in selection {
                    switch item.source {
                    case .photo(let id, _):
                        if let fingerprints = try? await scanner.archiveFingerprints(for: id), let fingerprint = fingerprints.first {
                            sizes[item.id] = fingerprints.reduce(0) { $0 + $1.bytes }
                            photos[item.id] = fingerprint
                            if fingerprints.count > 1 { parts[item.id] = fingerprints }
                        }
                    case .file(let url):
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                            sizes[item.id] = Int64(size)
                        }
                    }
                }
                // What Photos reports for the rest, so the free 5 GB counts them too. Nothing is downloaded.
                let unmeasuredPhotos = selection.compactMap { item -> (String, String)? in
                    guard sizes[item.id] == nil, case .photo(let id, _) = item.source else { return nil }
                    return (item.id, id)
                }
                let estimates = FreeArchiveBudget.reportedSizes(unmeasuredPhotos)
                return (sizes, photos, parts, estimates)
            }.value
            measuredBytes.merge(result.0) { _, new in new }
            checkedPhotos.merge(result.1) { _, new in new }
            checkedParts.merge(result.2) { _, new in new }
            estimatedBytes.merge(result.3) { _, new in new }
            if result.0.count < selection.count {
                message = "Some items are stored in iCloud, so their size shows once they are copied. TidyAway downloads them while copying."
            }
            checkingSizes = false
            busy = false
        }
    }

    private var resultsSection: some View {
        Section("Copy results") {
            ForEach(receipts) { receipt in
                VStack(alignment: .leading, spacing: 6) {
                    Label(receipt.url.lastPathComponent, systemImage: "checkmark.circle")
                    Text(restored.contains(receipt.id) ? "Restored bytes verified" : "Copied, same size as the original")
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
                Text("Each copy was checked to be the same size as its original. A test restore brings one back and checks it in full. This can't confirm provider sync. Keep this screen open to test a restore.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func restoreSection(_ receipt: ArchiveReceipt) -> some View {
        Section("Test restore") {
            Text(receipt.url.lastPathComponent)
            Button { showRestoreFolder = true } label: {
                Label(restoreFolder.map { "Change folder (\($0.lastPathComponent))" } ?? "Choose a different restore folder", systemImage: "folder")
            }
            if let restoreFolder {
                Text(restoreFolder.path(percentEncoded: false))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Toggle("I authorize creating a test copy here. It uses storage and the folder’s provider may sync it. The archive copy stays in place.", isOn: $restoreConsent)
                Button("Get back and verify", action: beginRestore)
                    .fontWeight(.semibold)
                    .disabled(!restoreConsent)
            }
        }
    }

    private func addFiles(_ result: Result<[URL], Error>) {
        do {
            for url in try result.get() {
                add(ArchiveItem(id: url.absoluteString, name: url.lastPathComponent, source: .file(url)))
            }
        } catch {
            message = "Could not open the selection. \(error.localizedDescription)"
        }
    }

    private func addPhotos(_ selection: [PhotosPickerItem]) {
        guard !selection.isEmpty else { return }
        let ids = selection.map(\.itemIdentifier)
        photoSelection = []
        // Looking each one up in Photos happens off the main thread, so a big selection doesn't freeze the screen.
        Task {
            let found = await Task.detached(priority: .userInitiated) { () -> [ArchiveItem] in
                let known = ids.compactMap { $0 }
                var names: [String: String] = [:]
                PHAsset.fetchAssets(withLocalIdentifiers: known, options: nil).enumerateObjects { asset, _, _ in
                    names[asset.localIdentifier] = VerifiedArchive.primary(for: asset)?.originalFilename
                }
                return known.compactMap { id in
                    names[id].map { ArchiveItem(id: id, name: $0, source: .photo(id, expected: nil)) }
                }
            }.value
            for item in found { add(item) }
            let skipped = ids.count - found.count
            message = skipped == 0 ? nil : "\(skipped.formatted()) selected items were unavailable with current Photos access or had an unsupported format. Run a local scan to check Photos access."
        }
    }

    private func showSuggestions(from snapshot: ScanSnapshot) {
        let filter = ArchiveSuggestionFilter(olderThanYears: age.years, minimumBytes: sizeFloor.bytes, kind: kind,
                                             albumID: albumID, place: place, limit: Self.suggestionLimit)
        guard !findingSuggestions else { return }
        findingSuggestions = true
        // Matching and the Photos lookups run off the main thread; a large library took seconds here.
        Task {
            let found = await Task.detached(priority: .userInitiated) { () -> [ArchiveItem] in
                let records = filter.matches(in: snapshot)
                let assets = PHAsset.fetchAssets(withLocalIdentifiers: records.map(\.id), options: nil)
                var names: [String: String] = [:]
                assets.enumerateObjects { asset, _, _ in
                    names[asset.localIdentifier] = VerifiedArchive.primary(for: asset)?.originalFilename
                }
                return records.compactMap { record -> ArchiveItem? in
                    guard let name = names[record.id] else { return nil }
                    return ArchiveItem(id: record.id, name: name, source: .photo(record.id, expected: ArchivePlan.primaryFingerprint(of: record)),
                                       size: record.displayBytes > 0 ? record.displayBytes : nil,
                                       expectedParts: ArchivePlan.partFingerprints(of: record))
                }
            }.value
            suggested = found
            showSuggested = true
            findingSuggestions = false
        }
    }

    private func add(_ item: ArchiveItem) {
        guard !items.contains(where: { $0.id == item.id }) else { return }
        items.append(item)
        archiveConsent = false
    }

    private func toggle(_ item: ArchiveItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items.remove(at: index)
            measuredBytes[item.id] = nil
            checkedPhotos[item.id] = nil
            checkedParts[item.id] = nil
            estimatedBytes[item.id] = nil
            archiveConsent = false
        } else {
            add(item)
        }
    }

    /// Uploads each item to OneDrive or Dropbox and matches the service's own fingerprint of what it stored.
    private func beginCloudCopy(_ service: CloudService) {
        let account = account(service)
        guard !busy, archiveConsent, account.connected, !items.isEmpty, !overAllowance else { return }
        let selection = items.map { item in
            if case let .photo(id, nil) = item.source, let measured = checkedPhotos[item.id] {
                return ArchiveItem(id: item.id, name: item.name, source: .photo(id, expected: measured),
                                   expectedParts: checkedParts[item.id])
            }
            return item
        }
        archiveConsent = false
        guard let operation = authorize("archive copy to \(service.name)", count: selection.count) else { return }
        busy = true
        message = nil
        restoreTarget = nil
        run.start(selection.count)
        showRun = true
        UIApplication.shared.isIdleTimerDisabled = true
        run.holdBackgroundTime()
        let folder = OnlineFolders.chosen(OnlinePlace(service))
        let sizes = allowanceSizes
        let network = wifi
        let placeID = PlaceIdentity.online(folder)
        let unlimited = pro.allows(.unlimitedArchive)
        Task {
            // The free 5 GB is checked again for each item as it starts, against what is archived now.
            var budget = FreeArchiveBudget(used: await FreeArchiveBudget.usedNow(), unlimited: unlimited)
            // An item whose confirmed copy is already in this place, unchanged and still there at the
            // same size, is not copied again (1.0.2). Another photo with the same name still gets "(2)".
            let here = await AlreadyArchivedHere.find(selection, wifi: network) { $0.cloud == service && $0.folderID == placeID }
            run.alreadyHere = here.count
            run.tried += here.count
            if service == .oneDrive, let token = try? await account.accessToken() {
                try? await OnlineFolders.prepareOneDrive(folder, token: token)
            }
            let started = Date()
            var records: [ArchivedRecord] = []
            var copies: [String: ArchivedRecord] = [:]
            var problems: [String] = []
            var copiedItems: [ArchiveItem] = []
            await withTaskGroup(of: (ArchiveItem, Result<(upload: CloudUpload, parts: [ArchivedPart]), Error>).self) { group in
                var waiting = selection.filter { !here.contains($0.id) }[...]
                var running = 0
                while true {
                    while running < Self.copiesAtOnce, !run.stopping, let item = waiting.popFirst() {
                        guard budget.take(sizes[item.id]) else {
                            problems.append("\(item.name) — \(OverFreeArchive().localizedDescription)")
                            run.failed(OverFreeArchive())
                            run.tried += 1
                            continue
                        }
                        run.currentID = Self.photoID(item)
                        running += 1
                        let token = try? await account.accessToken()
                        group.addTask {
                            guard let token else { return (item, .failure(CloudError.notConnected(service.name))) }
                            return (item, await Result(awaiting: { try await CloudArchive.uploadEvery(item, to: service, token: token, folder: folder) }))
                        }
                    }
                    guard let next = await group.next() else { break }
                    let (item, outcome) = next
                    running -= 1
                    switch outcome {
                    case .success(let stored):
                        let uploaded = stored.upload
                        let record = ArchivedRecord(id: UUID().uuidString, name: uploaded.name, folderName: folder.label(in: OnlinePlace(service)),
                                                    bytes: uploaded.fingerprint.bytes, digest: uploaded.fingerprint.digest, date: Date(),
                                                    viaHomeServer: false, folderBookmark: nil, driveFileID: uploaded.fileID,
                                                    photoID: Self.photoID(item), cloud: service, cloudHash: uploaded.serviceHash,
                                                    parts: stored.parts.isEmpty ? nil : stored.parts).remembering(PhotoDetails.of(Self.photoID(item))).placed(placeID)
                        records.append(record)
                        copiedItems.append(item)
                        run.copied += 1
                        run.bytes += record.totalBytes
                        // Saved as each item finishes, so an interrupted run keeps what it already copied.
                        if Self.save(record) { copies[item.id] = record } else { problems.append(Self.notSaved(item)) }
                        budget.settle(took: sizes[item.id], actual: record.totalBytes)
                    case .failure(let error):
                        problems.append("\(item.name) — \(error.localizedDescription)")
                        run.failed(error)
                        budget.giveBack(sizes[item.id])
                    }
                    run.tried += 1
                }
            }
            refreshArchivedBytes()
            let copiedIDs = Set(copiedItems.map(\.id))
            failures = problems
            items.removeAll { copiedIDs.contains($0.id) || here.contains($0.id) }
            message = nil
            let completion = records.isEmpty ? nil : ArchiveCompletion(items: copiedItems, bytes: records.reduce(0) { $0 + $1.totalBytes },
                                                                       place: service.name, driveFolderID: nil, copies: copies)
            run.outcome = ArchiveOutcome(completion: completion, failures: problems,
                                         left: run.stopping ? selection.count - run.tried : 0, place: service.name,
                                         alreadyHere: here.count)
            recordOutcome("Archive copy to \(service.name) \(operation) completed. Verified \(records.count) of \(selection.count) items in \(Self.seconds(since: started)), \(Self.throughput(records.reduce(0) { $0 + $1.totalBytes }, since: started)).")
            UIApplication.shared.isIdleTimerDisabled = false
            run.releaseBackgroundTime()
            busy = false
        }
    }

    /// Streams each item to Google Drive and checks Drive's own checksum against the original.
    private func beginDriveCopy() {
        guard !busy, archiveConsent, google.connected, !items.isEmpty, !overAllowance else { return }
        let selection = items.map { item in
            if case let .photo(id, nil) = item.source, let measured = checkedPhotos[item.id] {
                return ArchiveItem(id: item.id, name: item.name, source: .photo(id, expected: measured),
                                   expectedParts: checkedParts[item.id])
            }
            return item
        }
        archiveConsent = false
        guard let operation = authorize("archive copy to Google Drive", count: selection.count) else { return }
        busy = true
        message = nil
        restoreTarget = nil
        let account = google
        run.start(selection.count)
        showRun = true
        UIApplication.shared.isIdleTimerDisabled = true
        run.holdBackgroundTime()
        let sizes = allowanceSizes
        let network = wifi

        let unlimited = pro.allows(.unlimitedArchive)
        Task {
            // The free 5 GB is checked again for each item as it starts, against what is archived now.
            var budget = FreeArchiveBudget(used: await FreeArchiveBudget.usedNow(), unlimited: unlimited)
            // Filled in once the Drive folder's ID is known, below.
            var here: Set<String> = []
            let started = Date()
            var records: [ArchivedRecord] = []
            var copies: [String: ArchivedRecord] = [:]
            var problems: [String] = []
            var copiedItems: [ArchiveItem] = []
            var driveFolder: String?
            do {
                let chosen = OnlineFolders.chosen(.google)
                let folderID = chosen.isRoot ? try await GoogleDriveClient.archiveFolder(token: try await account.accessToken()) : chosen.id
                driveFolder = folderID
                // An item whose confirmed copy is already in this Drive folder (by its ID), unchanged and
                // still there at the same size, is not copied again (1.0.2). Another photo with the same
                // name still gets "(2)".
                here = await AlreadyArchivedHere.find(selection, wifi: network) {
                    $0.cloud == nil && $0.driveFileID != nil && $0.folderID == folderID
                }
                run.alreadyHere = here.count
                run.tried += here.count
                let found = here
                await withTaskGroup(of: (ArchiveItem, Result<(fileID: String, fingerprint: ArchiveFingerprint, parts: [ArchivedPart]), Error>).self) { group in
                var waiting = selection.filter { !found.contains($0.id) }[...]
                var running = 0
                while true {
                    while running < Self.copiesAtOnce, !run.stopping, let item = waiting.popFirst() {
                        guard budget.take(sizes[item.id]) else {
                            problems.append("\(item.name) — \(OverFreeArchive().localizedDescription)")
                            run.failed(OverFreeArchive())
                            run.tried += 1
                            continue
                        }
                        run.currentID = Self.photoID(item)
                        running += 1
                        // A fresh token per item; each item streams straight from Photos or Files to
                        // Drive in small pieces, so no full copy needs room on this iPhone.
                        let token = try? await account.accessToken()
                        group.addTask {
                            guard let token else { return (item, .failure(GoogleDriveError.notConnected)) }
                            return (item, Result { try GoogleDriveClient.streamUploadEvery(item, folderID: folderID, token: token) })
                        }
                    }
                    guard let next = await group.next() else { break }
                    let (item, outcome) = next
                    running -= 1
                    do {
                        let uploaded = try outcome.get()
                        let record = ArchivedRecord(id: UUID().uuidString, name: item.name,
                                                    folderName: chosen.label(in: .google), bytes: uploaded.fingerprint.bytes,
                                                    digest: uploaded.fingerprint.digest, date: Date(),
                                                    viaHomeServer: false, folderBookmark: nil, driveFileID: uploaded.fileID,
                                                    photoID: Self.photoID(item), parts: uploaded.parts.isEmpty ? nil : uploaded.parts).remembering(PhotoDetails.of(Self.photoID(item))).placed(folderID)
                        records.append(record)
                        copiedItems.append(item)
                        run.copied += 1
                        run.bytes += record.totalBytes
                        // Saved as each item finishes, so an interrupted run keeps what it already copied.
                        if Self.save(record) { copies[item.id] = record } else { problems.append(Self.notSaved(item)) }
                        budget.settle(took: sizes[item.id], actual: record.totalBytes)
                    } catch {
                        problems.append("\(item.name) — \(error.localizedDescription)")
                        run.failed(error)
                        budget.giveBack(sizes[item.id])
                    }
                    run.tried += 1
                }
                }
            } catch {
                problems.append(error.localizedDescription)
            }
            refreshArchivedBytes()
            let copiedIDs = Set(copiedItems.map(\.id))
            failures = problems
            items.removeAll { copiedIDs.contains($0.id) || here.contains($0.id) }
            message = nil
            let completion = records.isEmpty ? nil : ArchiveCompletion(items: copiedItems, bytes: records.reduce(0) { $0 + $1.totalBytes },
                                                                       place: "Google Drive", driveFolderID: driveFolder, copies: copies)
            run.outcome = ArchiveOutcome(completion: completion, failures: problems,
                                         left: run.stopping ? selection.count - run.tried : 0, place: "Google Drive",
                                         alreadyHere: here.count)
            recordOutcome("Archive copy to Google Drive \(operation) completed. Verified \(records.count) of \(selection.count) items in \(Self.seconds(since: started)), \(Self.throughput(records.reduce(0) { $0 + $1.totalBytes }, since: started)).")
            UIApplication.shared.isIdleTimerDisabled = false
            run.releaseBackgroundTime()
            busy = false
        }
    }

    private func beginCopy() {
        guard !busy, archiveConsent, let destination, !items.isEmpty, !overAllowance,
              availableGB.isEmpty || availableBytes != nil,
              folderCheck?.problem == nil, tooBigForDrive.isEmpty else { return }
        let selectedBytes = items.compactMap { bytes(for: $0) }.reduce(Int64(0), +)
        guard ArchiveCapacity(selected: selectedBytes, available: availableBytes).fits != false else { return }
        let home = destinationKind == .home
        let wifiCheck = wifi
        let selection = items.map { item in
            if case let .photo(id, nil) = item.source, let measured = checkedPhotos[item.id] {
                return ArchiveItem(id: item.id, name: item.name, source: .photo(id, expected: measured),
                                   expectedParts: checkedParts[item.id])
            }
            return item
        }
        archiveConsent = false
        guard let operation = authorize("archive copy", count: selection.count) else { return }
        busy = true
        message = nil
        restoreTarget = nil
        run.start(selection.count)
        showRun = true
        UIApplication.shared.isIdleTimerDisabled = true
        run.holdBackgroundTime()
        let sizes = allowanceSizes
        let placeID = PlaceIdentity.folder(destination)
        let unlimited = pro.allows(.unlimitedArchive)
        Task {
            // The free 5 GB is checked again for each item as it starts, against what is archived now.
            var budget = FreeArchiveBudget(used: await FreeArchiveBudget.usedNow(), unlimited: unlimited)
            // An item whose confirmed copy is already in this place, unchanged and still there at the
            // same size, is not copied again (1.0.2). Another photo with the same name still gets "(2)".
            let here = await AlreadyArchivedHere.find(selection, wifi: wifiCheck) { AlreadyArchivedHere.inFolder($0, placeID) }
            run.alreadyHere = here.count
            run.tried += here.count
            let started = Date()
            var successes: [ArchiveReceipt] = []
            // Every file of every item, so a Live Photo's video and an edit count toward the total.
            var copiedBytes: Int64 = 0
            var problems: [String] = []
            var copies: [String: ArchivedRecord] = [:]
            let bookmark = Self.bookmark(for: destination)
            let check: ArchiveWiFi? = home ? wifiCheck : nil
            await withTaskGroup(of: (ArchiveItem, Result<(receipt: ArchiveReceipt, parts: [ArchivedPart]), Error>).self) { group in
            var waiting = selection.filter { !here.contains($0.id) }[...]
            var running = 0
            while true {
                while running < Self.copiesAtOnce, !run.stopping, let item = waiting.popFirst() {
                    guard budget.take(sizes[item.id]) else {
                        problems.append("\(item.name) — \(OverFreeArchive().localizedDescription)")
                        run.failed(OverFreeArchive())
                        run.tried += 1
                        continue
                    }
                    run.currentID = Self.photoID(item)
                    running += 1
                    group.addTask { (item, Result { try VerifiedArchive.copyEvery(item, to: destination, wifi: check, flush: false) }) }
                }
                guard let next = await group.next() else { break }
                let (item, result) = next
                running -= 1
                switch result {
                case let .success(stored):
                    let receipt = stored.receipt
                    successes.append(receipt)
                    let record = ArchivedRecord(id: UUID().uuidString, name: receipt.url.lastPathComponent,
                                                folderName: destination.lastPathComponent, bytes: receipt.fingerprint.bytes,
                                                digest: receipt.fingerprint.digest, date: Date(),
                                                viaHomeServer: home, folderBookmark: bookmark, photoID: Self.photoID(item),
                                                parts: stored.parts.isEmpty ? nil : stored.parts, unflushed: true).remembering(PhotoDetails.of(Self.photoID(item))).placed(placeID)
                    run.copied += 1
                    run.bytes += record.totalBytes
                    copiedBytes += record.totalBytes
                    // Saved as each item finishes, so an interrupted run keeps what it already copied. It
                    // waits as unconfirmed, and counts as a backup only once the drive confirms it below.
                    if Self.save(record) { copies[item.id] = record } else { problems.append(Self.notSaved(item)) }
                    budget.settle(took: sizes[item.id], actual: record.totalBytes)
                case let .failure(error):
                    problems.append("\(item.name) — \(error.localizedDescription)")
                    run.failed(error)
                    budget.giveBack(sizes[item.id])
                }
                run.tried += 1
            }
            }
            // One flush for the whole batch. Until the drive confirms it, nothing may be deleted.
            if let last = successes.last {
                // Shown on the copy screen, since a large drive can take a while to finish writing.
                run.phase = "Making sure the drive saved everything…"
                let flushed = await Task.detached(priority: .userInitiated) {
                    (try? VerifiedArchive.flushDrive(last.url, in: destination)) != nil
                }.value
                if !flushed {
                    copies = [:]
                    problems.append("The drive didn't confirm it saved everything, so nothing can be deleted yet. The copies are on the drive; check them from the drive panel.")
                } else {
                    // Only now do the saved copies count as backups, as already archived and for removal.
                    let confirmed = copies.mapValues(\.confirming)
                    if Self.confirm(Array(confirmed.values)) {
                        copies = confirmed
                    } else {
                        copies = [:]
                        problems.append("The drive saved everything, but this \(Device.name) couldn't note that, so nothing can be deleted yet. The copies are on the drive; check them from the drive panel.")
                    }
                }
            }
            let copied = Set(successes.map(\.id))
            receipts.removeAll { copied.contains($0.id) }
            receipts.append(contentsOf: successes)
            refreshArchivedBytes()
            homeReceipts.subtract(copied)
            if home { homeReceipts.formUnion(copied) }
            restored.subtract(copied)
            failures = problems
            items.removeAll { copied.contains($0.id) || here.contains($0.id) }
            for id in copied {
                measuredBytes[id] = nil
                checkedPhotos[id] = nil
                checkedParts[id] = nil
            }
            recordOutcome("Archive copy \(operation) completed. Verified \(copied.count) of \(selection.count) items in \(Self.seconds(since: started)), \(Self.throughput(copiedBytes, since: started)).")
            let completion = copied.isEmpty ? nil : ArchiveCompletion(items: selection.filter { copied.contains($0.id) },
                                                                      bytes: copiedBytes,
                                                                      place: destination.lastPathComponent, driveFolderID: nil, copies: copies)
            run.outcome = ArchiveOutcome(completion: completion, failures: problems,
                                         left: run.stopping ? selection.count - run.tried : 0, place: destination.lastPathComponent,
                                         alreadyHere: here.count)
            UIApplication.shared.isIdleTimerDisabled = false
            run.releaseBackgroundTime()
            busy = false
        }
    }

    private func beginRestore() {
        guard !busy, restoreConsent, let restoreTarget, let restoreFolder else { return }
        let home = homeReceipts.contains(restoreTarget.id)
        let wifiCheck = wifi
        restoreConsent = false
        guard let operation = authorize("archive test restore", count: 1) else { return }
        busy = true
        message = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try VerifiedArchive.restore(restoreTarget, to: restoreFolder, wifi: home ? wifiCheck : nil)
                }
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

    /// Checks the chosen folder right away: format, read-only, free space, and a test write.
    private func checkFolder(_ folder: URL) {
        folderCheck = nil
        checkingFolder = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { FolderCheck.run(on: folder) }.value
            guard destination == folder else { return }
            folderCheck = result
            checkingFolder = false
            if let available = result.available, availableGB.isEmpty {
                let formatter = NumberFormatter()
                formatter.locale = locale
                formatter.numberStyle = .decimal
                formatter.maximumFractionDigits = 1
                availableGB = formatter.string(from: NSNumber(value: Double(available) / 1_000_000_000)) ?? ""
            }
        }
    }

    /// Items too big for a FAT32 drive.
    private var tooBigForDrive: [ArchiveItem] {
        guard folderCheck?.isFAT32 == true else { return [] }
        return items.filter { (bytes(for: $0) ?? 0) > FolderCheck.fat32FileLimit }
    }

    private func completionNote(_ done: ArchiveCompletion) -> String? {
        guard !done.photoIDs.isEmpty else { return nil }
        if RemovalAfterArchive.enabled {
            let removable = done.removable
            guard !removable.isEmpty else { return "They're still on your \(Device.name) too. Favorites stay." }
            return "They're still on your \(Device.name) too. Every copy is checked again before anything is removed: up to \(done.bytes(of: removable).fileSize)."
        }
        return "They're still on your \(Device.name) too. Removing originals after archiving turns on once putting an item back has been tested on this \(Device.name)."
    }

    /// Everything archived so far counts toward the free 5 GB.
    private func refreshArchivedBytes() {
        // Read off the main thread: with a long archive list the sum takes a moment.
        Task {
            archivedBytes = await Task.detached(priority: .userInitiated) {
                (try? InventoryStore.openDefault().archivedBytes()) ?? 0
            }.value
        }
    }

    private static func photoID(_ item: ArchiveItem) -> String? {
        if case let .photo(id, _) = item.source { return id }
        return nil
    }

    private static func save(_ record: ArchivedRecord) -> Bool {
        let saved = (try? InventoryStore.openDefault().saveArchived([record])) != nil
        if saved, let id = record.photoID { ArchiveThumbnails.rememberSoon([id]) }
        return saved
    }

    /// Marks copies as confirmed once the drive has written everything out.
    private static func confirm(_ records: [ArchivedRecord]) -> Bool {
        (try? InventoryStore.openDefault().saveArchived(records)) != nil
    }

    private static func notSaved(_ item: ArchiveItem) -> String {
        "\(item.name) — Copied, but it couldn't be added to Get back, so its original stays on this \(Device.name)."
    }

    /// Lets the Archived tab reopen the folder later without asking the user to pick it again.
    private static func bookmark(for folder: URL) -> Data? {
        let active = folder.startAccessingSecurityScopedResource()
        defer { if active { folder.stopAccessingSecurityScopedResource() } }
        return try? folder.bookmarkData()
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

    static func seconds(since start: Date) -> String {
        Duration.seconds(Date().timeIntervalSince(start)).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated))
    }

    /// "1.2 GB at 18 MB/s": how much was copied and how fast, so a slow archive shows where it stands.
    static func throughput(_ bytes: Int64, since start: Date, now: Date = Date()) -> String {
        let seconds = max(now.timeIntervalSince(start), 0.001)
        let rate = Int64(Double(bytes) / seconds)
        return "\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) at \(ByteCountFormatter.string(fromByteCount: rate, countStyle: .file))/s"
    }

    private func recordOutcome(_ entry: String) {
        try? InventoryStore.openDefault().log(entry)
    }
}

extension ProOffer {
    /// What the half sheet says for a locked Archive feature.
    static func archive(_ feature: ProFeature) -> ProOffer {
        switch feature {
        case .unlimitedArchive:
            ProOffer(id: "archive-unlimited", title: "Archive without a limit",
                     what: "lifts the 5 GB limit, so you can copy as much as you like, to any destination.",
                     found: "Your first 5 GB, every destination and getting items back stay free.", symbol: "infinity")
        default:
            ProOffer(id: "archive-groups", title: "Archive groups",
                     what: "sorts your library into events, trips and topics, lets you choose by album or place, and suggests large videos to move.",
                     found: "Archiving up to 5 GB, to any destination, stays free.", symbol: "rectangle.stack")
        }
    }
}
