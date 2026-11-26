import SwiftUI

/// App shell: a first-launch welcome, then the tab bar.
struct RootView: View {
    enum Tab: Hashable { case freeUp, archive, more }

    @StateObject private var model = DashboardModel()
    @ObservedObject private var basket = ArchiveBasket.shared
    @ObservedObject private var checkIns = CheckInCenter.shared
    @EnvironmentObject private var pro: ProStore
    @State private var tab = Tab.freeUp
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false
    @State private var forceWelcome = LaunchFlags.has("--reset-welcome")
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase

    private let accent = Brand.primary

    private var skipWelcome: Bool {
        return LaunchFlags.has("--skip-welcome") || LaunchFlags.has("--demo")
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
        TabView(selection: $tab) {
            FreeUpView(model: model, openMore: { tab = .more })
                .tabItem { Label("Free up", systemImage: "sparkles") }
                .tag(Tab.freeUp)
            ArchiveTabView(model: model)
                .tabItem { Label("Archive", systemImage: "archivebox") }
                .tag(Tab.archive)
            MoreView(model: model)
                .tabItem { Label("More", systemImage: "ellipsis.circle") }
                .tag(Tab.more)
        }
        // Photos chosen in a Free up list go straight to Archive's copy screen.
        .onChange(of: basket.request) { tab = .archive }
        .task {
            if LaunchFlags.has("--demo") { model.showDemo() }
            checkIns.start()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refreshAuthorization() }
            // Check-ins catch up each time the app opens, since iOS may not have run one in the background.
            // At launch the plan isn't known yet; the catch-up then waits for it (below), so a Pro
            // schedule is never planned as free, even for a moment.
            if phase == .active, !pro.checking { Task { await checkIns.catchUp(pro: pro.allows(.extraCheckIns)) } }
        }
        .onChange(of: pro.checking) { _, checking in
            // The first purchase check has finished: catch up once, with the plan it found.
            if !checking { Task { await checkIns.catchUp(pro: pro.allows(.extraCheckIns)) } }
        }
        .onChange(of: pro.unlocked) { _, unlocked in
            // While the first check runs, the catch-up above follows it.
            guard !pro.checking else { return }
            Task { await checkIns.catchUp(pro: unlocked) }
        }
        // A tapped check-in notification opens its report.
        .sheet(isPresented: $checkIns.showReport) {
            NavigationStack {
                CheckInReportView(model: model, openFreeUp: {
                    checkIns.showReport = false
                    tab = .freeUp
                })
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { checkIns.showReport = false } }
                }
            }
            .environmentObject(pro)
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
    @ObservedObject private var basket = ArchiveBasket.shared
    @State private var mode = ArchiveMode.moveOut
    @State private var path = NavigationPath()
    @State private var locked = false
    @State private var readyBytes: Int64 = 0
    @State private var safeCount = 0
    @State private var compact = false

    private var snapshot: ScanSnapshot? {
        if LaunchFlags.has("--demo-archive") {
            return DemoLibrary.archiveSnapshot
        }
        return model.isDemo ? nil : model.snapshot
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                ArchiveKeys(mode: $mode, compact: compact, locked: locked,
                            moveOutNote: readyBytes > 0 ? "\(readyBytes.fileSize) in groups" : "Copy off this \(Device.name)",
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
        .onChange(of: basket.request) { mode = .moveOut }
        .onAppear {
            if !basket.pending.isEmpty { mode = .moveOut }
            if LaunchFlags.has("--demo-archive") { InsightModel.shared.show(DemoLibrary.archiveInsights) }
            count()
        }
        .onChange(of: mode) {
            compact = false
            count()
        }
        .onChange(of: locked) { count() }
    }

    private func count() {
        // App Store pictures show stand-in records. Nil everywhere else.
        if let sample = DemoLibrary.archivedRecords {
            safeCount = sample.count
            return
        }
        safeCount = (try? InventoryStore.openDefault().archivedCount()) ?? 0
    }
}
