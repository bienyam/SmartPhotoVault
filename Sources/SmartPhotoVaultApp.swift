import SwiftUI

@main
struct SmartPhotoVaultApp: App {
    /// Created at launch so purchase updates are heard from the start.
    @StateObject private var pro = ProStore()

    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(pro)
        }
    }
}
