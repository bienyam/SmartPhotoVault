import SwiftUI

/// What TidyAway itself moved to Recently Deleted, so the guide can say how much may be waiting there.
/// iOS doesn't let apps read that album, so this is never shown as its size. Sizes and dates only.
enum RecentRemovals {
    private static let key = "recentRemovals"

    static func add(_ bytes: Int64, now: Date = .now, store: UserDefaults = .standard) {
        guard bytes > 0 else { return }
        var entries = recent(now: now, store: store)
        entries.append([now.timeIntervalSince1970, Double(bytes)])
        store.set(entries, forKey: key)
    }

    /// Moved in the last 30 days. Some may already be gone if the album was emptied.
    static func bytes(now: Date = .now, store: UserDefaults = .standard) -> Int64 {
        Int64(recent(now: now, store: store).reduce(0) { $0 + $1[1] })
    }

    private static func recent(now: Date, store: UserDefaults) -> [[Double]] {
        let cutoff = now.addingTimeInterval(-30 * 86_400).timeIntervalSince1970
        return (store.array(forKey: key) as? [[Double]] ?? []).filter { $0.count == 2 && $0[0] >= cutoff }
    }
}

/// How much free space came back since the guide was opened. Small changes are just iOS at work.
enum SpaceGained {
    static func bytes(before: Int64, after: Int64) -> Int64? {
        let gained = after - before
        return gained >= 20_000_000 ? gained : nil
    }
}

/// Apple's steps to empty Recently Deleted, with the button names people will see.
struct RecentlyDeletedSteps: View {
    private let steps: [(icon: String, text: LocalizedStringKey)] = [
        ("photo.on.rectangle", "Open the **Photos** app."),
        ("square.stack", "Tap **Collections** at the bottom. (On iOS 17, tap **Albums**.)"),
        ("trash", "Swipe up to **Utilities** and tap **Recently Deleted**."),
        ("faceid", "Tap **View Album** and unlock with Face ID or Touch ID."),
        ("checkmark.circle", "Look through it. Then tap **Select**, and the **•••** button."),
        ("trash.fill", "Tap **Delete All** and confirm.")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(steps.indices, id: \.self) { index in
                HStack(spacing: 14) {
                    Text("\(index + 1)")
                        .font(.title3.bold())
                        .frame(width: 40, height: 40)
                        .foregroundStyle(Color.white)
                        .background(Color(red: 0.722, green: 0.267, blue: 0.102), in: Circle())
                    Text(steps[index].text).font(.body)
                    Spacer(minLength: 0)
                    Image(systemName: steps[index].icon)
                        .font(.title3)
                        .foregroundStyle(Brand.primary)
                        .accessibilityHidden(true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Brand.surface, in: RoundedRectangle(cornerRadius: 16))
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// The first easy win on Free up.
struct RecentlyDeletedCard: View {
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 14) {
                Image(systemName: "trash.circle.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(Brand.primary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Easy win: empty Recently Deleted").font(.headline)
                    Text("Deleted photos still use space for up to 30 days.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(.secondary).accessibilityHidden(true)
            }
            .multilineTextAlignment(.leading)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.surface, in: RoundedRectangle(cornerRadius: 18))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("recently-deleted-card")
    }
}

/// Walks through emptying Recently Deleted, then measures how much space came back.
struct RecentlyDeletedGuide: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    /// Kept between launches: iOS may close TidyAway while Photos is open.
    @AppStorage("recentlyDeletedBefore") private var before = 0.0
    @AppStorage("recentlyDeletedStarted") private var started = 0.0
    @State private var now: Int64 = 0
    @State private var measured = false

    private var gained: Int64? { before > 0 ? SpaceGained.bytes(before: Int64(before), after: now) : nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Empty Recently Deleted").font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text("Photos you delete wait here for up to 30 days and still use space. \(Device.name) doesn't let apps open or empty this album, so here is the quickest way. It takes about a minute.")
                        .foregroundStyle(.secondary)
                    if RecentRemovals.bytes() > 0 {
                        Label("TidyAway moved about \(RecentRemovals.bytes().fileSize) there in the last 30 days.", systemImage: "info.circle")
                            .font(.subheadline)
                    }
                    if measured { resultCard }
                    RecentlyDeletedSteps()
                    Label("This can't be undone. It empties everything in that album, and with iCloud Photos it empties on all your devices. Look through it first.",
                          systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(Brand.caution)
                        .accessibilityIdentifier("recently-deleted-caution")
                    Text("Then come back here. TidyAway measures how much space you got back.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Button { measure() } label: {
                        Text("I emptied it. Measure my space")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 56)
                            .foregroundStyle(Color.white)
                            .background(Color(red: 0.722, green: 0.267, blue: 0.102), in: RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("recently-deleted-measure")
                }
                .frame(maxWidth: 520)
                .padding(20)
                .frame(maxWidth: .infinity)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("recently-deleted-done")
                }
            }
        }
        .onAppear(perform: begin)
        .onChange(of: scenePhase) { old, phase in
            // Coming back from Photos measures by itself.
            if phase == .active, old != .active { measure() }
        }
    }

    private var resultCard: some View {
        HStack(spacing: 14) {
            Image(systemName: gained == nil ? "clock" : "checkmark.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(gained == nil ? Brand.caution : Brand.safe)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if let gained {
                    Text("About \(gained.fileSize) came back").font(.title3.bold())
                    Text("Free space on this \(Device.name) since you opened this guide.").font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("No change yet").font(.title3.bold())
                    Text("If you emptied it, \(Device.name) can take a few minutes to show the space. Measure again soon.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.surface, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("recently-deleted-result")
    }

    /// Remembers the free space to compare with. A start more than an hour old is out of date.
    private func begin() {
        guard let free = DeviceStorage.current()?.available else { return }
        now = free
        if before <= 0 || Date().timeIntervalSince1970 - started > 3_600 {
            before = Double(free)
            started = Date().timeIntervalSince1970
        } else {
            measured = gained != nil
        }
    }

    private func measure() {
        guard let free = DeviceStorage.current()?.available else { return }
        now = free
        measured = true
    }
}
