import SwiftUI
import UIKit

/// TidyAway brand colours, taken from the Sweep app icon. Every screen uses these instead of literals.
/// Green only for safe/done, amber for cautions, never red.
enum Brand {
    /// Actions, links and the app tint. Deep tangerine keeps white text readable (about 4.6:1).
    static let primary = Color(light: 0xC8501F, dark: 0xFF8A5C)
    /// Page background: warm cream in light mode, near-black ink in dark mode.
    static let background = Color(light: 0xFFF7EE, dark: 0x14161F)
    /// Soft surfaces such as secondary buttons and cards.
    static let surface = Color(light: 0xFFE7D3, dark: 0x262A38)
    /// Top of the Home hero gradient.
    static let heroTop = Color(light: 0xFFD7BC, dark: 0x3A2A24)
    /// Safe and done.
    static let safe = Color(light: 0x1E7A4F, dark: 0x3DDC97)
    /// Cautions and things that need attention.
    static let caution = Color(light: 0x9A6200, dark: 0xF2C14E)

    // MARK: 1.0.1 home, More and Checkup

    /// Main text: navy ink on cream, cream on navy.
    static let ink = Color(light: 0x1B1F3B, dark: 0xFFF7EE)
    /// Quieter text beside it.
    static let muted = Color(light: 0x4A4F63, dark: 0xC9BDB4)
    /// Cards: white on cream, raised navy on ink.
    static let card = Color(light: 0xFFFFFF, dark: 0x242A45)
    static let cardEdge = Color(light: 0xF1E4D6, dark: 0x3B4160)
    /// The thin line between rows inside a card.
    static let hairline = Color(light: 0xEFE4D8, dark: 0x384060)
    /// The fixed page backdrop: cream with a peach glow, or navy ink with a dusk glow low down.
    static let backdrop = Color(light: 0xFFF8F0, dark: 0x171B34)
    static let backdropGlow = Color(light: 0xFBE3D2, dark: 0x4A2C2A)
    /// The plan card on More and the PRO badge: navy in both modes.
    static let navy = Color(light: 0x1F2547, dark: 0x2A3158)
    static let onNavy = Color(light: 0xFFFFFF, dark: 0xFFFFFF)
    /// In dark mode the plan card keeps its lead with a tangerine edge.
    static let navyEdge = Color(light: 0x1F2547, dark: 0xFF8A5C)
    static let navyAccent = Color(light: 0xFF9D76, dark: 0xFF9D76)
    /// The Appearance swatches show each look as it is, whatever the current mode.
    static let swatchLight = Color(light: 0xFFF7EE, dark: 0xFFF7EE)
    static let swatchDark = Color(light: 0x171B34, dark: 0x171B34)
    static let swatchEdge = Color(light: 0xD9C9B8, dark: 0x5A6080)
    /// The full-screen preview is black with white type in both modes, as in Photos.
    static let viewer = Color(light: 0x000000, dark: 0x000000)
    static let onViewer = Color(light: 0xFFFFFF, dark: 0xFFFFFF)
    /// Storage Score bands. Green for A and B, amber for C, deep amber for D and E. Never red.
    static let scoreAmber = Color(light: 0xD98A0B, dark: 0xF2B544)
    static let scoreDeepAmber = Color(light: 0xB5600A, dark: 0xE8923A)
    /// The band letter on its colored square.
    static let onScoreGood = Color(light: 0xFFFFFF, dark: 0x0E2A1E)
    static let onScoreAmber = Color(light: 0x1B1F3B, dark: 0x1B1F3B)
    static let onScoreDeepAmber = Color(light: 0xFFFFFF, dark: 0x1B1F3B)
    /// The empty part of a ring or bar.
    static let track = Color(light: 0xE8E0D6, dark: 0x3A4060)
    /// The worked-out middle of the storage bar.
    static let rest = Color(light: 0x8C90A8, dark: 0x8C90A8)
    static let restStripe = Color(light: 0xB5B8C9, dark: 0x6F748F)
    /// Small chips: "Worked out", "Copy first".
    static let chipBack = Color(light: 0xFDEFCB, dark: 0x4A3D17)
    static let chipText = Color(light: 0x7A5200, dark: 0xF2C14E)
    /// Icon tiles on the three shelves.
    static let safeTile = Color(light: 0xDFF3E8, dark: 0x17402F)
    static let lookTile = Color(light: 0xFDF0D0, dark: 0x4A4030)
    static let moveTile = Color(light: 0xFCE3D6, dark: 0x4D3232)
    /// The Keep button in the preview: green because keeping is the safe choice.
    static let keep = Color(light: 0x3DDC97, dark: 0x3DDC97)
    static let onKeep = Color(light: 0x0E2A1E, dark: 0x0E2A1E)

    // MARK: The storage bar, colored as in Settings › General › iPhone Storage

    /// Photos & videos: the yellow iOS gives Photos.
    static let storagePhotos = Color(light: 0xFFCC00, dark: 0xFFD60A)
    /// Apps, System & other: iOS system gray. Still striped, because the figure is worked out.
    static let storageRest = Color(light: 0x8E8E93, dark: 0x98989D)
    static let storageRestStripe = Color(light: 0xAEAEB2, dark: 0x7C7C80)
    /// Free space is not a color at all: it is the empty track.
    static let storageFree = Color(light: 0xE5E5EA, dark: 0x3A3A3C)
    /// The thin ring around the Free dot in the legend, so the empty track can be seen on a card.
    static let storageFreeEdge = Color(light: 0xAEAEB2, dark: 0x7C7C80)
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            UIColor(rgb: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255,
                  green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255,
                  alpha: 1)
    }
}

/// The app icon artwork, used as the hero on Welcome and Home.
struct BrandMark: View {
    var size: CGFloat = 112

    var body: some View {
        Image("BrandMark")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
            .shadow(color: Brand.primary.opacity(0.25), radius: 12, y: 6)
            .accessibilityHidden(true)
    }
}
