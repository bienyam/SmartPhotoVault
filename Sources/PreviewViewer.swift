import AVKit
import Photos
import PhotosUI
import SwiftUI
import UIKit

// Preview before delete, free for everyone. Tap a picture to look at it full screen; tap the circle
// to choose it. The viewer never deletes anything: it only changes what is ticked, and deleting
// still needs the list, the sign-off and the iOS confirmation.

/// A request to open the viewer at one item.
struct PreviewRequest: Identifiable {
    let id = UUID()
    let assetID: String
    /// Opens with the file info showing.
    var showInfo = false
}

/// Which items the viewer loads: a window around the one that was tapped, so a list of thousands
/// opens as quickly as a list of ten.
enum PreviewWindow {
    static let radius = 60

    static func range(count: Int, index: Int, radius: Int = PreviewWindow.radius) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        let at = min(max(0, index), count - 1)
        return max(0, at - radius)..<min(count, at + radius + 1)
    }
}

/// The one line of facts under a previewed item, and the rows of its info sheet.
enum PreviewFacts {
    static func kind(_ record: AssetRecord) -> String {
        let type = record.filename.split(separator: ".").count > 1 ? record.filename.split(separator: ".").last.map { $0.uppercased() } : nil
        return type ?? (record.mediaType == PHAssetMediaType.video.rawValue ? "Video" : "Photo")
    }

    static func place(_ record: AssetRecord) -> String {
        record.inICloud ? "in iCloud" : "on this \(Device.name)"
    }

    static func dimensions(_ record: AssetRecord) -> String? {
        guard let width = record.pixelWidth, let height = record.pixelHeight, width > 0, height > 0 else { return nil }
        return "\(width) × \(height)"
    }

    /// "3.7 MB · 4032 × 3024 · HEIC · on this iPhone"
    static func line(_ record: AssetRecord) -> String {
        var parts: [String] = []
        if record.displayBytes > 0 { parts.append(record.displayBytes.fileSize) }
        if let size = dimensions(record) { parts.append(size) }
        parts.append(kind(record))
        parts.append(place(record))
        return parts.joined(separator: " · ")
    }

    static func date(_ record: AssetRecord) -> String {
        record.createdAt?.formatted(date: .abbreviated, time: .shortened) ?? "Date not known"
    }
}

/// The words on the viewer's two buttons. Free up lists choose what to delete; Archive chooses what to copy.
struct PreviewWords {
    var keep = "Keep"
    var select = "Select"
    var selected = "Selected"
    var footer = "Nothing is removed from this screen. Selected items wait for your sign-off."

    static let archive = PreviewWords(keep: "Leave out", select: "Include", selected: "Included",
                                      footer: "Nothing is copied or removed from this screen. Archiving only copies.")
}

/// The full-screen viewer: swipe between items, pinch or double-tap to zoom, play videos and
/// Live Photos, read the file info, and tick or untick. There is no Delete here.
struct PhotoPreview: View {
    let title: String
    let items: [AssetRecord]
    /// Where the window starts in the whole list, and how long that list is, for "3 of 12".
    let offset: Int
    let total: Int
    /// Items that can be ticked. Anything else opens view only.
    let selectable: Set<String>
    /// Why an item stays, such as "Keeping this one".
    let notes: [String: String]
    let words: PreviewWords
    @Binding var selected: Set<String>
    /// Called when a tick changes, so the list can clear its sign-off.
    let changed: () -> Void

    @State private var current: String
    @State private var showInfo: Bool
    @State private var archived: [String: ArchivedRecord] = [:]
    @State private var moved = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    init(title: String, items all: [AssetRecord], request: PreviewRequest, selectable: Set<String>,
         notes: [String: String] = [:], words: PreviewWords = PreviewWords(),
         selected: Binding<Set<String>>, changed: @escaping () -> Void = {}) {
        let index = all.firstIndex { $0.id == request.assetID } ?? 0
        let window = PreviewWindow.range(count: all.count, index: index)
        self.title = title
        self.items = Array(all[window])
        self.offset = window.lowerBound
        self.total = all.count
        self.selectable = selectable
        self.notes = notes
        self.words = words
        self._selected = selected
        self.changed = changed
        _current = State(initialValue: all.isEmpty ? "" : all[min(index, all.count - 1)].id)
        _showInfo = State(initialValue: request.showInfo)
    }

    private var record: AssetRecord? { items.first { $0.id == current } }
    private var position: Int { offset + (items.firstIndex { $0.id == current } ?? 0) + 1 }

    var body: some View {
        ZStack {
            Brand.viewer.ignoresSafeArea()
            TabView(selection: $current) {
                ForEach(items) { item in
                    PreviewPage(record: item, active: item.id == current)
                        .tag(item.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                if !moved && items.count > 1 {
                    Label("Swipe for the next one", systemImage: "arrow.left.and.right")
                        .font(.subheadline)
                        .foregroundStyle(Brand.onViewer)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Brand.viewer.opacity(0.55), in: Capsule())
                        .padding(.bottom, 10)
                        .accessibilityHidden(true)
                }
                if let record { bottomPanel(record) }
            }
        }
        // The viewer is always dark, like Photos. Only this screen: the app's look is not changed.
        .environment(\.colorScheme, .dark)
        .statusBarHidden(false)
        .onChange(of: current) { moved = true }
        .sheet(isPresented: $showInfo) {
            if let record { PreviewInfoSheet(record: record, archived: archived[record.id], note: notes[record.id]) }
        }
        .task {
            // Whether a verified copy already exists, read off the main thread.
            archived = await Task.detached(priority: .utility) { () -> [String: ArchivedRecord] in
                var found: [String: ArchivedRecord] = [:]
                for copy in (try? InventoryStore.openDefault().archived()) ?? [] {
                    if let photo = copy.photoID, found[photo] == nil { found[photo] = copy }
                }
                return found
            }.value
        }
    }

    private var topBar: some View {
        HStack(alignment: .center, spacing: 8) {
            Button { dismiss() } label: {
                Text("Done")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Brand.onViewer)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .background(Brand.viewer.opacity(0.55), in: Capsule())
            }
            .accessibilityIdentifier("preview-done")
            Spacer(minLength: 0)
            VStack(spacing: 1) {
                Text(title).font(.headline).foregroundStyle(Brand.onViewer).lineLimit(1)
                Text("\(position.formatted()) of \(total.formatted())")
                    .font(.footnote).foregroundStyle(Brand.onViewer.opacity(0.85))
            }
            .shadow(color: Brand.viewer.opacity(0.6), radius: 3)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("preview-position")
            Spacer(minLength: 0)
            Button { showInfo = true } label: {
                Image(systemName: "info.circle")
                    .font(.body.weight(.bold))
                    .foregroundStyle(Brand.onViewer)
                    .frame(width: 44, height: 44)
                    .background(Brand.viewer.opacity(0.55), in: Circle())
            }
            .accessibilityLabel("File info")
            .accessibilityIdentifier("preview-info")
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
    }

    private func bottomPanel(_ record: AssetRecord) -> some View {
        let canPick = selectable.contains(record.id)
        let picked = selected.contains(record.id)
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(PreviewFacts.date(record)).font(.headline).foregroundStyle(Brand.onViewer)
                Text(PreviewFacts.line(record)).font(.footnote).foregroundStyle(Brand.onViewer.opacity(0.85))
                if archived[record.id] != nil {
                    Label("Already archived, copy checked", systemImage: "checkmark.circle.fill")
                        .font(.footnote.weight(.semibold)).foregroundStyle(Brand.keep)
                }
                Label(record.favorite ? "Favorite" : "Not a favorite", systemImage: record.favorite ? "heart.fill" : "heart")
                    .font(.footnote).foregroundStyle(Brand.onViewer.opacity(0.85))
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("preview-facts")
            if canPick {
                let layout = typeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(spacing: 6)) : AnyLayout(HStackLayout(spacing: 6))
                layout {
                    Button { set(record, to: false) } label: {
                        Label(words.keep, systemImage: picked ? "circle" : "checkmark")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .foregroundStyle(picked ? Brand.onViewer : Brand.onKeep)
                            .background(picked ? Color.clear : Brand.keep, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityAddTraits(picked ? [] : .isSelected)
                    .accessibilityIdentifier("preview-keep")
                    Button { set(record, to: true) } label: {
                        Label(picked ? words.selected : words.select, systemImage: picked ? "checkmark" : "circle")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .foregroundStyle(picked ? ArchiveStyle.onAction : Brand.onViewer)
                            .background(picked ? ArchiveStyle.action : Color.clear, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityAddTraits(picked ? .isSelected : [])
                    .accessibilityIdentifier("preview-select")
                }
                .padding(5)
                .background(Brand.viewer.opacity(0.6), in: RoundedRectangle(cornerRadius: 21, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 21, style: .continuous).stroke(Brand.onViewer.opacity(0.25), lineWidth: 1))
                Text(words.footer)
                    .font(.footnote).foregroundStyle(Brand.onViewer.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label(notes[record.id] ?? (record.favorite ? "Favorite, kept" : "View only"), systemImage: "lock.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Brand.onKeep)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Brand.keep, in: Capsule())
                    .accessibilityIdentifier("preview-stays")
                Text("This one stays. It can't be selected here.")
                    .font(.footnote).foregroundStyle(Brand.onViewer.opacity(0.85))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        .background(LinearGradient(colors: [Brand.viewer.opacity(0), Brand.viewer.opacity(0.75)], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea())
    }

    private func set(_ record: AssetRecord, to picked: Bool) {
        guard selectable.contains(record.id), selected.contains(record.id) != picked else { return }
        if picked { selected.insert(record.id) } else { selected.remove(record.id) }
        changed()
    }
}

// MARK: - One page

/// Loads what one page shows. Originals kept in iCloud are fetched for the preview only, with progress.
final class PreviewLoader: ObservableObject {
    enum Content {
        case loading
        case image(UIImage)
        case live(PHLivePhoto)
        case video(AVPlayer)
        case sample
        case missing
    }

    @Published var content = Content.loading
    /// 0 to 1 while an original comes down from iCloud; nil otherwise.
    @Published var progress: Double?
    private var request: PHImageRequestID?
    private var started = false

    deinit {
        if let request { PHImageManager.default().cancelImageRequest(request) }
    }

    func load(_ record: AssetRecord) {
        guard !started else { return }
        started = true
        guard !record.id.hasPrefix("sample-") else {
            content = .sample
            return
        }
        let access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard access == .authorized || access == .limited,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [record.id], options: nil).firstObject else {
            content = .missing
            return
        }
        let manager = PHImageManager.default()
        let scale = UIScreen.main.scale
        let side = min(3_000, max(UIScreen.main.bounds.width, UIScreen.main.bounds.height) * scale * 1.5)
        let target = CGSize(width: side, height: side)
        let report: (Double) -> Void = { [weak self] value in
            DispatchQueue.main.async { self?.progress = value < 1 ? value : nil }
        }
        if asset.mediaType == .video {
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .automatic
            options.progressHandler = { value, _, _, _ in report(value) }
            request = manager.requestPlayerItem(forVideo: asset, options: options) { [weak self] item, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.progress = nil
                    guard let item else {
                        self.content = .missing
                        return
                    }
                    let player = AVPlayer(playerItem: item)
                    // Sound stays off until the person turns it on in the player.
                    player.isMuted = true
                    self.content = .video(player)
                }
            }
        } else if asset.mediaSubtypes.contains(.photoLive) {
            let options = PHLivePhotoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .opportunistic
            options.progressHandler = { value, _, _, _ in report(value) }
            request = manager.requestLivePhoto(for: asset, targetSize: target, contentMode: .aspectFit, options: options) { [weak self] photo, info in
                let cancelled = (info?[PHLivePhotoInfoCancelledKey] as? Bool) == true
                let degraded = (info?[PHLivePhotoInfoIsDegradedKey] as? Bool) == true
                DispatchQueue.main.async {
                    guard let self, !cancelled else { return }
                    if let photo { self.content = .live(photo) } else if !degraded { self.content = .missing }
                    if !degraded { self.progress = nil }
                }
            }
        } else {
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .opportunistic
            options.resizeMode = .fast
            options.progressHandler = { value, _, _, _ in report(value) }
            request = manager.requestImage(for: asset, targetSize: target, contentMode: .aspectFit, options: options) { [weak self] image, info in
                let cancelled = (info?[PHImageCancelledKey] as? Bool) == true
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
                DispatchQueue.main.async {
                    guard let self, !cancelled else { return }
                    if let image { self.content = .image(image) } else if !degraded { self.content = .missing }
                    if !degraded { self.progress = nil }
                }
            }
        }
    }

    /// Stops a video when its page is swiped away.
    func pause() {
        if case .video(let player) = content { player.pause() }
    }
}

/// One item, full screen.
struct PreviewPage: View {
    let record: AssetRecord
    let active: Bool
    @StateObject private var loader = PreviewLoader()

    private var isVideo: Bool { record.mediaType == PHAssetMediaType.video.rawValue }
    private var spoken: String { "\(isVideo ? "Video" : "Photo"), \(PreviewFacts.date(record))" }

    var body: some View {
        ZStack {
            switch loader.content {
            case .loading:
                AssetCover(assetID: record.id, side: 600)
                    .aspectRatio(contentMode: .fit)
                    .opacity(0.6)
                ProgressView().tint(Brand.onViewer).controlSize(.large)
            case .image(let image):
                ZoomableImage(image: image)
                    .ignoresSafeArea()
                    .accessibilityElement()
                    .accessibilityLabel(spoken)
                    .accessibilityAddTraits(.isImage)
                    .accessibilityHint("Pinch or double-tap to zoom")
            case .live(let photo):
                LivePhotoPlayer(photo: photo)
                    .ignoresSafeArea()
                    .accessibilityElement()
                    .accessibilityLabel("Live Photo, \(PreviewFacts.date(record))")
                    .accessibilityHint("Touch and hold to play")
                    .overlay(alignment: .topLeading) {
                        Label("LIVE", systemImage: "livephoto")
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(Brand.onViewer)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(Brand.viewer.opacity(0.55), in: Capsule())
                            .padding(.top, 64).padding(.leading, 16)
                            .accessibilityHidden(true)
                    }
            case .video(let player):
                VideoPlayer(player: player)
                    .padding(.top, 60)
                    .padding(.bottom, 190)
                    .accessibilityLabel(spoken)
            case .sample:
                VStack(spacing: 10) {
                    Image(systemName: isVideo ? "video" : "photo")
                        .font(.system(size: 64))
                    Text("Sample \(isVideo ? "video" : "photo")").font(.headline)
                    Text(record.filename).font(.footnote)
                }
                .foregroundStyle(Brand.onViewer.opacity(0.85))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("preview-sample")
            case .missing:
                VStack(spacing: 10) {
                    if let saved = ArchiveThumbnails.cached(record.id) {
                        Image(uiImage: saved).resizable().scaledToFit().frame(maxWidth: 280, maxHeight: 280)
                    } else {
                        Image(systemName: "photo.badge.exclamationmark").font(.system(size: 56))
                    }
                    Text("This item can't be shown right now.").font(.headline)
                    Text("It may have left this \(Device.name), or it couldn't be loaded from iCloud.")
                        .font(.footnote).multilineTextAlignment(.center)
                }
                .foregroundStyle(Brand.onViewer.opacity(0.85))
                .padding(30)
            }
            if let progress = loader.progress {
                VStack(spacing: 8) {
                    ProgressView(value: progress)
                        .progressViewStyle(.circular)
                        .tint(Brand.onViewer)
                        .controlSize(.large)
                    Text("Loading from iCloud… \(Int(progress * 100))%")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Brand.onViewer)
                }
                .padding(16)
                .background(Brand.viewer.opacity(0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("preview-icloud-progress")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { loader.load(record) }
        .onDisappear { loader.pause() }
        .onChange(of: active) { _, now in
            if !now { loader.pause() }
        }
    }
}

/// A photo that can be pinched and double-tapped to zoom, as in Photos.
struct ZoomableImage: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 5
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.bouncesZoom = true
        scroll.backgroundColor = .clear
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.delegate = context.coordinator
        let picture = UIImageView(image: image)
        picture.contentMode = .scaleAspectFit
        picture.frame = scroll.bounds
        picture.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.addSubview(picture)
        context.coordinator.picture = picture
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        tap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(tap)
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        if context.coordinator.picture?.image !== image { context.coordinator.picture?.image = image }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var picture: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { picture }

        @objc func doubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scroll = gesture.view as? UIScrollView else { return }
            if scroll.zoomScale > 1 {
                scroll.setZoomScale(1, animated: true)
            } else {
                let point = gesture.location(in: picture)
                let size = CGSize(width: scroll.bounds.width / 2.5, height: scroll.bounds.height / 2.5)
                scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                       width: size.width, height: size.height), animated: true)
            }
        }
    }
}

/// A Live Photo. Touch and hold plays it, as in Photos.
struct LivePhotoPlayer: UIViewRepresentable {
    let photo: PHLivePhoto

    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = .scaleAspectFit
        view.livePhoto = photo
        return view
    }

    func updateUIView(_ view: PHLivePhotoView, context: Context) {
        if view.livePhoto !== photo { view.livePhoto = photo }
    }
}

// MARK: - File info

/// Size, date, kind, where it lives, and whether a checked copy already exists in the archive.
struct PreviewInfoSheet: View {
    let record: AssetRecord
    let archived: ArchivedRecord?
    let note: String?
    @Environment(\.dismiss) private var dismiss

    private var isVideo: Bool { record.mediaType == PHAssetMediaType.video.rawValue }

    var body: some View {
        NavigationStack {
            List {
                if let archived {
                    Section {
                        Label("Already archived, copy checked", systemImage: "checkmark.circle.fill")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(ArchiveStyle.safeText)
                        Text("\(archived.folderName) · checked \(archived.date.formatted(date: .abbreviated, time: .omitted))")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        Text("Not archived. Archive makes a checked copy before anything is removed.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Section {
                    LabeledContent("Size", value: record.displayBytes > 0 ? record.displayBytes.fileSize : "Not known")
                    LabeledContent("Taken", value: PreviewFacts.date(record))
                    LabeledContent("Kind", value: [isVideo ? "Video" : "Photo", PreviewFacts.kind(record), PreviewFacts.dimensions(record)]
                        .compactMap { $0 }.joined(separator: " · "))
                    LabeledContent("Where it is now", value: record.inICloud ? "In iCloud, with a small copy on this \(Device.name)" : "On this \(Device.name)")
                    LabeledContent("Favorite", value: record.favorite ? "Yes, always kept" : "No")
                    if let note { LabeledContent("In this list", value: note) }
                }
                Section {
                    Text("Nothing is removed from here. Deleting needs your sign-off on the list, then the iOS confirmation.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("File info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("preview-info-done")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - In lists and grids

/// The one choice in a touch-and-hold menu: tick or untick. Never delete.
struct PreviewTick {
    let title: String
    let action: () -> Void
}

extension View {
    /// Touch and hold on something that can be picked: a large look and the same safe choices.
    /// There is no Delete in this menu.
    func previewMenu(assetID: String, tick: PreviewTick?, open: (() -> Void)?, info: (() -> Void)?) -> some View {
        contextMenu {
            if let tick {
                Button(tick.title, action: tick.action)
            }
            if let open {
                Button { open() } label: { Label("Open full screen", systemImage: "arrow.up.left.and.arrow.down.right") }
            }
            if let info {
                Button { info() } label: { Label("File info", systemImage: "info.circle") }
            }
        } preview: {
            AssetCover(assetID: assetID, side: 1000).frame(width: 320, height: 420)
        }
    }
}
