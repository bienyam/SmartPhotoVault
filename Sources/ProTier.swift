import Foundation
import StoreKit

/// What TidyAway Pro adds in 1.0.1. Everything else is free: the by-type lists (duplicates, large
/// videos, screenshots and more types), the first 5 GB of archiving, every destination, verified
/// delete, Get back, Activity, preview, favorites protection and the Storage Checkup.
enum ProFeature: String, CaseIterable, Identifiable {
    /// Smart picks on Free up: look-alike, blurry, accidental, too dark, expired receipts,
    /// old screenshots, photos of screens, and the one-tap suggestion made from them.
    case smartPicks
    /// Already archived, Best shots and Screenshots, read.
    case smartPro
    /// Archive groups, album and place filters, suggested videos.
    case archiveGroups
    /// Archiving past the free 5 GB.
    case unlimitedArchive
    /// Daily or weekly check-ins, space alerts and reminders before big events.
    case extraCheckIns

    var id: String { rawValue }
}

/// The one rule for who can open what.
enum ProGate {
    /// Pro opens everything. People who started on 1.0 keep the smart picks on Free up for good.
    static func allows(_ feature: ProFeature, pro: Bool, grandfathered: Bool) -> Bool {
        if pro { return true }
        return feature == .smartPicks && grandfathered
    }

    /// The Free up lists that are never behind Pro.
    static let freeRows: Set<String> = ["row-duplicates", "row-videos", "row-screenshots", "row-more"]
}

/// People who installed TidyAway 1.0 keep the smart picks on Free up free forever.
/// Two signals: Apple's record of the first installed build, and 1.0 data already on this iPhone
/// the first time 1.0.1 opens. Once set, the flag is kept.
enum Grandfather {
    static let flagKey = "grandfather.smartPicks"
    static let checkedKey = "grandfather.checkedFirstLaunch"
    /// Every App Store build of 1.0 has a build number at or below this (the upload run number).
    /// Builds of 1.0.1 are numbered higher.
    static let lastVersionOneBuild = 194

    static func isSet(in store: UserDefaults = .standard) -> Bool { store.bool(forKey: flagKey) }

    /// True when Apple's record shows the app was first installed as 1.0.
    /// On iPhone the record holds the build number; in the test environment Apple always reports
    /// "1.0" whatever was installed, so it proves nothing there.
    static func startedOnVersionOne(originalAppVersion: String, production: Bool) -> Bool {
        guard production else { return false }
        let version = originalAppVersion.trimmingCharacters(in: .whitespaces)
        if version == "1.0" || version == "1.0.0" { return true }
        guard let build = version.split(separator: ".").first.flatMap({ Int($0) }) else { return false }
        return build <= lastVersionOneBuild
    }

    /// The backup signal, read once: the first time 1.0.1 opens, was there 1.0 data on this iPhone?
    /// Returns the flag after the check.
    @discardableResult
    static func noteFirstLaunch(hadEarlierData: Bool, store: UserDefaults = .standard) -> Bool {
        if !store.bool(forKey: checkedKey) {
            store.set(true, forKey: checkedKey)
            if hadEarlierData { store.set(true, forKey: flagKey) }
        }
        return isSet(in: store)
    }

    /// Apple's record can only ever add the flag, never take it away.
    @discardableResult
    static func note(originalAppVersion: String, production: Bool, store: UserDefaults = .standard) -> Bool {
        if startedOnVersionOne(originalAppVersion: originalAppVersion, production: production) {
            store.set(true, forKey: flagKey)
        }
        return isSet(in: store)
    }

    /// 1.0 left these behind: the welcome flag, or the local inventory and recognition files.
    static func hasEarlierData(store: UserDefaults = .standard, files: FileManager = .default) -> Bool {
        if store.object(forKey: "hasSeenWelcome") != nil { return true }
        guard let support = files.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return false }
        let folder = support.appendingPathComponent("SmartPhotoVault", isDirectory: true)
        return files.fileExists(atPath: folder.appendingPathComponent("inventory.sqlite").path)
            || files.fileExists(atPath: folder.appendingPathComponent("insights.jsonl").path)
    }

    /// Call before anything creates local data, so a fresh install is never mistaken for 1.0.
    static func checkAtLaunch() {
        guard !UserDefaults.standard.bool(forKey: checkedKey) else { return }
        noteFirstLaunch(hadEarlierData: hasEarlierData())
    }

    /// Asks Apple which build was installed first. Quietly does nothing when Apple can't be reached.
    static func checkAppStoreRecord() async -> Bool {
        if isSet() { return true }
        guard let record = try? await AppTransaction.shared, case .verified(let app) = record else { return isSet() }
        return note(originalAppVersion: app.originalAppVersion, production: app.environment == .production)
    }
}
