import Foundation

/// One reading of free space. Sizes and dates only, kept on this iPhone.
struct FreeSpacePoint: Codable, Equatable {
    let date: Date
    let freeBytes: Int64
}

/// Free space over time, noted at each check-in and each time the Storage Checkup measures.
/// At most one point a day, and a few months of them.
enum FreeSpaceTrend {
    static let key = "freeSpaceTrend"
    static let limit = 90

    static func points(store: UserDefaults = .standard) -> [FreeSpacePoint] {
        guard let data = store.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([FreeSpacePoint].self, from: data)) ?? []
    }

    /// Adds a reading. A second reading on the same day replaces the first.
    static func record(_ freeBytes: Int64, at date: Date = .now, store: UserDefaults = .standard,
                       calendar: Calendar = .current) {
        guard freeBytes >= 0 else { return }
        var all = points(store: store)
        if let last = all.last, calendar.isDate(last.date, inSameDayAs: date) { all.removeLast() }
        all.append(FreeSpacePoint(date: date, freeBytes: freeBytes))
        all = Array(all.sorted { $0.date < $1.date }.suffix(limit))
        if let data = try? JSONEncoder().encode(all) { store.set(data, forKey: key) }
    }

    /// Notes the iPhone's free space right now.
    static func recordNow() {
        if let free = DeviceStorage.current()?.available { record(free) }
    }

    /// Heights for a sparkline, 0 to 1, lowest reading at 0. A flat line sits in the middle.
    static func heights(_ points: [FreeSpacePoint]) -> [Double] {
        guard let low = points.map(\.freeBytes).min(), let high = points.map(\.freeBytes).max() else { return [] }
        guard high > low else { return points.map { _ in 0.5 } }
        return points.map { Double($0.freeBytes - low) / Double(high - low) }
    }

    /// "Up 2.1 GB since Nov 3", "Down 800 MB since Nov 3", or nil with fewer than two readings.
    static func summary(_ points: [FreeSpacePoint]) -> String? {
        guard points.count > 1, let first = points.first, let last = points.last else { return nil }
        let change = last.freeBytes - first.freeBytes
        let since = first.date.formatted(date: .abbreviated, time: .omitted)
        if abs(change) < 20_000_000 { return "About the same since \(since)" }
        return "\(change > 0 ? "Up" : "Down") \(abs(change).fileSize) since \(since)"
    }
}
