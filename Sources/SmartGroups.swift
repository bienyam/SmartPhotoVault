import Foundation
import Photos
import UniformTypeIdentifiers

/// A ready-made set of photos and videos to archive in one go, with a reason people can check.
struct SmartGroup: Identifiable {
    enum Kind: String { case event, trip, largeVideos, oldVideos, album }

    let id: String
    let kind: Kind
    let title: String
    let reason: String
    /// What can be archived now, in the order to look through it.
    let records: [AssetRecord]
    /// Items that belong here but can't be archived yet (Live Photos, edits, other formats).
    let notYet: Int

    var bytes: Int64 { records.reduce(0) { $0 + $1.displayBytes } }
    var total: Int { records.count + notYet }
}

/// Finds groups from the last scan, on this iPhone only: times, sizes and the rough location already
/// saved with the scan. No calendar, no place names, nothing sent anywhere.
enum SmartGrouper {
    static let eventMinimum = 20
    static let largeVideo: Int64 = 500_000_000
    static let bigVideo: Int64 = 100_000_000

    /// Largest first: trips and events, then very large videos and old videos.
    static func groups(in snapshot: ScanSnapshot, now: Date = .now, calendar: Calendar = .current) -> [SmartGroup] {
        let segments = Self.segments(in: snapshot.assets)
        let trips = Self.trips(from: segments, calendar: calendar)
        let inTrips = Set(trips.flatMap(\.segmentIDs))
        let tripGroups = trips.compactMap { tripGroup($0, calendar: calendar) }
        let eventGroups = segments.enumerated()
            .filter { !inTrips.contains($0.offset) && $0.element.count >= eventMinimum }
            .compactMap { eventGroup($0.element, calendar: calendar) }
        var result = (tripGroups + eventGroups).sorted { $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes }
        let large = largeVideos(in: snapshot.assets)
        if let large { result.append(large) }
        if let old = oldVideos(in: snapshot.assets, except: Set(large?.records.map(\.id) ?? []), now: now, calendar: calendar) {
            result.append(old)
        }
        return result
    }

    /// True when the app can archive this item today as one verified original file.
    static func canArchive(_ record: AssetRecord) -> Bool {
        let subtypes = PHAssetMediaSubtype(rawValue: record.subtypes ?? 0)
        guard !subtypes.contains(.photoLive), !subtypes.contains(.videoHighFrameRate),
              let type = UTType(filenameExtension: (record.filename as NSString).pathExtension) else { return false }
        let image = record.mediaType == PHAssetMediaType.image.rawValue
        let video = record.mediaType == PHAssetMediaType.video.rawValue
        guard image ? (type.conforms(to: .jpeg) || type.conforms(to: .heic)) : (video && type.conforms(to: .movie)) else {
            return false
        }
        if record.inICloud { return true }
        let resource = image ? PHAssetResourceType.photo.rawValue : PHAssetResourceType.video.rawValue
        return record.issue == nil && record.resources.count == 1 && record.resources.first?.type == resource
    }

    /// Everything in one of the person's own albums, oldest first.
    static func album(_ album: AlbumInfo, in snapshot: ScanSnapshot) -> SmartGroup {
        let all = snapshot.assets
            .filter { $0.albumIDs?.contains(album.id) == true }
            .sorted { ($0.createdAt ?? .distantPast, $0.id) < ($1.createdAt ?? .distantPast, $1.id) }
        let ready = all.filter(canArchive)
        return SmartGroup(id: "album-\(album.id)", kind: .album, title: album.title, reason: "Everything in this album",
                          records: ready, notYet: all.count - ready.count)
    }

    // MARK: - Events

    /// Photos and videos in time order, split where there is an unusually long pause.
    static func segments(in assets: [AssetRecord]) -> [[AssetRecord]] {
        let items = assets
            .filter { $0.createdAt != nil && $0.isScreenshot != true
                && ($0.mediaType == PHAssetMediaType.image.rawValue || $0.mediaType == PHAssetMediaType.video.rawValue) }
            .sorted { $0.createdAt! == $1.createdAt! ? $0.id < $1.id : $0.createdAt! < $1.createdAt! }
        guard items.count > 1 else { return items.isEmpty ? [] : [items] }
        let gaps = zip(items, items.dropFirst()).map { max(1, $1.createdAt!.timeIntervalSince($0.createdAt!)) }
        let logs = gaps.map { log($0) }
        var sums = [0.0]
        for value in logs { sums.append(sums.last! + value) }
        var result: [[AssetRecord]] = []
        var current = [items[0]]
        for index in gaps.indices {
            let low = max(0, index - 10), high = min(logs.count, index + 11)
            let average = (sums[high] - sums[low]) / Double(high - low)
            let pause = gaps[index] >= 45 * 60
            // A pause far longer than its neighbours (Graham et al. 2002), a night's sleep, or a jump in place.
            let unusual = pause && logs[index] >= log(17) + average
            let moved = pause && (distance(items[index], items[index + 1]) ?? 0) >= 30
            if unusual || moved || gaps[index] >= 6 * 3600 {
                result.append(current)
                current = []
            }
            current.append(items[index + 1])
        }
        result.append(current)
        return result
    }

    private static func eventGroup(_ items: [AssetRecord], calendar: Calendar) -> SmartGroup? {
        let ready = items.filter(canArchive)
        guard !ready.isEmpty, let first = items.first?.createdAt, let last = items.last?.createdAt else { return nil }
        let place = spread(items).map { $0 < 5 ? ", same area" : "" } ?? ""
        return SmartGroup(id: "event-\(Int(first.timeIntervalSince1970))", kind: .event, title: dayTitle(first, calendar),
                          reason: "Taken \(time(first, calendar)) to \(time(last, calendar))\(place)",
                          records: ready, notYet: items.count - ready.count)
    }

    // MARK: - Trips

    struct Trip {
        var segmentIDs: [Int]
        var items: [AssetRecord]
    }

    /// Events close together in time that are all far from where most photos are taken.
    static func trips(from segments: [[AssetRecord]], calendar: Calendar) -> [Trip] {
        guard let home = Self.home(of: segments.flatMap { $0 }) else { return [] }
        var result: [Trip] = []
        var current: Trip?
        func close() {
            if let trip = current, trip.items.count >= eventMinimum, days(trip.items, calendar) >= 2 { result.append(trip) }
            current = nil
        }
        for (index, segment) in segments.enumerated() {
            guard let center = Self.center(of: segment) else { continue }
            guard kilometers(center, home) >= 80 else {
                close()
                continue
            }
            if let last = current?.items.last?.createdAt, let start = segment.first?.createdAt,
               start.timeIntervalSince(last) > 36 * 3600 { close() }
            if current == nil { current = Trip(segmentIDs: [], items: []) }
            current?.segmentIDs.append(index)
            current?.items.append(contentsOf: segment)
        }
        close()
        return result
    }

    private static func tripGroup(_ trip: Trip, calendar: Calendar) -> SmartGroup? {
        let ready = trip.items.filter(canArchive)
        guard !ready.isEmpty, let first = trip.items.first?.createdAt, let last = trip.items.last?.createdAt else { return nil }
        return SmartGroup(id: "trip-\(Int(first.timeIntervalSince1970))", kind: .trip,
                          title: "Trip, \(shortDay(first, calendar)) to \(shortDay(last, calendar))",
                          reason: "\(days(trip.items, calendar)) days, away from where you take most photos",
                          records: ready, notYet: trip.items.count - ready.count)
    }

    // MARK: - Videos

    private static func largeVideos(in assets: [AssetRecord]) -> SmartGroup? {
        let videos = assets
            .filter { $0.mediaType == PHAssetMediaType.video.rawValue && !$0.favorite && canArchive($0) }
            .sorted { $0.displayBytes == $1.displayBytes ? $0.id < $1.id : $0.displayBytes > $1.displayBytes }
        let huge = videos.filter { $0.displayBytes >= largeVideo }
        let chosen = huge.count >= 5 ? huge : Array(videos.filter { $0.displayBytes >= bigVideo }.prefix(10))
        guard !chosen.isEmpty else { return nil }
        return SmartGroup(id: "large-videos", kind: .largeVideos, title: "Very large videos",
                          reason: huge.count >= 5 ? "Each is 500 MB or more" : "Your largest, each 100 MB or more",
                          records: chosen, notYet: 0)
    }

    private static func oldVideos(in assets: [AssetRecord], except: Set<String>, now: Date, calendar: Calendar) -> SmartGroup? {
        guard let cutoff = calendar.date(byAdding: .year, value: -2, to: now) else { return nil }
        let chosen = assets
            .filter { record in
                record.mediaType == PHAssetMediaType.video.rawValue && !record.favorite && !except.contains(record.id)
                    && record.displayBytes >= bigVideo && (record.albumIDs ?? []).isEmpty
                    && (record.createdAt.map { $0 < cutoff } ?? false) && canArchive(record)
            }
            .sorted { $0.createdAt! == $1.createdAt! ? $0.id < $1.id : $0.createdAt! < $1.createdAt! }
        guard !chosen.isEmpty else { return nil }
        return SmartGroup(id: "old-videos", kind: .oldVideos, title: "Old videos",
                          reason: "Over 2 years old, 100 MB or more, not a favorite, in no album",
                          records: chosen, notYet: 0)
    }

    // MARK: - Places and dates

    private typealias Point = (latitude: Double, longitude: Double)

    private static func point(_ record: AssetRecord) -> Point? {
        guard let latitude = record.latitude, let longitude = record.longitude else { return nil }
        return (latitude, longitude)
    }

    private static func distance(_ a: AssetRecord, _ b: AssetRecord) -> Double? {
        guard let from = point(a), let to = point(b) else { return nil }
        return kilometers(from, to)
    }

    private static func kilometers(_ a: Point, _ b: Point) -> Double {
        let radians = Double.pi / 180
        let dLat = (b.latitude - a.latitude) * radians, dLon = (b.longitude - a.longitude) * radians
        let h = pow(sin(dLat / 2), 2) + cos(a.latitude * radians) * cos(b.latitude * radians) * pow(sin(dLon / 2), 2)
        return 2 * 6371 * asin(min(1, sqrt(h)))
    }

    private static func center(of items: [AssetRecord]) -> Point? {
        let points = items.compactMap(point)
        guard !points.isEmpty else { return nil }
        // The middle value, so one wrong location can't move the center.
        return (points.map(\.latitude).sorted()[points.count / 2], points.map(\.longitude).sorted()[points.count / 2])
    }

    /// How far the items are from their center, in km, or nil when none has a location.
    private static func spread(_ items: [AssetRecord]) -> Double? {
        guard let middle = center(of: items) else { return nil }
        return items.compactMap(point).map { kilometers($0, middle) }.max()
    }

    /// Where most photos are taken: the busiest area of roughly 10 km. Needs enough located items to mean anything.
    private static func home(of items: [AssetRecord]) -> Point? {
        var areas: [String: [AssetRecord]] = [:]
        for item in items {
            guard let place = point(item) else { continue }
            areas["\(Int((place.latitude * 10).rounded())),\(Int((place.longitude * 10).rounded()))", default: []].append(item)
        }
        guard let busiest = areas.max(by: { $0.value.count == $1.value.count ? $0.key > $1.key : $0.value.count < $1.value.count }),
              busiest.value.count >= eventMinimum else { return nil }
        return center(of: busiest.value)
    }

    private static func days(_ items: [AssetRecord], _ calendar: Calendar) -> Int {
        Set(items.compactMap { $0.createdAt.map(calendar.startOfDay) }).count
    }

    private static func format(_ date: Date, _ calendar: Calendar, _ template: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? .current
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    private static func dayTitle(_ date: Date, _ calendar: Calendar) -> String { format(date, calendar, "EEEEMMMMdyyyy") }
    private static func shortDay(_ date: Date, _ calendar: Calendar) -> String { format(date, calendar, "MMMdyyyy") }
    private static func time(_ date: Date, _ calendar: Calendar) -> String { format(date, calendar, "jmm") }
}
