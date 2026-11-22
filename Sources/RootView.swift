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
                WelcomeStoryView(
                    start: { finishWelcome() },
                    trySamples: {
                        model.showDemo()
                        finishWelcome()
                    }
                )
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
    @State private var mode = Mode.moveOut

    enum Mode: String, CaseIterable { case moveOut = "Move out", getBack = "Get back" }

    var body: some View {
        NavigationStack {
            Group {
                switch mode {
                case .moveOut: PhotoArchiveView(snapshot: model.isDemo ? nil : model.snapshot, model: model,
                                               showArchived: { mode = .getBack })
                case .getBack: ArchivedView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Archive", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                    .accessibilityIdentifier("archive-mode")
                }
            }
        }
    }
}
