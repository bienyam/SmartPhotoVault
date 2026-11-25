import SwiftUI

@main
struct SmartPhotoVaultApp: App {
    /// Created at launch so purchase updates are heard from the start.
    @StateObject private var pro = ProStore()

    /// UI tests that tap through every screen don't wait for animations.
    private let fast = LaunchFlags.has("--ui-fast")

    init() {
        if fast { UIView.setAnimationsEnabled(false) }
        // Background check-ins must be registered before launch finishes.
        CheckInBackground.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(pro)
                .transaction { if fast { $0.animation = nil } }
        }
    }
}
