import Foundation
import Photos

/// Turns recognized labels into things people say: "Beach trip", "Birthday party", "Receipts and papers".
enum Recognition {
    struct Moment {
        let name: String
        /// Used instead when the group is a trip of several days.
        var tripName: String? = nil
        let labels: Set<String>
        /// The share of pictures that must show it.
        let share: Double
        let minimum: Int
        /// What the reason says, such as "beach or sea".
        let words: String
    }

    /// The most telling first: one cake says more about a day than fifty faces.
    static let moments: [Moment] = [
        Moment(name: "Wedding", labels: ["wedding", "wedding_dress", "wedding_cake", "bride", "groom"], share: 0.06, minimum: 4, words: "a wedding"),
        Moment(name: "Birthday party", labels: ["birthday_cake"], share: 0.02, minimum: 2, words: "a birthday cake"),
        Moment(name: "Graduation", labels: ["graduation"], share: 0.05, minimum: 3, words: "a graduation"),
        Moment(name: "Christmas", labels: ["christmas_tree", "christmas_decoration"], share: 0.06, minimum: 4, words: "a Christmas tree"),
        Moment(name: "Fireworks", labels: ["fireworks"], share: 0.12, minimum: 4, words: "fireworks"),
        Moment(name: "Concert", labels: ["concert"], share: 0.15, minimum: 4, words: "a concert"),
        Moment(name: "Amusement park", labels: ["amusement_park", "rollercoaster", "ferris_wheel"], share: 0.08, minimum: 4, words: "rides"),
        Moment(name: "Game day", labels: ["stadium"], share: 0.15, minimum: 5, words: "a stadium"),
        Moment(name: "Snow day", tripName: "Snow trip", labels: ["snow", "skiing", "snowboarding"], share: 0.22, minimum: 6, words: "snow"),
        Moment(name: "Beach day", tripName: "Beach trip", labels: ["beach"], share: 0.22, minimum: 6, words: "a beach"),
        Moment(name: "Mountains", tripName: "Mountain trip", labels: ["mountain"], share: 0.25, minimum: 6, words: "mountains")
    ]

    struct Topic {
        let id: String
        let name: String
        let labels: Set<String>
        let words: String
    }

    static let topics: [Topic] = [
        Topic(id: "papers", name: "Receipts and papers", labels: ["receipt", "document"], words: "receipts or documents"),
        Topic(id: "whiteboards", name: "Whiteboards", labels: ["whiteboard"], words: "whiteboards"),
        Topic(id: "food", name: "Food", labels: ["food"], words: "food"),
        Topic(id: "pets", name: "Pets", labels: ["dog", "cat", "adult_cat"], words: "dogs or cats"),
        Topic(id: "scenery", name: "Sunsets and scenery", labels: ["sunset_sunrise", "mountain"], words: "sunsets or mountains"),
        Topic(id: "flowers", name: "Flowers", labels: ["flower"], words: "flowers"),
        Topic(id: "cars", name: "Cars", labels: ["car", "sportscar"], words: "cars"),
        Topic(id: "art", name: "Art", labels: ["art"], words: "art")
    ]

    /// The only labels that are kept.
    static let known: Set<String> = moments.reduce(into: Set(topics.flatMap(\.labels))) { $0.formUnion($1.labels) }

    /// The name that fits a set of pictures, with how many of them show it. Nil when nothing stands out.
    static func moment(for records: [AssetRecord], insights: [String: PhotoInsight]) -> (moment: Moment, share: Double)? {
        let looked = records.compactMap { insights[$0.id] }
        // Too few results so far would name a day after its first pictures.
        guard looked.count >= 10, Double(looked.count) >= Double(records.count) * 0.6 else { return nil }
        for moment in moments {
            let hits = looked.reduce(0) { $0 + (moment.labels.isDisjoint(with: $1.labels) ? 0 : 1) }
            let share = Double(hits) / Double(looked.count)
            if hits >= moment.minimum, share >= moment.share { return (moment, share) }
        }
        return nil
    }
}

extension SmartGrouper {
    static let topicMinimum = 15
    static let goals: [Int64] = [5, 10, 20]

    /// Everything, named by what it shows when that is known.
    static func groups(in snapshot: ScanSnapshot, insights: [String: PhotoInsight], facts: [String: AssetFacts],
                       now: Date = .now, calendar: Calendar = .current) -> [SmartGroup] {
        var result = groups(in: snapshot, now: now, calendar: calendar).map { named($0, insights: insights) }
        if let same = sameShots(in: snapshot.assets, insights: insights, facts: facts) { result.append(same) }
        result += topics(in: snapshot.assets, insights: insights)
        result += videoGroups(in: snapshot.assets, facts: facts)
        return result
    }

    private static func named(_ group: SmartGroup, insights: [String: PhotoInsight]) -> SmartGroup {
        guard group.kind == .event || group.kind == .trip,
              let found = Recognition.moment(for: group.records, insights: insights) else { return group }
        var group = group
        group.when = group.title
        group.title = (group.kind == .trip ? found.moment.tripName : nil) ?? found.moment.name
        let percent = Int((found.share * 100).rounded())
        group.reason = "Looks like \(found.moment.words), in \(percent)% of the pictures"
        return group
    }

    // MARK: - Same shot

    /// Pictures taken moments apart that look alike, in order. Each chain is one series.
    static func series(in assets: [AssetRecord], insights: [String: PhotoInsight]) -> [[AssetRecord]] {
        let photos = assets
            .filter { $0.mediaType == PHAssetMediaType.image.rawValue && $0.createdAt != nil && $0.isScreenshot != true }
            .sorted { $0.createdAt! == $1.createdAt! ? $0.id < $1.id : $0.createdAt! < $1.createdAt! }
        var result: [[AssetRecord]] = []
        var current: [AssetRecord] = []
        for photo in photos {
            if let last = current.last, insights[photo.id]?.sameAs == last.id {
                current.append(photo)
            } else {
                if current.count > 1 { result.append(current) }
                current = [photo]
            }
        }
        if current.count > 1 { result.append(current) }
        return result
    }

    /// The one that stays on the iPhone: a favorite, then one the person edited, then the sharpest.
    static func best(of series: [AssetRecord], insights: [String: PhotoInsight], facts: [String: AssetFacts]) -> AssetRecord? {
        series.max { a, b in
            if a.favorite != b.favorite { return b.favorite }
            let editedA = facts[a.id]?.edited ?? false, editedB = facts[b.id]?.edited ?? false
            if editedA != editedB { return editedB }
            let sharpA = insights[a.id]?.sharpness ?? 0, sharpB = insights[b.id]?.sharpness ?? 0
            return sharpA == sharpB ? a.id > b.id : sharpA < sharpB
        }
    }

    static func extras(in assets: [AssetRecord], insights: [String: PhotoInsight], facts: [String: AssetFacts]) -> [AssetRecord] {
        Self.series(in: assets, insights: insights).flatMap { series -> [AssetRecord] in
            guard let best = Self.best(of: series, insights: insights, facts: facts) else { return [] }
            return series.filter { $0.id != best.id && !$0.favorite && !(facts[$0.id]?.edited ?? false) }
        }
    }

    private static func sameShots(in assets: [AssetRecord], insights: [String: PhotoInsight], facts: [String: AssetFacts]) -> SmartGroup? {
        let all = extras(in: assets, insights: insights, facts: facts)
        let ready = all.filter(canArchive)
        guard ready.count >= 5 else { return nil }
        return SmartGroup(id: "same-shots", kind: .sameShots, title: "Lots of the same shot",
                          reason: "Taken seconds apart and look alike. The sharpest one stays on your iPhone",
                          records: ready, notYet: all.count - ready.count, when: "Best one stays")
    }

    // MARK: - Topics

    private static func topics(in assets: [AssetRecord], insights: [String: PhotoInsight]) -> [SmartGroup] {
        Recognition.topics.compactMap { topic -> SmartGroup? in
            let all = assets
                .filter { !$0.favorite && !topic.labels.isDisjoint(with: insights[$0.id]?.labels ?? []) }
                .sorted { ($0.createdAt ?? .distantPast, $0.id) < ($1.createdAt ?? .distantPast, $1.id) }
            let ready = all.filter(canArchive)
            guard ready.count >= topicMinimum else { return nil }
            return SmartGroup(id: "topic-\(topic.id)", kind: .topic, title: topic.name, reason: "Looks like \(topic.words)",
                              records: ready, notYet: all.count - ready.count)
        }
        .appending(darkShots(in: assets, insights: insights))
        .sorted { $0.bytes > $1.bytes }
    }

    /// Below this average light a photo shows next to nothing: taken in a pocket, a bag or the dark.
    static let darkLevel = 14.0

    /// Photos too dark to see anything in. Almost always taken by accident.
    private static func darkShots(in assets: [AssetRecord], insights: [String: PhotoInsight]) -> SmartGroup? {
        let all = assets
            .filter { record in
                guard record.mediaType == PHAssetMediaType.image.rawValue, !record.favorite,
                      let light = insights[record.id]?.brightness else { return false }
                return light < darkLevel
            }
            .sorted { ($0.createdAt ?? .distantPast, $0.id) < ($1.createdAt ?? .distantPast, $1.id) }
        let ready = all.filter(canArchive)
        guard ready.count >= 5 else { return nil }
        return SmartGroup(id: "topic-dark", kind: .topic, title: "Too dark to see", reason: "Almost black, often taken by accident",
                          records: ready, notYet: all.count - ready.count)
    }

    // MARK: - Videos

    private static func videoGroups(in assets: [AssetRecord], facts: [String: AssetFacts]) -> [SmartGroup] {
        let videos = assets
            .filter { $0.mediaType == PHAssetMediaType.video.rawValue && !$0.favorite }
            .sorted { $0.displayBytes == $1.displayBytes ? $0.id < $1.id : $0.displayBytes > $1.displayBytes }
        func group(_ id: String, _ title: String, _ reason: String, _ matches: (AssetRecord) -> Bool) -> SmartGroup? {
            let all = videos.filter(matches)
            let ready = all.filter(canArchive)
            guard !ready.isEmpty else { return nil }
            return SmartGroup(id: id, kind: .videos, title: title, reason: reason, records: ready, notYet: all.count - ready.count)
        }
        return [
            group("long-videos", "Long videos", "Over 5 minutes") { (facts[$0.id]?.duration ?? 0) > 300 },
            group("4k-videos", "4K videos", "Recorded in 4K") { max($0.pixelWidth ?? 0, $0.pixelHeight ?? 0) >= 3840 },
            group("time-lapse", "Time-lapse", "Recorded as time-lapse") { PHAssetMediaSubtype(rawValue: $0.subtypes ?? 0).contains(.videoTimelapse) },
            // Marked by iOS when the screen was recorded.
            group("screen-recordings", "Screen recordings", "Recorded from your screen") { ($0.subtypes ?? 0) & 524_288 != 0 }
        ].compactMap { $0 }
    }

    // MARK: - A pick that reaches a goal

    /// How likely an item is to be fine off the iPhone. Nil means it is never picked.
    static func score(_ record: AssetRecord, insight: PhotoInsight?, facts: AssetFacts?, extra: Bool, now: Date) -> Double? {
        guard !record.favorite, canArchive(record), let taken = record.createdAt else { return nil }
        let days = now.timeIntervalSince(taken) / 86_400
        var score = min(Double(record.displayBytes) / 100_000_000, 5)
        if days > 730 { score += 2 }
        if extra { score += 3 }
        if let labels = insight?.labels, !Set(["receipt", "document", "whiteboard"]).isDisjoint(with: labels) { score += 2 }
        if (facts?.duration ?? 0) > 300 { score += 1 }
        if days < 90 { score -= 4 }
        if facts?.edited == true { score -= 4 }
        if !(record.albumIDs ?? []).isEmpty { score -= 3 }
        if insight?.closeFace == true { score -= 1 }
        return score > 0.5 ? score : nil
    }

    /// Enough to reach a goal, what is least likely to be missed first.
    static func pick(goal gigabytes: Int64, in assets: [AssetRecord], insights: [String: PhotoInsight], facts: [String: AssetFacts],
                     now: Date = .now) -> SmartGroup? {
        let extras = Set(Self.extras(in: assets, insights: insights, facts: facts).map(\.id))
        let ranked = assets
            .compactMap { record in
                score(record, insight: insights[record.id], facts: facts[record.id], extra: extras.contains(record.id), now: now).map { (record, $0) }
            }
            .sorted { $0.1 == $1.1 ? ($0.0.displayBytes, $1.0.id) > ($1.0.displayBytes, $0.0.id) : $0.1 > $1.1 }
        let goal = gigabytes * 1_000_000_000
        var chosen: [AssetRecord] = []
        var bytes: Int64 = 0
        for (record, _) in ranked where bytes < goal {
            chosen.append(record)
            bytes += record.displayBytes
        }
        guard !chosen.isEmpty else { return nil }
        let videos = chosen.filter { $0.mediaType == PHAssetMediaType.video.rawValue }.count
        let same = chosen.filter { extras.contains($0.id) }.count
        var parts: [String] = []
        if videos > 0 { parts.append("\(videos.formatted()) \(videos == 1 ? "video" : "videos")") }
        if same > 0 { parts.append("\(same.formatted()) same-shot \(same == 1 ? "extra" : "extras")") }
        let rest = chosen.count - videos - same
        if rest > 0 { parts.append("\(rest.formatted()) \(rest == 1 ? "photo" : "photos")") }
        return SmartGroup(id: "pick-\(gigabytes)", kind: .pick, title: "Your pick: \(bytes.fileSize)",
                          reason: "Big, old or nearly identical. No favorites, nothing recent",
                          records: chosen, notYet: 0, when: parts.joined(separator: ", "))
    }
}

private extension Array {
    func appending(_ element: Element?) -> [Element] {
        guard let element else { return self }
        return self + [element]
    }
}
