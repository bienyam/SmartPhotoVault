import SwiftUI

/// What is free and what Pro adds, in one place, so the Pro page and its tests read the same lists.
enum ProPlanLists {
    /// What stays free, word for word what the app does.
    static let alwaysFree: [(text: String, icon: String)] = [
        ("Find and clear large videos, duplicates, screenshots and more", "sparkles"),
        ("Preview any photo or video before you choose it", "eye"),
        ("Archive up to 5 GB, with every copy checked", "archivebox"),
        ("Every archive destination: a drive, Files, iCloud Drive and cloud services", "externaldrive"),
        ("Nothing is deleted without your sign-off and the iOS confirmation", "checkmark.shield"),
        ("Get archived items back, always", "arrow.uturn.backward"),
        ("Favorites are never deleted", "heart"),
        ("Activity record and storage analysis", "list.bullet.rectangle"),
        ("Storage Score and the Storage Checkup", "gauge.with.dots.needle.67percent"),
        ("A monthly check-in reminder", "bell")
    ]

    static var addedWithPro: [(text: String, icon: String)] {
        [("Smart picks on Free up: look-alike shots, blurry, accidental and more, with one suggestion to review", "sparkles.rectangle.stack"),
         ("Archive without a limit", "infinity"),
         ("Archive groups by event, trip and topic", "rectangle.stack"),
         ("Choose what to archive by album, place and size", "line.3.horizontal.decrease.circle"),
         ("Daily or weekly check-ins, space alerts and reminders before big events", "bell.badge"),
         ("Smart Pro on this \(Device.name): best shots with the reason, screenshots sorted by what they say, and photos already archived", "wand.and.stars")]
    }
}

/// The one place that explains TidyAway Pro. It never interrupts: people open it from More,
/// or from "See all plans" on the half sheet where a Pro feature starts.
struct ProUpgradeView: View {
    @EnvironmentObject private var pro: ProStore
    @Environment(\.dynamicTypeSize) private var typeSize

    /// The lists are longer than one screen, so the plans stay pinned at the bottom. At the largest
    /// text sizes they would cover the page, so they sit in the page instead.
    private var pinned: Bool { !typeSize.isAccessibilitySize }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("TidyAway Pro").font(.title2.bold())
                    Text("Monthly, yearly, or once for life. Your choice.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }
            Section("Always free") {
                ForEach(ProPlanLists.alwaysFree, id: \.text) { item in
                    Label(item.text, systemImage: item.icon)
                }
            }
            Section {
                ForEach(ProPlanLists.addedWithPro, id: \.text) { item in
                    Label(item.text, systemImage: item.icon)
                }
            } header: {
                Text("Added with Pro")
            } footer: {
                if pro.grandfathered && !pro.unlocked {
                    Text("You started on TidyAway 1.0, so smart picks on Free up stay free for you.")
                        .accessibilityIdentifier("pro-grandfathered")
                }
            }
            Section {
                ProPurchaseControls(part: pinned ? .terms : .all)
            } footer: {
                Text("Pro is optional. Cleaning up your \(Device.name) and getting your photos back stay free.")
            }
        }
        .navigationTitle("TidyAway Pro")
        .navigationBarTitleDisplayMode(.inline)
        // A plan tapped before its price arrived is not bought after this page has gone.
        .onDisappear { pro.cancelQueuedBuy() }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if pinned {
                ProPurchaseControls(part: .plans)
                    .frame(maxWidth: 520)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(.regularMaterial)
                    .overlay(alignment: .top) { Divider() }
            }
        }
    }
}
