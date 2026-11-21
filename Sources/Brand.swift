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
