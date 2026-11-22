import Photos
import SwiftUI

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
    static let done = Color(red: 0.094, green: 0.40, blue: 0.259)
}

/// The one big button at the bottom of an Archive screen.
struct ArchiveButtonStyle: ButtonStyle {
    var fill = ArchiveStyle.action
    var text = ArchiveStyle.onAction
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 58)
            .foregroundStyle(text)
            .background(fill, in: RoundedRectangle(cornerRadius: 18))
            .opacity(enabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
    }
}

/// A quieter, outlined button.
struct ArchiveOutlineStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.bold))
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 48)
            .foregroundStyle(ArchiveStyle.ink)
            .background(RoundedRectangle(cornerRadius: 14).stroke(ArchiveStyle.border, lineWidth: 1.5))
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.7 : 1)
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

/// Move out and Get back, as two large buttons that stay on screen. They shrink while the page is scrolled.
struct ArchiveKeys: View {
    @Binding var mode: ArchiveMode
    var compact = false
    let locked: Bool
    let moveOutNote: String
    let getBackNote: String
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 11))
        layout {
            key(.moveOut, note: moveOutNote)
            key(.getBack, note: getBackNote)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8), value: mode)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: compact)
        .sensoryFeedback(.selection, trigger: mode)
    }

    private func key(_ kind: ArchiveMode, note: String) -> some View {
        let on = mode == kind
        let small = compact && !typeSize.isAccessibilitySize
        let stack = small ? AnyLayout(HStackLayout(spacing: 8)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
        return Button { mode = kind } label: {
            HStack(alignment: small ? .center : .top, spacing: 8) {
                stack {
                    Image(systemName: locked && on ? "lock.fill" : kind.icon)
                        .font(.headline.weight(.heavy))
                        .foregroundStyle(Color(red: 0.078, green: 0.086, blue: 0.122))
                        .frame(width: 36, height: 36)
                        .background(Color(red: 1, green: 0.541, blue: 0.361), in: Circle())
                    Text(kind.rawValue).font(.title3.weight(.heavy))
                    if !small { Text(note).font(.footnote).lineLimit(2) }
                }
                Spacer(minLength: 0)
                if on { Image(systemName: "checkmark").font(.subheadline.weight(.heavy)) }
            }
            .multilineTextAlignment(.leading)
            .padding(small ? 8 : 12)
            .frame(maxWidth: .infinity, minHeight: small ? 56 : 104, maxHeight: .infinity, alignment: small ? .leading : .topLeading)
            .foregroundStyle(on ? ArchiveStyle.onSelected : ArchiveStyle.ink)
            .background(on ? ArchiveStyle.selected : Brand.surface, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(on ? Color.clear : ArchiveStyle.border, lineWidth: 1.5))
            .shadow(color: .black.opacity(on ? 0.2 : 0), radius: 10, y: 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(locked)
        .accessibilityElement(children: .ignore)
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

    var body: some View {
        Color.clear
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    LinearGradient(colors: [Color(red: 0.55, green: 0.42, blue: 0.36), Color(red: 0.30, green: 0.26, blue: 0.30)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .clipped()
            .accessibilityHidden(true)
            .onAppear(perform: load)
            .onDisappear {
                if let request { PHImageManager.default().cancelImageRequest(request) }
                request = nil
            }
    }

    private func load() {
        guard image == nil, !assetID.hasPrefix("sample-") else { return }
        let access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard access == .authorized || access == .limited,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else { return }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        request = PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: side, height: side),
                                                        contentMode: .aspectFill, options: options) { picture, info in
            guard (info?[PHImageCancelledKey] as? Bool) != true, let picture else { return }
            DispatchQueue.main.async { image = picture }
        }
    }
}

/// A picture card for a group, with its size.
struct ArchiveCard: View {
    let title: String
    let detail: String
    let coverID: String?
    var tall = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(tall ? .title3.bold() : .headline)
            Text(detail).font(.footnote)
        }
        .multilineTextAlignment(.leading)
        .foregroundStyle(.white)
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: tall ? 120 : 96, alignment: .bottomLeading)
        .background {
            ZStack {
                AssetCover(assetID: coverID ?? "sample-", side: 600)
                LinearGradient(colors: [.black.opacity(0.25), .black.opacity(0.82)], startPoint: .top, endPoint: .bottom)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .contentShape(Rectangle())
    }
}
