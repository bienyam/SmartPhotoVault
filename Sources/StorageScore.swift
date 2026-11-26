import Foundation

/// The Storage Score: one number from free space alone. Score = free ÷ total × 4, capped at 100,
/// so a quarter of the iPhone free (or more) scores 100. It says nothing about speed or health.
struct StorageScore: Equatable {
    /// Five bands, each 5% of the iPhone's capacity wide.
    enum Band: String, CaseIterable, Identifiable {
        case a = "A", b = "B", c = "C", d = "D", e = "E"

        var id: String { rawValue }

        var name: String {
            switch self {
            case .a: "Healthy"
            case .b: "Comfortable"
            case .c: "Getting full"
            case .d: "Tight"
            case .e: "Nearly full"
            }
        }

        var scores: ClosedRange<Int> {
            switch self {
            case .a: 80...100
            case .b: 60...79
            case .c: 40...59
            case .d: 20...39
            case .e: 0...19
            }
        }

        /// The same band in words about free space.
        var freeSpace: String {
            switch self {
            case .a: "20% free or more"
            case .b: "15% to under 20%"
            case .c: "10% to under 15%"
            case .d: "5% to under 10%"
            case .e: "under 5%"
            }
        }

        /// One plain sentence on what this much free space means day to day.
        var advice: String {
            switch self {
            case .a: "Plenty of room for photos, videos and updates."
            case .b: "Enough room for everyday use."
            case .c: "A big iOS update could run short."
            case .d: "Long videos and iOS updates may not fit."
            case .e: "There may be no room for new photos or an iOS update."
            }
        }

        static func of(score: Int) -> Band {
            allCases.first { $0.scores.contains(score) } ?? (score > 100 ? .a : .e)
        }
    }

    let value: Int
    /// Free space as a share of the whole iPhone, 0 to 1.
    let freeFraction: Double

    var band: Band { Band.of(score: value) }

    init(free: Int64, total: Int64) {
        freeFraction = Self.fraction(free: free, total: total)
        value = Self.value(free: free, total: total)
    }

    static func fraction(free: Int64, total: Int64) -> Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(free) / Double(total)))
    }

    /// Rounded down, so "under 20% free" never shows as an A.
    static func value(free: Int64, total: Int64) -> Int {
        guard total > 0 else { return 0 }
        // Whole-number maths, so an exact 20% free is never a hair under 80.
        let counted = min(max(0, free), total)
        return Int(min(100, counted * 400 / total))
    }

    /// "12.5%" or "20%": one decimal place only when it adds something.
    var freePercent: String {
        let percent = (freeFraction * 1000).rounded() / 10
        return percent == percent.rounded() ? "\(Int(percent))%" : String(format: "%.1f%%", percent)
    }
}

/// The storage bar's three parts. Photos and free space are measured; the middle is what is left.
struct StorageSplit: Equatable {
    let photos: Int64
    let rest: Int64
    let free: Int64
    let total: Int64

    /// `photos` is nil until a check has measured the library.
    init(storage: DeviceStorage, photos measured: Int64?) {
        total = storage.total
        free = min(max(0, storage.available), storage.total)
        let used = max(0, storage.total - free)
        photos = min(max(0, measured ?? 0), used)
        rest = max(0, used - photos)
    }

    func fraction(_ bytes: Int64) -> Double { total > 0 ? Double(bytes) / Double(total) : 0 }
}
