import SwiftUI
import StoreKit

// The pieces of the 1.0.1 Free up page: the fixed backdrop, the storage card with the Storage Score,
// the three shelves and their rows, and the two sheets (how the score works, and a Pro feature).

/// The page backdrop. It stays where it is while the cards scroll over it.
struct HomeBackdrop: View {
    var body: some View {
        ZStack {
            Brand.backdrop
            RadialGradient(colors: [Brand.backdropGlow, Brand.backdropGlow.opacity(0)],
                           center: .topTrailing, startRadius: 10, endRadius: 420)
            LinearGradient(colors: [Brand.backdropGlow.opacity(0), Brand.backdropGlow.opacity(0.55)],
                           startPoint: .center, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

extension View {
    /// A card on the home pages: white on cream, raised navy on ink, with a soft edge.
    func homeCard(padding: CGFloat = 16) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Brand.cardEdge, lineWidth: 1))
    }
}

extension StorageScore.Band {
    /// Green for A and B, amber for C, deep amber for D and E. The letter and words carry the meaning too.
    var color: Color {
        switch self {
        case .a, .b: Brand.safe
        case .c: Brand.scoreAmber
        case .d, .e: Brand.scoreDeepAmber
        }
    }

    var letterColor: Color {
        switch self {
        case .a, .b: Brand.onScoreGood
        case .c: Brand.onScoreAmber
        case .d, .e: Brand.onScoreDeepAmber
        }
    }
}

/// The band letter in its colored square.
struct BandChip: View {
    let band: StorageScore.Band

    var body: some View {
        Text(band.rawValue)
            .font(.subheadline.weight(.heavy))
            .foregroundStyle(band.letterColor)
            .frame(width: 26, height: 26)
            .background(band.color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// The Storage Score as a ring: the number, out of 100.
struct ScoreRing: View {
    let score: StorageScore
    var size: CGFloat = 104
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().stroke(Brand.track, lineWidth: 11)
            Circle()
                .trim(from: 0, to: max(0.02, Double(score.value) / 100))
                .stroke(score.band.color, style: StrokeStyle(lineWidth: 11, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(score.value)")
                    .font(.system(size: size * 0.36, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Brand.ink)
                    .contentTransition(.numericText())
                Text("of 100").font(.caption).foregroundStyle(Brand.muted)
            }
        }
        .frame(width: size, height: size)
        .padding(6)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.6), value: score.value)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Storage Score \(score.value) of 100. Band \(score.band.rawValue), \(score.band.name).")
        .accessibilityIdentifier("storage-score")
    }
}

/// Diagonal stripes over the worked-out part of the bar, so it reads as an estimate without color.
private struct BarStripes: View {
    var body: some View {
        Canvas { context, size in
            var x = -size.height
            while x < size.width {
                var path = Path()
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                context.stroke(path, with: .color(Brand.storageRestStripe), lineWidth: 3)
                x += 9
            }
        }
    }
}

/// The storage bar: photos and videos, everything else, and free space. Colored as iOS colors its
/// own storage bar: yellow for Photos, gray for the rest, and free space is just the empty track.
struct StorageBar: View {
    let split: StorageSplit
    let photosKnown: Bool

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            HStack(spacing: 2) {
                if photosKnown && split.photos > 0 {
                    Rectangle().fill(Brand.storagePhotos)
                        .frame(width: max(4, width * split.fraction(split.photos)))
                }
                if split.rest > 0 {
                    ZStack {
                        Rectangle().fill(Brand.storageRest)
                        if photosKnown { BarStripes() }
                    }
                    .frame(width: max(4, width * split.fraction(split.rest)))
                    .clipped()
                }
                Rectangle().fill(Brand.storageFree)
            }
            .clipShape(Capsule())
        }
        .frame(height: 12)
        .accessibilityHidden(true)
    }
}

/// The hero card: the Storage Score ring beside how full the iPhone is, then the storage bar.
struct StorageHeroCard<Footer: View>: View {
    let storage: DeviceStorage
    /// Photos and videos measured on this iPhone. Nil until a check has measured them.
    let photos: Int64?
    let showInfo: () -> Void
    @ViewBuilder let footer: Footer
    @Environment(\.dynamicTypeSize) private var typeSize

    private var score: StorageScore { StorageScore(free: storage.available, total: storage.total) }
    private var split: StorageSplit { StorageSplit(storage: storage, photos: photos) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: Device.name == "iPad" ? "ipad" : "iphone")
                    .foregroundStyle(Brand.muted)
                    .accessibilityHidden(true)
                Text("\(Device.name) Storage")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.muted)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: showInfo) {
                    Image(systemName: "info.circle")
                        .imageScale(.large)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .tint(Brand.primary)
                .accessibilityLabel("How the Storage Score works")
                .accessibilityIdentifier("score-info")
            }
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 16))
            layout {
                ScoreRing(score: score)
                VStack(alignment: .leading, spacing: 6) {
                    (Text(storage.used.fileSize).font(.title.weight(.heavy)).foregroundColor(Brand.ink)
                        + Text(" of \(storage.total.fileSize) used").font(.subheadline).foregroundColor(Brand.muted))
                        .accessibilityIdentifier("storage-used")
                    HStack(spacing: 8) {
                        BandChip(band: score.band)
                        Text(score.band.name).font(.title3.weight(.heavy)).foregroundStyle(Brand.ink)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Band \(score.band.rawValue), \(score.band.name)")
                    .accessibilityIdentifier("storage-band")
                }
            }
            // Every explanation (what the score means, measured or worked out, the iOS note) is
            // behind the ⓘ, so the card stays short.
            StorageBar(split: split, photosKnown: photos != nil)
            legend
            footer
        }
        .homeCard()
    }

    /// A compact legend: a dot, the name and the figure on one line each. The first line is photos,
    /// the second holds the rest and free space side by side when they fit.
    @ViewBuilder
    private var legend: some View {
        VStack(alignment: .leading, spacing: 6) {
            if photos != nil {
                StorageLegendItem(color: Brand.storagePhotos, title: "Photos & videos", value: split.photos.fileSize, note: "measured")
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { restAndFree }
                    VStack(alignment: .leading, spacing: 6) { restAndFree }
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { usedAndFree }
                    VStack(alignment: .leading, spacing: 6) { usedAndFree }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var restAndFree: some View {
        StorageLegendItem(color: Brand.storageRest, title: "Apps, System & other", value: "About \(split.rest.fileSize)", note: "worked out")
        StorageLegendItem(color: Brand.storageFree, title: "Free", value: split.free.fileSize, note: "measured", hollow: true)
    }

    @ViewBuilder
    private var usedAndFree: some View {
        StorageLegendItem(color: Brand.storageRest, title: "Used", value: storage.used.fileSize, note: "measured")
        StorageLegendItem(color: Brand.storageFree, title: "Free", value: split.free.fileSize, note: "measured", hollow: true)
    }
}

/// One entry in the storage legend: a dot, the name, then the figure in bold.
struct StorageLegendItem: View {
    let color: Color
    let title: String
    let value: String
    /// "measured" or "worked out", for VoiceOver. The words themselves are in the ⓘ sheet.
    let note: String
    /// Free space is the empty track, so its dot gets a thin edge to show on the card.
    var hollow = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Circle().fill(color).frame(width: 9, height: 9)
                .overlay { if hollow { Circle().stroke(Brand.storageFreeEdge, lineWidth: 1) } }
            Text(title).font(.footnote).foregroundStyle(Brand.muted)
            Text(value).font(.footnote.weight(.bold)).monospacedDigit().foregroundStyle(Brand.ink)
        }
        // One line each at ordinary sizes; at the largest text sizes the name may wrap.
        .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
        .minimumScaleFactor(0.8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value), \(note)")
    }
}

/// A small capital-letter chip: "WORKED OUT", "COPY FIRST".
struct ChipLabel: View {
    let text: String
    var back = Brand.chipBack
    var color = Brand.chipText

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.heavy))
            .tracking(0.5)
            .lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .foregroundStyle(color)
            .background(back, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityLabel(text)
    }
}

/// The PRO badge on features that need TidyAway Pro. The feature itself stays visible.
struct ProBadge: View {
    /// On a photo card the badge is white with dark letters, so it reads over any picture.
    var onPhoto = false

    var body: some View {
        Text("PRO")
            .font(.caption2.weight(.heavy))
            .tracking(0.6)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .foregroundStyle(onPhoto ? Brand.viewer : Brand.background)
            .background(onPhoto ? Brand.onViewer : Brand.ink, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityLabel("Pro")
    }
}

// MARK: - How the score works

/// The sheet behind the ⓘ on the storage card. It holds every explanation the card used to carry:
/// what the score means for this iPhone, how it is worked out, what the bar shows, and what the
/// score is not. Three short sections that open in place, the first one open.
struct ScoreInfoSheet: View {
    enum Part: String, CaseIterable, Identifiable {
        case score, bar, not

        var id: String { rawValue }

        var title: String {
            switch self {
            case .score: "How the score is worked out"
            case .bar: "What the bar shows"
            case .not: "What the score is not"
            }
        }
    }

    let storage: DeviceStorage
    /// Photos and videos measured on this iPhone. Nil until a check has measured them.
    var photos: Int64? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var open: Part? = .score

    private var score: StorageScore { StorageScore(free: storage.available, total: storage.total) }
    private var split: StorageSplit { StorageSplit(storage: storage, photos: photos) }

    private var yours: String {
        let percent = score.freePercent
        let number = percent.replacingOccurrences(of: "%", with: "")
        let line = "Your \(Device.name): \(storage.available.fileSize) ÷ \(storage.total.fileSize) = \(percent) free."
        return score.freeFraction >= 0.25
            ? "\(line) \(number) × 4 is 100 or more, so the score is 100."
            : "\(line) \(number) × 4 = \(score.value)."
    }

    private func spoken(_ band: StorageScore.Band) -> String {
        let line = "Band \(band.rawValue), \(band.name): score \(band.scores.lowerBound) to \(band.scores.upperBound), \(band.freeSpace)."
        return band == score.band ? line + " Your \(Device.name) is here." : line
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    summary
                        .padding(.bottom, 14)
                    ForEach(Part.allCases) { part in
                        Rectangle().fill(Brand.hairline).frame(height: 1)
                        AccordionRow(title: part.title, identifier: "score-part-\(part.rawValue)", open: open == part,
                                     toggle: { open = open == part ? nil : part }) {
                            section(part)
                        }
                    }
                    Rectangle().fill(Brand.hairline).frame(height: 1)
                }
                .frame(maxWidth: 520)
                .padding(20)
                .frame(maxWidth: .infinity)
            }
            .background(Brand.background)
            .navigationTitle("How the Storage Score works")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("score-info-done")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func section(_ part: Part) -> some View {
        switch part {
        case .score: worked
        case .bar: bar
        case .not: isNot
        }
    }

    /// This iPhone's score and what it means, moved here from the card word for word.
    private var summary: some View {
        HStack(alignment: .top, spacing: 12) {
            BandChip(band: score.band)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(score.value) of 100 · \(score.band.name)")
                    .font(.headline).foregroundStyle(Brand.ink)
                Text("Storage Score, based only on free space: \(storage.available.fileSize) is \(score.freePercent) free. \(score.band.advice)")
                    .font(.footnote).foregroundStyle(Brand.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("score-meaning")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var worked: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("It measures one thing: how much of this \(Device.name) is free. Nothing else goes into it.")
                .foregroundStyle(Brand.ink)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 4) {
                Text("Score = free space ÷ total space × 4").font(.headline).foregroundStyle(Brand.ink)
                Text("capped at 100, so 25% free or more scores 100").font(.footnote).foregroundStyle(Brand.muted)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(14)
            .background(Brand.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityElement(children: .combine)
            Text(yours).font(.subheadline).foregroundStyle(Brand.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("score-yours")
            VStack(spacing: 0) {
                ForEach(StorageScore.Band.allCases) { band in
                    HStack(spacing: 12) {
                        BandChip(band: band)
                        Text(band.name).font(.body.weight(.semibold)).foregroundStyle(Brand.ink)
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 1) {
                            Text("\(band.scores.lowerBound)–\(band.scores.upperBound)")
                                .font(.subheadline.weight(.semibold)).monospacedDigit()
                                .foregroundStyle(Brand.ink)
                            Text(band.freeSpace).font(.caption).foregroundStyle(Brand.muted)
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .background(band == score.band ? Brand.surface : Color.clear,
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(spoken(band))
                }
            }
        }
    }

    /// The legend with "Measured" and "Worked out", and the note about how the middle is found.
    private var bar: some View {
        VStack(alignment: .leading, spacing: 12) {
            if photos != nil {
                line(Brand.storagePhotos, "Photos & videos", split.photos.fileSize, workedOut: false)
                line(Brand.storageRest, "Apps, System & other", "About \(split.rest.fileSize)", workedOut: true)
            } else {
                line(Brand.storageRest, "Used", storage.used.fileSize, workedOut: false)
            }
            line(Brand.storageFree, "Free", split.free.fileSize, workedOut: false, hollow: true)
            Text(photos == nil
                 ? "Check your photos to see how much of the used space is photos and videos."
                 : "iOS doesn't share how the rest is split, so the middle figure is worked out by subtraction: \(storage.total.fileSize) less free space and photos & videos. The stripes mark it.")
                .font(.footnote)
                .foregroundStyle(Brand.muted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("score-bar-note")
        }
    }

    private func line(_ color: Color, _ title: String, _ value: String, workedOut: Bool, hollow: Bool = false) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 10, height: 10)
                .overlay { if hollow { Circle().stroke(Brand.storageFreeEdge, lineWidth: 1) } }
            Text(title).font(.subheadline).foregroundStyle(Brand.ink)
            Spacer(minLength: 8)
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(Brand.ink)
            if workedOut {
                ChipLabel(text: "Worked out")
            } else {
                Text("Measured").font(.caption).foregroundStyle(Brand.muted)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value), \(workedOut ? "worked out" : "measured")")
    }

    private var isNot: some View {
        Text("It is not a measure of speed, battery or the health of your \(Device.name). Free space comes from iOS.")
            .font(.subheadline).foregroundStyle(Brand.ink)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Rows that open in place

/// A short title that opens in place to show what is under it. Used for the Help & FAQ questions,
/// the Privacy topics and the sections of the Storage Score sheet. Closed until tapped; the
/// chevron turns when it opens, and VoiceOver says "collapsed" or "expanded".
struct AccordionRow<Content: View>: View {
    let title: String
    /// The title is a button with this identifier.
    let identifier: String
    let open: Bool
    let toggle: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(alignment: .center, spacing: 12) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(open ? ArchiveStyle.link : Brand.ink)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(open ? ArchiveStyle.link : Brand.muted)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(open ? "Expanded" : "Collapsed")
            .accessibilityHint(open ? "Closes it" : "Opens it")
            .accessibilityIdentifier(identifier)
            if open {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 12)
            }
        }
    }
}

/// An accordion row whose content is one paragraph of text, kept word for word. One row is open
/// at a time: `open` holds the identifier of the open row. The paragraph is "<identifier>-answer".
struct AccordionText: View {
    let title: String
    let text: String
    let identifier: String
    @Binding var open: String?

    var body: some View {
        AccordionRow(title: title, identifier: identifier, open: open == identifier,
                     toggle: { open = open == identifier ? nil : identifier }) {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Brand.muted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("\(identifier)-answer")
        }
    }
}

// MARK: - Shelves and rows

/// One group on the Free up page, as a row with its size on the right.
struct TidyRow: Identifiable {
    enum Kind { case type, smart, pro }

    /// How safe a group is to clear, which is how the page is organised.
    enum Shelf: Int, CaseIterable, Identifiable {
        case safe, look, move

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .safe: "Safe to clear"
            case .look: "Worth a look"
            case .move: "Move it, keep it"
            }
        }

        var hint: String {
            switch self {
            case .safe: "Quick to check"
            case .look: "You pick the keepers"
            case .move: "To your drive or cloud"
            }
        }

        var color: Color {
            switch self {
            case .safe: ArchiveStyle.safeText
            case .look: Brand.caution
            case .move: Brand.primary
            }
        }

        var tile: Color {
            switch self {
            case .safe: Brand.safeTile
            case .look: Brand.lookTile
            case .move: Brand.moveTile
            }
        }
    }

    /// Also the row's accessibility identifier, such as "row-duplicates".
    let id: String
    let shelf: Shelf
    let kind: Kind
    let title: String
    let detail: String
    let size: String
    let count: String
    let symbol: String
    /// Space on this iPhone the row could give back, for the shelf's total.
    let bytes: Int64
    var chip: String? = nil
    /// Nil means free for everyone.
    var feature: ProFeature? = nil
    /// What the feature does, for the Pro sheet. Follows the row's name in bold.
    var what: String = ""
    /// A photo from the group, for the picture cards on Worth a look. Nil shows the symbol instead.
    var coverID: String? = nil
}

/// What every row together could give back on this iPhone, counting each item once.
struct TidyTotals: Equatable {
    var shelves: [Int: Int64] = [:]
    var total: Int64 = 0

    /// Items can sit in more than one group (a duplicate screenshot, a look-alike in Best shots),
    /// so the totals count each item once. Phone space only: iCloud-only originals don't count.
    /// Only what the lists let someone select counts: never a favorite, never the photo kept in a
    /// look-alike set, so the estimate matches what can actually be freed.
    static func make(rescue: RescueSummary, smart: [CleanupGroup], archived: [ArchivedPlace], sets: [KeepSet]) -> TidyTotals {
        var safe: [String: Int64] = [:]
        var look: [String: Int64] = [:]
        var move: [String: Int64] = [:]
        let favorites = Set(rescue.snapshot.assets.filter(\.favorite).map(\.id))
        let kept = Set((sets + smart.flatMap(\.sets)).map(\.keep.id))
        func count(_ item: AssetRecord, _ shelf: inout [String: Int64], keptStays: Bool = false) {
            guard !item.favorite, !favorites.contains(item.id), !(keptStays && kept.contains(item.id)) else { return }
            shelf[item.id] = item.localBytes
        }
        for group in rescue.duplicateGroups {
            guard let plan = DuplicateRemovalPlan(group: group) else { continue }
            for asset in group.assets where plan.removeIDs.contains(asset.id) && !asset.favorite { safe[asset.id] = asset.bytes }
        }
        for item in rescue.screenshots.items { count(item, &safe) }
        for place in archived {
            for record in place.records {
                if let photo = record.photoID, !favorites.contains(photo) { safe[photo] = max(safe[photo] ?? 0, record.totalBytes) }
            }
        }
        for group in smart {
            for item in group.items { count(item, &look, keptStays: true) }
        }
        for set in sets {
            for item in set.extras { count(item, &look, keptStays: true) }
        }
        for type in rescue.otherTypes where type.category.allowsRemoval {
            for item in type.items { count(item, &look) }
        }
        for video in rescue.videos { count(video, &move) }

        var totals = TidyTotals()
        totals.shelves[TidyRow.Shelf.safe.rawValue] = safe.values.reduce(0, +)
        totals.shelves[TidyRow.Shelf.look.rawValue] = look.values.reduce(0, +)
        totals.shelves[TidyRow.Shelf.move.rawValue] = move.values.reduce(0, +)
        var all = safe
        all.merge(look) { max($0, $1) }
        all.merge(move) { max($0, $1) }
        totals.total = all.values.reduce(0, +)
        return totals
    }
}

/// A row's label: icon tile, name with any badge, the reason, then size and count on the right.
struct TidyRowLabel: View {
    let row: TidyRow
    let locked: Bool
    /// Smart picks kept free for someone who started on 1.0.
    var yours = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: row.symbol)
                .font(.title3)
                .foregroundStyle(row.shelf.color)
                .frame(width: 44, height: 44)
                .background(row.shelf.tile, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    names
                    HStack(spacing: 6) { figures(alignment: .leading) }
                }
                Spacer(minLength: 0)
            } else {
                names
                Spacer(minLength: 8)
                figures(alignment: .trailing)
            }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Brand.muted)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private var names: some View {
        VStack(alignment: .leading, spacing: 2) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { titleParts }
                VStack(alignment: .leading, spacing: 3) { titleParts }
            }
            Text(row.detail).font(.footnote).foregroundStyle(Brand.muted)
                .multilineTextAlignment(.leading)
        }
    }

    @ViewBuilder
    private var titleParts: some View {
        Text(row.title).font(.headline).foregroundStyle(Brand.ink)
            .multilineTextAlignment(.leading)
        if locked { ProBadge() }
        if yours { ChipLabel(text: "Yours", back: Brand.safeTile, color: ArchiveStyle.safeText) }
        if let chip = row.chip { ChipLabel(text: chip, back: row.shelf.tile, color: row.shelf.color) }
    }

    private func figures(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(row.size).font(.headline).monospacedDigit().foregroundStyle(Brand.ink)
            if !row.count.isEmpty {
                Text(row.count).font(.footnote).foregroundStyle(Brand.muted)
            }
        }
        .lineLimit(1)
    }
}

/// A Worth a look group as a picture card, the same card Archive uses for "Or start here"
/// (`ArchiveCard`): a photo from the group, a dark fade, and white words on it. Free up adds the
/// size and count on the right, a chevron, and the PRO badge. The words are white on a fade that is
/// at least 65% black behind them, so they read over any photo, in light and dark mode alike.
struct TidyPhotoCard: View {
    let row: TidyRow
    let locked: Bool
    /// Smart picks kept free for someone who started on 1.0.
    var yours = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    names
                    figures(alignment: .leading)
                }
                Spacer(minLength: 0)
            } else {
                names
                Spacer(minLength: 8)
                figures(alignment: .trailing)
            }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .padding(.bottom, 4)
                .accessibilityHidden(true)
        }
        .foregroundStyle(Brand.onViewer)
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .bottomLeading)
        .background { cover }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(Rectangle())
    }

    private var cover: some View {
        ZStack {
            if let coverID = row.coverID {
                AssetCover(assetID: coverID, side: 600)
            } else {
                LinearGradient(colors: [Brand.navyAccent, Brand.primary], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: row.symbol)
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(Brand.onViewer.opacity(0.35))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(12)
            }
            LinearGradient(colors: [Brand.viewer.opacity(0.25), Brand.viewer.opacity(0.82)], startPoint: .top, endPoint: .bottom)
        }
        .accessibilityHidden(true)
    }

    private var names: some View {
        VStack(alignment: .leading, spacing: 2) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { titleParts }
                VStack(alignment: .leading, spacing: 3) { titleParts }
            }
            Text(row.detail).font(.footnote)
                .multilineTextAlignment(.leading)
        }
    }

    @ViewBuilder
    private var titleParts: some View {
        Text(row.title).font(.headline)
            .multilineTextAlignment(.leading)
        if locked { ProBadge(onPhoto: true) }
        if yours { ChipLabel(text: "Yours", back: Brand.onViewer, color: Brand.viewer) }
        if let chip = row.chip { ChipLabel(text: chip, back: Brand.onViewer, color: Brand.viewer) }
    }

    private func figures(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(row.size).font(.headline).monospacedDigit()
            if !row.count.isEmpty {
                Text(row.count).font(.footnote)
            }
        }
        .lineLimit(1)
    }
}

/// A shelf's heading: its name, a hint and what it adds up to.
struct ShelfHeader: View {
    let shelf: TidyRow.Shelf
    let total: Int64

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(shelf.color).frame(width: 9, height: 9)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) { words }
                VStack(alignment: .leading, spacing: 1) { words }
            }
            Spacer(minLength: 8)
            Text(total.fileSize).font(.subheadline.weight(.semibold)).monospacedDigit()
                .foregroundStyle(Brand.muted)
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(shelf.title). \(shelf.hint). About \(total.fileSize).")
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("shelf-\(shelf.rawValue)")
    }

    @ViewBuilder
    private var words: some View {
        Text(shelf.title).font(.subheadline.weight(.heavy)).foregroundStyle(shelf.color)
        Text(shelf.hint).font(.footnote).foregroundStyle(Brand.muted)
    }
}

// MARK: - A Pro feature, on a half sheet

/// What a locked row says about itself when tapped.
struct ProOffer: Identifiable {
    let id: String
    let title: String
    /// Follows the title: "groups look-alike shots…"
    let what: String
    /// The person's own numbers, when there are any.
    let found: String?
    let symbol: String
}

/// The half sheet's buy button and the line under it. With a free trial the billed price is in the
/// button itself and leads the line under it, so the amount charged is never quieter than the trial
/// (App Review guideline 3.1.2). Prices and the trial length come from the App Store.
enum ProSheetCopy {
    static func button(trial: String?, price: String?, unit: String) -> String {
        guard let price else { return "Get TidyAway Pro" }
        if trial != nil { return "Try free, then \(price)/\(unit)" }
        return "Get Pro · \(price) a \(unit)"
    }

    static func priceLine(trial: String?, price: String?, unit: String, loading: Bool) -> String {
        guard let price else {
            return loading ? "Getting the price from the App Store…" : "The price is shown by the App Store before you pay."
        }
        if let trial { return "\(price) a \(unit) after the \(trial) free trial. Cancel anytime in Settings." }
        return "Renews each \(unit) until you cancel. Cancel anytime in Settings."
    }
}

/// "Available in TidyAway Pro": what the feature does, one benefit, the trial and the price from
/// the App Store, then See all plans and Not now. Opens only when a PRO item is tapped.
struct ProFeatureSheet: View {
    let offer: ProOffer
    @EnvironmentObject private var pro: ProStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var showPlans = false

    /// The plan this sheet offers: yearly, which carries the free trial. Monthly only when the App
    /// Store has no yearly plan right now. Every plan is still under See all plans.
    private var offered: (product: Product?, id: String, unit: String) {
        if pro.yearly != nil || pro.monthly == nil { return (pro.yearly, ProStore.yearlyID, "year") }
        return (pro.monthly, ProStore.monthlyID, "month")
    }

    /// The free trial, if this Apple Account can still have it. Length and price come from the App Store.
    private var trial: String? {
        guard pro.trialEligible, let intro = offered.product?.subscription?.introductoryOffer,
              intro.paymentMode == .freeTrial else { return nil }
        return ProStore.trialName(intro.period.value, intro.period.unit)
    }

    private var buttonTitle: String {
        ProSheetCopy.button(trial: trial, price: offered.product?.displayPrice, unit: offered.unit)
    }

    private var priceLine: String {
        ProSheetCopy.priceLine(trial: trial, price: offered.product?.displayPrice, unit: offered.unit,
                               loading: pro.loadingProducts || pro.waitingToBuy != nil)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: offer.symbol)
                        .font(.title2)
                        .foregroundStyle(Brand.caution)
                        .frame(width: 52, height: 52)
                        .background(Brand.lookTile, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        ProBadge()
                        Text("Available in TidyAway Pro")
                            .font(.title2.weight(.heavy))
                            .foregroundStyle(Brand.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("pro-sheet-title")
                    }
                }
                (Text(offer.title).fontWeight(.bold).foregroundColor(Brand.ink)
                    + Text(" \(offer.what)").foregroundColor(Brand.muted))
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                if let found = offer.found {
                    Label(found, systemImage: "checkmark")
                        .font(.subheadline)
                        .foregroundStyle(Brand.ink)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Brand.safeTile, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .accessibilityIdentifier("pro-sheet-found")
                }
                Button {
                    Task { await pro.buy(offered.id) }
                } label: {
                    HStack(spacing: 8) {
                        Text(buttonTitle)
                        if offered.product == nil && (pro.loadingProducts || pro.waitingToBuy != nil) {
                            ProgressView().tint(ArchiveStyle.onAction).accessibilityLabel("Getting the price")
                        }
                    }
                }
                .buttonStyle(ArchiveButtonStyle())
                .disabled(pro.busy)
                .accessibilityIdentifier("pro-sheet-start")
                // The amount charged is as prominent as the trial: the same size and weight as the
                // button's label, in the main text colour (App Review guideline 3.1.2).
                Text(priceLine)
                    .font(offered.product == nil ? Font.footnote : Font.body.weight(.semibold))
                    .foregroundStyle(offered.product == nil ? Brand.muted : Brand.ink)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("pro-sheet-price")
                if pro.connecting {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Connecting to the App Store…")
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Brand.muted)
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .combine)
                }
                if let notice = pro.notice {
                    Text(notice).font(.footnote).foregroundStyle(Brand.caution)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                }
                HStack(spacing: 28) {
                    Button("See all plans") { showPlans = true }
                        .font(.body.weight(.semibold))
                        .tint(ArchiveStyle.link)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("pro-sheet-plans")
                    Button("Not now") { dismiss() }
                        .font(.body)
                        .tint(Brand.muted)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("pro-sheet-not-now")
                }
                .frame(maxWidth: .infinity)
                HStack(spacing: 16) {
                    Button("Terms of Use") { openURL(ProPurchaseControls.termsURL) }
                    Button("Privacy Policy") { openURL(ProPurchaseControls.privacyURL) }
                }
                .font(.caption)
                .tint(Brand.muted)
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 22)
            .padding(.top, 26)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity)
        }
        .background(Brand.background)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onChange(of: pro.unlocked) { _, unlocked in
            if unlocked { dismiss() }
        }
        // "Not now", a swipe down or leaving the screen: a plan queued here is not bought later.
        .onDisappear { pro.cancelQueuedBuy() }
        .sheet(isPresented: $showPlans) {
            NavigationStack {
                ProUpgradeView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Close") { showPlans = false } }
                    }
            }
            .environmentObject(pro)
        }
    }
}

extension View {
    /// Opens the half sheet for a Pro feature. Used wherever a PRO item can be tapped.
    func proSheet(_ offer: Binding<ProOffer?>, pro: ProStore) -> some View {
        sheet(item: offer) { ProFeatureSheet(offer: $0).environmentObject(pro) }
    }
}

/// One thank-you for people who started on 1.0, shown once.
struct EarlySupporterNote: View {
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Thanks for being here early").font(.headline).foregroundStyle(Brand.ink)
                .accessibilityAddTraits(.isHeader)
            Text("Smart picks are now part of TidyAway Pro. You had them in 1.0, so they stay free for you.")
                .font(.subheadline).foregroundStyle(Brand.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button("OK", action: dismiss)
                .font(.subheadline.weight(.bold))
                .tint(ArchiveStyle.link)
                .frame(minHeight: 44)
                .accessibilityIdentifier("early-note-ok")
        }
        .homeCard()
    }
}
