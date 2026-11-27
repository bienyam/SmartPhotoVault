import Photos
import SwiftUI

/// A part of a group, shown together while skimming.
struct SkimPart: Identifiable {
    let id: String
    let title: String
    let records: [AssetRecord]
    /// In a look-alike set, the photo that stays on the iPhone. Shown first, locked, never moved.
    var keep: AssetRecord? = nil
    var because: String? = nil

    /// One day is split by time of day, several days by day. Look-alike sets are shown set by set with
    /// the photo that stays. Video groups stay in one list, in their own order.
    static func parts(of group: SmartGroup, calendar: Calendar = .current) -> [SkimPart] {
        if group.kind == .sameShots, !group.sets.isEmpty {
            return group.sets.map { set in
                SkimPart(id: set.keep.id, title: "\(set.extras.count + 1) look alike · keeping 1", records: set.extras,
                         keep: set.keep, because: set.because)
            }
        }
        guard group.kind == .event || group.kind == .trip else {
            return [SkimPart(id: "all", title: "All", records: group.records)]
        }
        let days = Set(group.records.compactMap { $0.createdAt.map(calendar.startOfDay) })
        var order: [String] = []
        var sorted: [String: (title: String, records: [AssetRecord])] = [:]
        for record in group.records {
            guard let date = record.createdAt else { continue }
            let key: String, title: String
            if days.count > 1 {
                let day = calendar.startOfDay(for: date)
                key = "\(day.timeIntervalSince1970)"
                title = day.formatted(.dateTime.weekday(.wide).month().day())
            } else {
                switch calendar.component(.hour, from: date) {
                case 5..<12: title = "Morning"
                case 12..<17: title = "Afternoon"
                case 17..<21: title = "Evening"
                default: title = "Night"
                }
                key = title
            }
            if sorted[key] == nil {
                order.append(key)
                sorted[key] = (title, [])
            }
            sorted[key]?.records.append(record)
        }
        return order.compactMap { key in sorted[key].map { SkimPart(id: key, title: $0.title, records: $0.records) } }
    }
}

/// The last picture fully on screen right now.
private struct SkimVisible: PreferenceKey {
    static let defaultValue = 0
    static func reduce(value: inout Int, nextValue: () -> Int) { value = max(value, nextValue()) }
}

/// Look through a whole group quickly. Everything starts selected, because archiving only copies;
/// tap one, or a whole part, to leave it out.
struct GroupSkimView: View {
    let group: SmartGroup
    let next: ([AssetRecord]) -> Void
    @State private var leftOut: Set<String> = []
    @State private var seen = 0
    @State private var visible = 0
    @State private var preview: PreviewRequest?

    /// Everything in the group, the photo that stays first in each look-alike set.
    private var previewItems: [AssetRecord] {
        parts.flatMap { part in (part.keep.map { [$0] } ?? []) + part.records }
    }
    private var keptNotes: [String: String] {
        Dictionary(parts.compactMap { part in
            part.keep.map { ($0.id, "Stays on your \(Device.name): \(part.because ?? "the best of this set")") }
        }, uniquingKeysWith: { first, _ in first })
    }
    /// The viewer ticks what is included; the grid remembers what is left out.
    private var included: Binding<Set<String>> {
        Binding(get: { Set(group.records.map(\.id)).subtracting(leftOut) },
                set: { leftOut = Set(group.records.map(\.id)).subtracting($0) })
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 4)
    private let parts: [SkimPart]
    private let positions: [String: Int]

    init(group: SmartGroup, next: @escaping ([AssetRecord]) -> Void) {
        self.group = group
        self.next = next
        let parts = SkimPart.parts(of: group)
        self.parts = parts
        var positions: [String: Int] = [:]
        for record in parts.flatMap(\.records) { positions[record.id] = positions.count + 1 }
        self.positions = positions
    }

    private var chosen: [AssetRecord] { group.records.filter { !leftOut.contains($0.id) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Label("Why: \(group.reason)", systemImage: "info.circle")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(ArchiveStyle.safeText)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(ArchiveStyle.safeBack, in: Capsule())
                    .accessibilityIdentifier("skim-reason")
                if group.notYet > 0 {
                    Text("\(group.records.count) of \(group.total) can be archived now. Slo-mo, edited videos and some formats can't yet.")
                        .font(.footnote).foregroundStyle(ArchiveStyle.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 6)
            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(parts) { part in
                    Section {
                        if let keep = part.keep { keptCell(keep, because: part.because) }
                        ForEach(part.records) { record in cell(record) }
                    } header: {
                        HStack {
                            Text(part.keep == nil ? "\(part.title) · \(part.records.count)" : part.title).font(.headline)
                            Spacer()
                            Button(allOut(part) ? "Put back in" : "Leave out") { toggle(part) }
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(ArchiveStyle.link)
                                .frame(minHeight: 44)
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
        }
        .hiddenBehindPreview(preview != nil)
        .background(Brand.background)
        .onPreferenceChange(SkimVisible.self) { visible = $0 }
        .task(id: visible) {
            // Rows prepared ahead of scrolling pass through the screen for an instant; only what stays counts.
            try? await Task.sleep(nanoseconds: 250_000_000)
            if !Task.isCancelled, visible > seen { seen = visible }
        }
        .fullScreenCover(item: $preview) { request in
            PhotoPreview(title: group.kind == .pick ? "Your pick" : group.title, items: previewItems, request: request,
                         selectable: Set(group.records.map(\.id)), notes: keptNotes, words: .archive, selected: included)
        }
        .navigationTitle(group.kind == .pick ? "Your pick" : group.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(leftOut.isEmpty ? "Select none" : "Select all") {
                    leftOut = leftOut.isEmpty ? Set(group.records.map(\.id)) : []
                }
                .accessibilityIdentifier("skim-select-all")
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                Text("Seen \(min(seen, group.records.count).formatted()) of \(group.records.count.formatted())\(leftOut.isEmpty ? "" : " · \(leftOut.count.formatted()) left out")")
                    .font(.footnote).foregroundStyle(ArchiveStyle.muted)
                Button("Next · \(chosen.count.formatted()) \(chosen.count == 1 ? "item" : "items") · \(chosen.reduce(Int64(0)) { $0 + $1.displayBytes }.fileSize)") {
                    next(chosen)
                }
                .buttonStyle(ArchiveButtonStyle())
                .disabled(chosen.isEmpty)
                .accessibilityIdentifier("skim-next")
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.regularMaterial)
            .hiddenBehindPreview(preview != nil)
        }
    }

    private func cell(_ record: AssetRecord) -> some View {
        let out = leftOut.contains(record.id)
        let video = record.mediaType == PHAssetMediaType.video.rawValue
        return Button {
            if out { leftOut.remove(record.id) } else { leftOut.insert(record.id) }
        } label: {
            AssetCover(assetID: record.id, side: 200)
                .aspectRatio(1, contentMode: .fit)
                .grayscale(out ? 1 : 0)
                .opacity(out ? 0.35 : 1)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: out ? "circle" : "checkmark.circle.fill")
                        .font(.body.weight(.bold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, out ? Brand.onAccent : Brand.stepBadge)
                        .shadow(radius: 2)
                        .padding(4)
                }
                .overlay(alignment: .bottomLeading) {
                    if video {
                        Text(record.displayBytes.fileSize)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.black.opacity(0.7), in: Capsule())
                            .padding(3)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .previewMenu(assetID: record.id,
                     tick: PreviewTick(title: out ? "Put back in" : "Leave out", action: {
                         if out { leftOut.remove(record.id) } else { leftOut.insert(record.id) }
                     }),
                     open: { preview = PreviewRequest(assetID: record.id) },
                     info: { preview = PreviewRequest(assetID: record.id, showInfo: true) })
        .accessibilityLabel("\(video ? "Video" : "Photo"), \(record.createdAt?.formatted(date: .abbreviated, time: .shortened) ?? record.filename)")
        .accessibilityValue(out ? "Left out" : "Selected")
        .accessibilityAddTraits(out ? [] : .isSelected)
        .accessibilityIdentifier("skim-\(record.id)")
        .background {
            // Counts a picture as seen only once it has really been on screen, a row at a time.
            let position = positions[record.id] ?? 0
            if position % 4 == 0 || position == positions.count {
                GeometryReader { geo in
                    let frame = geo.frame(in: .global)
                    let shown = frame.height > 1 && frame.minY > 60 && frame.maxY < UIScreen.main.bounds.height - 150
                    Color.clear.preference(key: SkimVisible.self, value: shown ? position : 0)
                }
            }
        }
    }

    /// The photo that stays on the iPhone: shown, locked, and never selected or moved.
    private func keptCell(_ record: AssetRecord, because: String?) -> some View {
        AssetCover(assetID: record.id, side: 200)
            .aspectRatio(1, contentMode: .fit)
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(Brand.safe, lineWidth: 3))
            .overlay(alignment: .topTrailing) {
                Image(systemName: "lock.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(Brand.safe, in: Circle())
                    .padding(4)
            }
            .overlay(alignment: .bottomLeading) {
                Text("Stays")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Brand.safe, in: Capsule())
                    .padding(3)
            }
            .contextMenu {
                Text("Stays on your \(Device.name): \(because ?? "the best of this set")")
                Button { preview = PreviewRequest(assetID: record.id) } label: {
                    Label("Open full screen", systemImage: "arrow.up.left.and.arrow.down.right")
                }
            } preview: {
                AssetCover(assetID: record.id, side: 1000).frame(width: 320, height: 420)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Kept photo, stays on your \(Device.name), \(because ?? "the best of this set"). Not moved.")
            .accessibilityIdentifier("skim-kept-\(record.id)")
    }

    private func allOut(_ part: SkimPart) -> Bool { part.records.allSatisfy { leftOut.contains($0.id) } }

    private func toggle(_ part: SkimPart) {
        let ids = part.records.map(\.id)
        if allOut(part) { leftOut.subtract(ids) } else { leftOut.formUnion(ids) }
    }
}
