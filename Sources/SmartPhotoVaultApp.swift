import SwiftUI

@main
struct SmartPhotoVaultApp: App {
    /// Created at launch so purchase updates are heard from the start.
    @StateObject private var pro = ProStore()

    /// UI tests that tap through every screen don't wait for animations.
    private let fast = LaunchFlags.has("--ui-fast")
    /// Same as iPhone, Light or Dark, chosen under More. Applied to every screen.
    @AppStorage(AppearanceStore.key) private var appearance = AppearanceChoice.system.rawValue

    private var look: AppearanceChoice { AppearanceChoice(rawValue: appearance) ?? .system }

    init() {
        // Before anything writes local data: did this iPhone already have TidyAway 1.0 on it?
        Grandfather.checkAtLaunch()
        if fast { UIView.setAnimationsEnabled(false) }
        // Background check-ins must be registered before launch finishes.
        CheckInBackground.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(pro)
                .transaction { if fast { $0.animation = nil } }
                .preferredColorScheme(look.colorScheme)
                .onAppear { AppearanceStore.apply(look) }
                .onChange(of: appearance) { AppearanceStore.apply(look) }
        }
    }
}
