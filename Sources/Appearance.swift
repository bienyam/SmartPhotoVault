import SwiftUI
import UIKit

/// How TidyAway looks: following the iPhone, or always light or dark. Only TidyAway changes.
enum AppearanceChoice: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Same as iPhone"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var detail: String {
        switch self {
        case .system: "Follows Light or Dark in iOS Settings"
        case .light: "Cream, always"
        case .dark: "Navy ink, always"
        }
    }

    /// Nil follows the iPhone.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Where the choice is kept. "Same as iPhone" is the default, so nobody's app changes look on updating.
enum AppearanceStore {
    static let key = "appearance"

    static func load(from store: UserDefaults = .standard) -> AppearanceChoice {
        store.string(forKey: key).flatMap(AppearanceChoice.init(rawValue:)) ?? .system
    }

    static func save(_ choice: AppearanceChoice, to store: UserDefaults = .standard) {
        store.set(choice.rawValue, forKey: key)
    }

    /// Sheets and system alerts follow the window, so the window is told as well as SwiftUI.
    @MainActor
    static func apply(_ choice: AppearanceChoice) {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows { window.overrideUserInterfaceStyle = choice.interfaceStyle }
        }
    }
}
