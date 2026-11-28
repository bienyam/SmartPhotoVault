import Photos
import SwiftUI
import UIKit

/// Shown when Photos access is Limited, so small totals have a reason and a way out (D9).
/// "Choose more photos" opens Apple's own picker; the library change notice then updates the scan.
/// Settings opens TidyAway's page in Settings, where access can be changed to Full.
struct LimitedAccessBanner: View {
    @Environment(\.openURL) private var openURL

    static let message = "TidyAway can see only the photos you chose."

    /// True when the banner belongs on screen. `--limited-access` shows it in UI tests with sample data.
    static func shows(authorization: PHAuthorizationStatus, isDemo: Bool) -> Bool {
        if LaunchFlags.has("--limited-access") { return true }
        return authorization == .limited && !isDemo
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(Self.message, systemImage: "photo.badge.exclamationmark")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("limited-access-message")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { buttons }
                VStack(alignment: .leading, spacing: 0) { buttons }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.chipBack, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("limited-access-banner")
    }

    @ViewBuilder
    private var buttons: some View {
        Button("Choose more photos") { Self.presentPicker() }
            .font(.subheadline.weight(.bold))
            .foregroundStyle(ArchiveStyle.link)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .buttonStyle(.plain)
            .accessibilityIdentifier("limited-choose-more")
        Button("Settings") {
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        }
        .font(.subheadline.weight(.bold))
        .foregroundStyle(ArchiveStyle.link)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .buttonStyle(.plain)
        .accessibilityIdentifier("limited-settings")
    }

    /// Apple's limited-library picker, over whatever is showing now.
    static func presentPicker() {
        guard let top = topViewController() else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: top)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.filter { $0.activationState == .foregroundActive }.flatMap(\.windows).first(where: \.isKeyWindow)
            ?? scenes.flatMap(\.windows).first(where: \.isKeyWindow)
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
