import Photos
import SwiftUI
import UIKit

/// Colors for the Archive tab, chosen so text is readable (at least 4.5 to 1) in light and dark mode.
enum ArchiveStyle {
    static let action = Color(light: 0xB8441A, dark: 0xFF8A5C)
    static let onAction = Color(light: 0xFFFFFF, dark: 0x14161F)
    static let selected = Color(light: 0x1B1F3B, dark: 0xFFF7EE)
    static let onSelected = Color(light: 0xFFFFFF, dark: 0x14161F)
    static let ink = Color(light: 0x1B1F3B, dark: 0xFFF7EE)
    static let muted = Color(light: 0x4A4F63, dark: 0xC9BDB4)
    static let border = Color(light: 0xB07A55, dark: 0x8A8FA6)
    static let link = Color(light: 0xA83C14, dark: 0xFF8A5C)
    static let safeBack = Color(light: 0xDFF3E8, dark: 0x12382A)
    static let safeText = Color(light: 0x186642, dark: 0x3DDC97)
    /// The completion screen, the same in both modes.
    static let done = Brand.archiveDone
}

/// The one big button at the bottom of an Archive screen.
struct ArchiveButtonStyle: ButtonStyle {
    var fill = ArchiveStyle.action
    var text = ArchiveStyle.onAction
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 58)
            .foregroundStyle(text)
            .background(fill, in: RoundedRectangle(cornerRadius: 18))
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            // A firmer press: the button gives a little under the finger, with a light tap.
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { Haptics.light() }
            }
    }
}

/// A light tap for primary actions. Does nothing where the iPhone has haptics switched off.
enum Haptics {
    @MainActor
    static func light() {
        guard !LaunchFlags.has("--ui-fast") else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

/// The press state for cards and rows that act as buttons: a small give and a dip in brightness.
struct PressableStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A quieter, outlined button.
struct ArchiveOutlineStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.bold))
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 48)
            .foregroundStyle(ArchiveStyle.ink)
            .background(RoundedRectangle(cornerRadius: 14).stroke(ArchiveStyle.border, lineWidth: 1.5))
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

enum ArchiveMode: String, CaseIterable {
    case moveOut = "Move out", getBack = "Get back"
    var icon: String { self == .moveOut ? "arrow.up.forward" : "arrow.uturn.backward" }
    var identifier: String { self == .moveOut ? "archive-move-out" : "archive-get-back" }
}

/// How far an Archive page has scrolled, so the big buttons can make room.
struct ArchiveScroll: PreferenceKey {
    static let space = "archive-scroll"
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = min(value, nextValue()) }
}

extension View {
    /// Put on the content of a scroll view whose coordinate space is `ArchiveScroll.space`.
    func reportsArchiveScroll() -> some View {
        background(GeometryReader { geo in
            Color.clear.preference(key: ArchiveScroll.self, value: geo.frame(in: .named(ArchiveScroll.space)).minY)
        })
    }
}

/// Move out and Get back, as one large sliding switch that stays on screen: the orange pill slides
/// to the side that's on. Tap a side or swipe across to switch. It shrinks while the page is scrolled.
struct ArchiveKeys: View {
    @Binding var mode: ArchiveMode
    var compact = false
    let locked: Bool
    let moveOutNote: String
    let getBackNote: String
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var pill

    var body: some View {
        let vertical = typeSize.isAccessibilitySize
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 4))
        layout {
            key(.moveOut, note: moveOutNote)
            key(.getBack, note: getBackNote)
        }
        .padding(5)
        .background(Brand.surface, in: RoundedRectangle(cornerRadius: 28))
        .overlay(RoundedRectangle(cornerRadius: 28).stroke(ArchiveStyle.border, lineWidth: 1.5))
        .simultaneousGesture(DragGesture(minimumDistance: 24).onEnded { drag in
            guard !locked, !vertical else { return }
            if drag.translation.width > 40 { mode = .getBack } else if drag.translation.width < -40 { mode = .moveOut }
        })
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.82), value: mode)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: compact)
        .sensoryFeedback(.selection, trigger: mode)
    }

    private func key(_ kind: ArchiveMode, note: String) -> some View {
        let on = mode == kind
        let small = compact && !typeSize.isAccessibilitySize
        let stack = small ? AnyLayout(HStackLayout(spacing: 8)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
        return Button { mode = kind } label: {
            stack {
                Image(systemName: locked && on ? "lock.fill" : kind.icon)
                    .font(.headline.weight(.heavy))
                    .foregroundStyle(Brand.onTangerineLight)
                    .frame(width: 36, height: 36)
                    .background(Brand.tangerineLight, in: Circle())
                Text(kind.rawValue).font(.title3.weight(.heavy))
                if !small { Text(note).font(.footnote).lineLimit(2) }
            }
            .multilineTextAlignment(.leading)
            .padding(small ? 8 : 12)
            .frame(maxWidth: .infinity, minHeight: small ? 52 : 98, maxHeight: .infinity, alignment: small ? .leading : .topLeading)
            .foregroundStyle(on ? ArchiveStyle.onSelected : ArchiveStyle.ink)
            .background {
                if on {
                    RoundedRectangle(cornerRadius: 23)
                        .fill(ArchiveStyle.selected)
                        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                        .matchedGeometryEffect(id: "pill", in: pill)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(locked)
        .accessibilityLabel(kind.rawValue)
        .accessibilityValue(note)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(kind.identifier)
    }
}

/// A photo that fills its space. Uses what's on the iPhone only; nothing is downloaded.
struct AssetCover: View {
    let assetID: String
    var side: CGFloat = 300
    @State private var image: UIImage?
    @State private var request: PHImageRequestID?
    @State private var loading: Task<Void, Never>?

    var body: some View {
        Color.clear
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    LinearGradient(colors: [Brand.coverDuskTop, Brand.coverDuskBottom],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .clipped()
            .accessibilityHidden(true)
            .onAppear(perform: load)
            .onDisappear {
                loading?.cancel()
                loading = nil
                if let request { Thumbnails.manager.cancelImageRequest(request) }
                request = nil
            }
    }

    private func load() {
        guard image == nil, !assetID.hasPrefix("sample-") else { return }
        let access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard access == .authorized || access == .limited else { return }
        let id = assetID, side = side
        loading?.cancel()
        loading = Task {
            // The look-up reads the Photos database, so it runs off the main thread.
            let found = await Thumbnails.asset(id)
            guard !Task.isCancelled else { return }
            guard let asset = found else {
                image = ArchiveThumbnails.cached(id)
                return
            }
            let options = PHImageRequestOptions()
            // Photos kept in iCloud may fetch a small preview, as they do in Photos.
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .opportunistic
            options.resizeMode = .fast
            request = Thumbnails.manager.requestImage(for: asset, targetSize: CGSize(width: side, height: side),
                                                      contentMode: .aspectFill, options: options) { picture, info in
                guard (info?[PHImageCancelledKey] as? Bool) != true, let picture else { return }
                DispatchQueue.main.async { image = picture }
            }
        }
    }
}

/// A picture card for a group, with its size.
struct ArchiveCard: View {
    let title: String
    let detail: String
    let coverID: String?
    var tall = false
    /// A few words on why this group was made, shown as a tag at the top.
    var why: String? = nil
    /// Shown on a brand-colored card when there is no picture, instead of a dark empty card.
    var symbol: String = "photo.on.rectangle"

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let why {
                Text(why).font(.caption2.weight(.bold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.black.opacity(0.35), in: Capsule())
                    .lineLimit(1)
                Spacer(minLength: 6)
            }
            Text(title).font(tall ? .title3.bold() : .headline)
            Text(detail).font(.footnote)
        }
        .multilineTextAlignment(.leading)
        .foregroundStyle(.white)
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: tall ? 120 : 96, alignment: .bottomLeading)
        .background {
            ZStack {
                if let coverID {
                    AssetCover(assetID: coverID, side: 600)
                    LinearGradient(colors: [.black.opacity(0.25), .black.opacity(0.82)], startPoint: .top, endPoint: .bottom)
                } else {
                    LinearGradient(colors: [Brand.coverTangerineTop, Brand.coverTangerineBottom],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: symbol)
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.35))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(14)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .contentShape(Rectangle())
    }
}
