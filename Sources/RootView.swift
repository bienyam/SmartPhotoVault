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
                WelcomeView(
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
                case .moveOut: PhotoArchiveView(snapshot: model.isDemo ? nil : model.snapshot)
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

struct WelcomeView: View {
    let start: () -> Void
    let trySamples: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private let accent = Brand.primary

    private var porcelain: Color {
        colorScheme == .dark ? Color(uiColor: .systemBackground) : Brand.background
    }

    private var card: Color {
        colorScheme == .dark ? Color(uiColor: .secondarySystemBackground) : Brand.surface
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("TidyAway")
                    .font(.title2.bold())
                BrandMark(size: 140)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Out of space? Let's fix it safely.")
                        .font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text("TidyAway shows what is filling your iPhone and iCloud, then helps you clear it without losing a photo.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 12) {
                    promise("The check runs on your iPhone. Your photos stay put.")
                    promise("Nothing is removed until you approve it.")
                    promise("Every change is logged and can be traced.")
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(card, in: RoundedRectangle(cornerRadius: 16))
                VStack(spacing: 10) {
                    Button(action: start) {
                        Text("Get started")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 56)
                            .foregroundStyle(Color.white)
                            .background(accent, in: RoundedRectangle(cornerRadius: 16))
                    }
                    Button(action: trySamples) {
                        Text("Try it with sample photos")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(card, lineWidth: 1.5))
                    }
                    Text("TidyAway asks for Photos access only when you start a scan, and it only reads at that stage.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 24)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
        .background(porcelain)
    }

    private func promise(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "checkmark")
                .font(.subheadline.weight(.bold))
                .accessibilityHidden(true)
            Text(text).font(.subheadline)
        }
        .foregroundStyle(.primary)
    }
}
