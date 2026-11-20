import SwiftUI

/// App shell: a first-launch welcome, then the tab bar.
struct RootView: View {
    @StateObject private var model = DashboardModel()
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false
    @State private var forceWelcome = ProcessInfo.processInfo.arguments.contains("--reset-welcome")
    @Environment(\.colorScheme) private var colorScheme

    private let slate = Color(red: 0.19, green: 0.32, blue: 0.44)

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
        .tint(colorScheme == .dark ? Color(red: 0.69, green: 0.82, blue: 0.95) : slate)
    }

    private var tabs: some View {
        TabView {
            DashboardView(model: model)
                .tabItem { Label("Home", systemImage: "house") }
            NavigationStack {
                PhotoDetailsView(model: model, destination: .duplicates)
            }
            .tabItem { Label("Clean", systemImage: "square.on.square") }
            NavigationStack {
                PhotoArchiveView(snapshot: model.isDemo ? nil : model.snapshot)
            }
            .tabItem { Label("Archive", systemImage: "archivebox") }
            NavigationStack {
                PhotoDetailsView(model: model, destination: .help)
            }
            .tabItem { Label("Ledger", systemImage: "checkmark.shield") }
        }
    }

    private func finishWelcome() {
        hasSeenWelcome = true
        forceWelcome = false
    }
}

struct WelcomeView: View {
    let start: () -> Void
    let trySamples: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private let slate = Color(red: 0.19, green: 0.32, blue: 0.44)

    private var porcelain: Color {
        colorScheme == .dark ? Color(uiColor: .systemBackground) : Color(red: 0.99, green: 0.98, blue: 0.96)
    }

    private var card: Color {
        colorScheme == .dark ? Color(uiColor: .secondarySystemBackground) : Color(red: 0.88, green: 0.92, blue: 0.96)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("TidyAway")
                    .font(.title2.bold())
                Image("PorcelainHero")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 220)
                    .accessibilityHidden(true)
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
                            .background(slate, in: RoundedRectangle(cornerRadius: 16))
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
