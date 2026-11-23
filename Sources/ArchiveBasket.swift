import Foundation

/// Hands photos chosen elsewhere in the app, such as a Free up list, to Archive's copy screen.
@MainActor
final class ArchiveBasket: ObservableObject {
    static let shared = ArchiveBasket()

    @Published private(set) var pending: [AssetRecord] = []
    /// Changes every time something is sent, so Archive opens even for the same photos twice.
    @Published private(set) var request = 0

    func send(_ records: [AssetRecord]) {
        guard !records.isEmpty else { return }
        pending = records
        request += 1
    }

    func take() -> [AssetRecord] {
        defer { pending = [] }
        return pending
    }
}

/// Pro for everyone testing a TestFlight build, so every feature can be tried.
enum TesterAccess {
    /// On in TestFlight builds, off in builds for App Review. Apple reviews in the same test
    /// environment as TestFlight and a reviewer has to be able to buy Pro, so the switch is set when
    /// the build is made: app-store.yml compiles TESTER_ACCESS in unless `review_build` is ticked,
    /// and review builds get a build number ending in .9. Even when compiled in, it only unlocks in
    /// the test environment, never for App Store customers.
    #if TESTER_ACCESS
    static let enabled = true
    #else
    static let enabled = false
    #endif
}

/// Test-only launch switches (sample data, skipping the welcome). Always off in builds for the App Store.
enum LaunchFlags {
    static func has(_ flag: String) -> Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains(flag)
        #else
        return false
        #endif
    }
}
