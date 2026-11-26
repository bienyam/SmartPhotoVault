import StoreKit
import SwiftUI

// One more check before deleting what isn't backed up, and the App Store rating prompt.

/// The kinds of delete in TidyAway, for the "not backed up" check.
enum DeleteFlow: CaseIterable {
    /// Only extra copies go; one byte-identical copy always stays on the iPhone.
    case duplicates
    /// Every item has a verified copy, which is checked again before removal.
    case alreadyArchived
    /// Any pick list: Large videos, Screenshots, the Worth a look groups, More types, and lists
    /// opened from a check-in.
    case list

    /// Duplicates and Already archived lose nothing, so asking there would warn about nothing
    /// and teach people to tap past it. Everywhere else the check runs, every time.
    var checksBackup: Bool { self == .list }
}

/// What a selection looks like against the archive: how many of the items picked for deleting
/// have a verified TidyAway archive copy, and how many don't.
///
/// "Backed up" means a verified record in TidyAway's own archive list, the same record Already
/// archived uses. iCloud Photos does not count: deleting from Photos removes the item from
/// iCloud too.
struct BackupCheck: Identifiable {
    let id = UUID()
    let backedUp: [AssetRecord]
    let notBackedUp: [AssetRecord]

    var total: Int { backedUp.count + notBackedUp.count }
    var notBackedUpBytes: Int64 { notBackedUp.reduce(0) { $0 + $1.displayBytes } }

    /// The alert shows only when something could really be lost.
    var needsAlert: Bool { !notBackedUp.isEmpty }

    /// `archived` holds the Photos identifiers that have a verified archive record.
    init(selected: [AssetRecord], archived: Set<String>) {
        backedUp = selected.filter { archived.contains($0.id) }
        notBackedUp = selected.filter { !archived.contains($0.id) }
    }

    /// Whether to stop and ask before this delete. Nil means go straight on to Apple's confirmation.
    static func alert(for flow: DeleteFlow, selected: [AssetRecord], archived: Set<String>) -> BackupCheck? {
        guard flow.checksBackup else { return nil }
        let check = BackupCheck(selected: selected, archived: archived)
        return check.needsAlert ? check : nil
    }

    var title: String {
        let count = notBackedUp.count
        if total == 1 { return "This one isn't backed up" }
        return count == 1 ? "1 of these isn't backed up" : "\(count.formatted()) of these aren't backed up"
    }

    var message: String {
        notBackedUp.count == 1
            ? "Once deleted and Recently Deleted is emptied, it's gone. Copy it first?"
            : "Once deleted and Recently Deleted is emptied, they're gone. Copy them first?"
    }

    var backedUpLine: String { "\(backedUp.count.formatted()) backed up" }
    var notBackedUpLine: String { "\(notBackedUp.count.formatted()) not backed up" }
}

/// The Photos identifiers that have a verified TidyAway archive copy.
enum BackupLedger {
    static func photoIDs(in records: [ArchivedRecord]) -> Set<String> {
        Set(records.compactMap(\.photoID))
    }

    /// Read from the archive list on this iPhone. If the list can't be read, nothing counts as
    /// backed up, so the check errs on the side of asking.
    static func verifiedPhotoIDs() -> Set<String> {
        guard let records = try? InventoryStore.openDefault().archived() else { return [] }
        return photoIDs(in: records)
    }
}

/// The TidyAway alert shown after the sign-off and before Apple's own confirmation, when some of
/// the selected items have no verified archive copy. Copy first sends only those items to Archive;
/// Delete anyway goes on to Apple's confirmation; tapping outside cancels. No red: the words and
/// the count carry the warning.
struct BackupAlert: View {
    let check: BackupCheck
    let copyFirst: () -> Void
    let deleteAnyway: () -> Void
    let cancel: () -> Void

    var body: some View {
        ZStack {
            Brand.viewer.opacity(0.45)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: cancel)
                .accessibilityHidden(true)
            // The card as it is when it fits; at the largest text sizes, the same card scrolling.
            ViewThatFits(in: .vertical) {
                card.padding(24)
                ScrollView { card.padding(24) }
            }
        }
    }

    private var card: some View {
        VStack(spacing: 14) {
            Image(systemName: "archivebox")
                .font(.title2)
                .foregroundStyle(Brand.primary)
                .frame(width: 52, height: 52)
                .background(Brand.moveTile, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityHidden(true)
            Text(check.title)
                .font(.title3.weight(.heavy))
                .foregroundStyle(Brand.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("backup-title")
            Text(check.message)
                .font(.subheadline)
                .foregroundStyle(Brand.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 0) {
                line(symbol: "checkmark", color: Brand.safe, bold: check.backedUpLine, rest: "verified copy in your archive")
                    .accessibilityIdentifier("backup-have")
                Rectangle().fill(Brand.hairline).frame(height: 1)
                line(symbol: "circle", color: Brand.caution, bold: check.notBackedUpLine, rest: check.notBackedUpBytes.fileSize)
                    .accessibilityIdentifier("backup-missing")
            }
            .padding(.horizontal, 14)
            .background(Brand.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Button("Copy first", action: copyFirst)
                .buttonStyle(ArchiveButtonStyle())
                .accessibilityHint("Opens Archive with the items that aren't backed up")
                .accessibilityIdentifier("backup-copy-first")
            Button("Delete anyway", action: deleteAnyway)
                .font(.body.weight(.semibold))
                .tint(Brand.muted)
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityHint("Apple asks you to confirm next")
                .accessibilityIdentifier("backup-delete-anyway")
        }
        .padding(20)
        .frame(maxWidth: 420)
        .background(Brand.background, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        // VoiceOver's two-finger scrub closes it, the same as tapping outside.
        .accessibilityAction(.escape, cancel)
    }

    private func line(symbol: String, color: Color, bold: String, rest: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .font(.footnote.weight(.bold))
                .foregroundStyle(color)
                .frame(width: 18)
                .accessibilityHidden(true)
            (Text(bold).fontWeight(.bold).foregroundColor(Brand.ink) + Text(" · \(rest)").foregroundColor(Brand.muted))
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Rating prompt

/// When to ask for an App Store rating: once, after the second cleanup or archive that finished
/// well. The count is kept on this iPhone. The request itself is Apple's own prompt, which Apple
/// limits to a few times a year and may not show at all. It is only made once the result screen has
/// been closed, so never during a delete, a sign-off or on a Pro screen. Nothing is tracked or sent.
enum RatingPrompt {
    static let countKey = "rating.completions"
    static let askedKey = "rating.asked"
    /// The second finished cleanup or archive.
    static let askAfter = 2

    /// Call when a cleanup or an archive finished with something done.
    static func noteCompletion(store: UserDefaults = .standard) {
        store.set(store.integer(forKey: countKey) + 1, forKey: countKey)
    }

    static func completions(store: UserDefaults = .standard) -> Int { store.integer(forKey: countKey) }

    /// True once, the first time this is called after the second completion.
    static func takeDue(store: UserDefaults = .standard) -> Bool {
        guard store.integer(forKey: countKey) >= askAfter, !store.bool(forKey: askedKey) else { return false }
        store.set(true, forKey: askedKey)
        return true
    }
}

private struct RatingAsk: ViewModifier {
    let trigger: Int
    @Environment(\.requestReview) private var requestReview

    func body(content: Content) -> some View {
        content.onChange(of: trigger) {
            // UI tests and sample data never ask: Apple's prompt would cover the screen.
            guard !LaunchFlags.has("--skip-welcome"), !LaunchFlags.has("--demo"), RatingPrompt.takeDue() else { return }
            requestReview()
        }
    }
}

extension View {
    /// Asks for a rating, if one is due, each time `trigger` changes. Raise the trigger when a
    /// result screen closes, never while a delete or a purchase is under way.
    func asksForRating(when trigger: Int) -> some View {
        modifier(RatingAsk(trigger: trigger))
    }
}
