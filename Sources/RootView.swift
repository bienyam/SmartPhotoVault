import SwiftUI

/// App shell: a first-launch welcome, then the tab bar.
struct RootView: View {
    @StateObject private var model = DashboardModel()
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false
    @State private var forceWelcome = ProcessInfo.processInfo.arguments.contains("--reset-welcome")
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase

    private let accent = Brand.primary

    private var skipWelcome: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--skip-welcome") || arguments.contains("--demo")
    }

    private var showWelcome: Bool {
        forceWelcome || (!hasSeenWelcome && !skipWelcome)
    }

    var body: some View {
        Group {
            if showWelcome {
                WelcomeStoryView(start: { finishWelcome() })
            } else {
                tabs
            }
        }
        .tint(colorScheme == .dark ? Brand.primary : accent)
    }

    private var tabs: some View {
        TabView {
            FreeUpView(model: model)
                .tabItem { Label("Free up", systemImage: "sparkles") }
            ArchiveTabView(model: model)
                .tabItem { Label("Archive", systemImage: "archivebox") }
            MoreView(model: model)
                .tabItem { Label("More", systemImage: "ellipsis.circle") }
        }
        .task {
            if ProcessInfo.processInfo.arguments.contains("--demo") { model.showDemo() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refreshAuthorization() }
        }
    }

    private func finishWelcome() {
        hasSeenWelcome = true
        forceWelcome = false
    }
}

/// Archive in one tab: Move out makes verified copies, Get back restores them.
struct ArchiveTabView: View {
    @ObservedObject var model: DashboardModel
    @State private var mode = ArchiveMode.moveOut
    @State private var path = NavigationPath()
    @State private var locked = false
    @State private var readyBytes: Int64 = 0
    @State private var safeCount = 0
    @State private var compact = false

    private var snapshot: ScanSnapshot? {
        if ProcessInfo.processInfo.arguments.contains("--demo-archive") { return DemoLibrary.archiveSnapshot }
        return model.isDemo ? nil : model.snapshot
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                ArchiveKeys(mode: $mode, compact: compact, locked: locked,
                            moveOutNote: readyBytes > 0 ? "\(readyBytes.fileSize) in groups" : "Copy off this iPhone",
                            getBackNote: safeCount > 0 ? "\(safeCount.formatted()) archived" : "Nothing yet")
                ZStack {
                    // Kept alive while Get back is showing, so a selection or a running copy is never lost.
                    PhotoArchiveView(snapshot: snapshot, model: model, showArchived: { mode = .getBack },
                                     path: $path, locked: $locked, readyBytes: $readyBytes)
                        .opacity(mode == .moveOut ? 1 : 0)
                        .allowsHitTesting(mode == .moveOut)
                        .accessibilityHidden(mode != .moveOut)
                    if mode == .getBack { ArchivedView() }
                }
                .onPreferenceChange(ArchiveScroll.self) { offset in
                    // Two thresholds, so the buttons don't flip back and forth.
                    if offset < -60 { compact = true } else if offset > -4 { compact = false }
                }
            }
            .background(Brand.background)
            .navigationTitle("Archive")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear(perform: count)
        .onChange(of: mode) {
            compact = false
            count()
        }
        .onChange(of: locked) { count() }
    }

    private func count() { safeCount = (try? InventoryStore.openDefault().archivedCount()) ?? 0 }
}
