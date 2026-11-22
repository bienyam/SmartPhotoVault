import Photos
import SwiftUI

/// A part of a group, shown together while skimming.
struct SkimPart: Identifiable {
    let id: String
    let title: String
    let records: [AssetRecord]

    /// One day is split by time of day, several days by day. Video groups stay in one list, in their own order.
    static func parts(of group: SmartGroup, calendar: Calendar = .current) -> [SkimPart] {
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

/// Look through a whole group quickly. Everything starts selected, because archiving only copies;
/// tap one, or a whole part, to leave it out.
struct GroupSkimView: View {
    let group: SmartGroup
    let next: ([AssetRecord]) -> Void
    @State private var leftOut: Set<String> = []
    @State private var seen = 0

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
                    Text("\(group.records.count) of \(group.total) can be archived now. Live Photos, edits and some formats can't yet.")
                        .font(.footnote).foregroundStyle(ArchiveStyle.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 6)
            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(parts) { part in
                    Section {
                        ForEach(part.records) { record in cell(record) }
                    } header: {
                        HStack {
                            Text("\(part.title) · \(part.records.count)").font(.headline)
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
        .background(Brand.background)
        .navigationTitle(group.title)
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
                        .foregroundStyle(.white, out ? Color.white : Color(red: 0.722, green: 0.267, blue: 0.102))
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
        .contextMenu {
            Button(out ? "Put back in" : "Leave out") {
                if out { leftOut.remove(record.id) } else { leftOut.insert(record.id) }
            }
        } preview: {
            AssetCover(assetID: record.id, side: 1000).frame(width: 320, height: 420)
        }
        .accessibilityLabel("\(video ? "Video" : "Photo"), \(record.createdAt?.formatted(date: .abbreviated, time: .shortened) ?? record.filename)")
        .accessibilityValue(out ? "Left out" : "Selected")
        .accessibilityAddTraits(out ? [] : .isSelected)
        .accessibilityIdentifier("skim-\(record.id)")
        .onAppear {
            // A row at a time, so scrolling doesn't redraw the screen for every picture.
            let position = positions[record.id] ?? 0
            if position > seen, position % 4 == 0 || position == positions.count { seen = position }
        }
    }

    private func allOut(_ part: SkimPart) -> Bool { part.records.allSatisfy { leftOut.contains($0.id) } }

    private func toggle(_ part: SkimPart) {
        let ids = part.records.map(\.id)
        if allOut(part) { leftOut.subtract(ids) } else { leftOut.formUnion(ids) }
    }
}
