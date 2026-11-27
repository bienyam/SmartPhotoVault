import XCTest
import Photos
@testable import SmartPhotoVault

/// 1.0.2: the delete sign-off must be on record, the saved scan loads off the main thread,
/// cleanup lists work out their selection once, and a rejected Google sign-in is forgotten.
final class Release102PerfTests: XCTestCase {
    private func photo(_ id: String, digest: String? = nil, bytes: Int64 = 100, favorite: Bool = false,
                       filename: String? = nil) -> AssetRecord {
        AssetRecord(id: id, filename: filename ?? id, mediaType: PHAssetMediaType.image.rawValue, favorite: favorite,
                    createdAt: nil,
                    resources: [ResourceFingerprint(type: PHAssetResourceType.photo.rawValue, digest: digest ?? id, bytes: bytes)],
                    issue: nil)
    }

    private func snapshot(_ assets: [AssetRecord]) -> ScanSnapshot {
        ScanSnapshot(date: Date(timeIntervalSince1970: 1_800_000_000), limitedAccess: false, includedCloudDownloads: false,
                     assets: assets, albums: [])
    }

    private func temporaryStore() throws -> (InventoryStore, URL) {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        return (try InventoryStore(url: path), path)
    }

    // MARK: A5, the sign-off is logged before anything is deleted

    func testApprovalCountsOnlyWhenItWasWritten() {
        struct Full: Error {}
        var written: [String] = []
        XCTAssertTrue(DashboardModel.recordApproval("Authorized deleting 2 item(s).") { written.append($0) })
        XCTAssertEqual(written, ["Authorized deleting 2 item(s)."])
        XCTAssertFalse(DashboardModel.recordApproval("Authorized deleting 2 item(s).") { _ in throw Full() },
                       "A log that can't be written, such as on a full disk, must stop the delete.")
        XCTAssertFalse(DashboardModel.recordApproval("Authorized deleting 2 item(s).", nil),
                       "No open log means no record, so nothing may be deleted.")
    }

    @MainActor
    func testDeletesAreBlockedWhenTheSignOffCantBeRecorded() async throws {
        let model = DashboardModel(opening: { nil })
        let blocked = DuplicateRemovalOutcome.blocked("The app could not save your authorization. Try again.")
        XCTAssertEqual(DashboardModel.approvalNotSaved, "The app could not save your authorization. Try again.")
        let itemsOutcome = await model.removeItems(["one", "two"], bytes: 200, from: "Screenshots")
        XCTAssertEqual(itemsOutcome, blocked)
        let group = DuplicateGroup(id: "same", assets: [photo("keep", digest: "same"), photo("extra", digest: "same")])
        let plan = try XCTUnwrap(DuplicateRemovalPlan(group: group))
        let duplicatesOutcome = await model.removeDuplicates([plan])
        XCTAssertEqual(duplicatesOutcome, blocked)
    }

    // MARK: D1, the saved scan

    func testSavedScanRoundTripsWithItsTextIntact() throws {
        let (store, path) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: path) }
        XCTAssertNil(try store.load())
        let first = snapshot([photo("a", filename: "Café ☕️ 1.heic"), photo("b", digest: "a")])
        let second = snapshot([photo("c", filename: "Ünïcödé 📷.jpg")])
        try store.save(first)
        try store.save(second)
        let loaded = try XCTUnwrap(try InventoryStore(url: path).load())
        XCTAssertEqual(loaded.assets.map(\.id), ["c"], "The later save wins.")
        XCTAssertEqual(loaded.assets.first?.filename, "Ünïcödé 📷.jpg")
        XCTAssertEqual(try store.activity().first?.message, "Scan saved: 1 assets, 1 fully hashed, 0 duplicate groups.")
    }

    func testDuplicateGroupCountMatchesTheGroups() {
        let assets = [photo("a", digest: "x"), photo("b", digest: "x"), photo("c", digest: "x"),
                      photo("d", digest: "y"), photo("e", digest: "y"), photo("f", digest: "z"),
                      AssetRecord(id: "g", filename: "g", mediaType: PHAssetMediaType.image.rawValue, favorite: false,
                                  createdAt: nil, resources: [], issue: "unreadable")]
        let scan = snapshot(assets)
        XCTAssertEqual(scan.duplicateGroupCount, scan.groups.count)
        XCTAssertEqual(scan.duplicateGroupCount, 2)
        XCTAssertEqual(snapshot([]).duplicateGroupCount, 0)
    }

    @MainActor
    func testSavedScanLoadsAfterLaunchAndFillsTheRows() async throws {
        let (store, path) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: path) }
        try store.save(snapshot([photo("keep", digest: "same"), photo("extra", digest: "same"), photo("other")]))
        let model = DashboardModel(opening: { store })
        guard model.authorization == .authorized || model.authorization == .limited else {
            throw XCTSkip("Saved results load only with Photos access; CI grants it through the consent UI first.")
        }
        XCTAssertTrue(model.isLoadingSaved, "The read happens after the first frame, not in init.")
        XCTAssertNil(model.snapshot)
        XCTAssertEqual(model.freeUpStart, .loadingSaved, "Never the empty Free up space state while saved results load.")
        await model.savedLoad?.value
        XCTAssertFalse(model.isLoadingSaved)
        XCTAssertEqual(model.freeUpStart, .results)
        XCTAssertEqual(model.snapshot?.assets.count, 3)
        XCTAssertEqual(model.rescue?.duplicateGroups.count, 1, "The Free up rows arrive with the results.")
        XCTAssertEqual(model.rescue?.duplicateCopies, 1)
    }

    @MainActor
    func testALateLaunchReadNeverReplacesNewerResults() async throws {
        let (store, path) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: path) }
        try store.save(snapshot([photo("saved")]))
        let model = DashboardModel(opening: { store })
        guard model.authorization == .authorized || model.authorization == .limited else {
            throw XCTSkip("Saved results load only with Photos access; CI grants it through the consent UI first.")
        }
        model.showDemo()
        let demoCount = DemoLibrary.snapshot.assets.count
        XCTAssertNotEqual(demoCount, 1)
        await model.savedLoad?.value
        XCTAssertTrue(model.isDemo)
        XCTAssertEqual(model.snapshot?.assets.count, demoCount, "Results shown after launch must not be overwritten by the older saved scan.")
        XCTAssertEqual(model.rescue?.snapshot.assets.count, demoCount)
    }

    func testTheEmptyStateIsNeverChosenWhileSavedResultsLoad() {
        XCTAssertEqual(DashboardModel.freeUpStart(scanning: false, loadingSaved: true, hasResults: false), .loadingSaved)
        XCTAssertEqual(DashboardModel.freeUpStart(scanning: false, loadingSaved: false, hasResults: false), .empty)
        XCTAssertEqual(DashboardModel.freeUpStart(scanning: false, loadingSaved: true, hasResults: true), .results)
        XCTAssertEqual(DashboardModel.freeUpStart(scanning: false, loadingSaved: false, hasResults: true), .results)
        XCTAssertEqual(DashboardModel.freeUpStart(scanning: true, loadingSaved: true, hasResults: false), .scanning)
        XCTAssertEqual(DashboardModel.freeUpStart(scanning: true, loadingSaved: false, hasResults: true), .scanning)
    }

    @MainActor
    func testWithNothingSavedTheEmptyStateShowsOnceTheReadFinishes() async throws {
        let (store, path) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: path) }
        let model = DashboardModel(opening: { store })
        guard model.authorization == .authorized || model.authorization == .limited else {
            throw XCTSkip("Saved results load only with Photos access; CI grants it through the consent UI first.")
        }
        XCTAssertEqual(model.freeUpStart, .loadingSaved)
        await model.savedLoad?.value
        XCTAssertEqual(model.freeUpStart, .empty)
    }

    // MARK: D2, cleanup list selection

    func testCleanupSelectionNeverOffersTheKeptPhotoOrFavorites() {
        let keep = photo("keep", bytes: 10)
        let extra = photo("extra", bytes: 20)
        let favorite = photo("fav", bytes: 40, favorite: true)
        let loose = photo("loose", bytes: 80)
        let sets = [KeepSet(keep: keep, extras: [extra], because: "the sharpest")]
        let selection = CleanupSelection(items: [keep, extra, favorite, loose], sets: sets)

        XCTAssertEqual(selection.selectable.map(\.id), ["extra", "loose"])
        XCTAssertEqual(selection.selectableIDs, ["extra", "loose"], "Select all never includes the kept photo or a favorite.")
        XCTAssertEqual(selection.kept, ["keep"])
        XCTAssertEqual(selection.rest.map(\.id), ["keep", "fav", "loose"])
        XCTAssertEqual(selection.previewItems.map(\.id), ["keep", "extra", "keep", "fav", "loose"])
        XCTAssertEqual(selection.keptNotes, ["keep": "Keeping this one: the sharpest"])

        let picked: Set<String> = ["extra", "fav", "keep", "gone"]
        XCTAssertEqual(selection.count(of: picked), 1)
        XCTAssertEqual(selection.bytes(of: picked), 20)
        XCTAssertEqual(selection.records(picked).map(\.id), ["extra"])
        XCTAssertFalse(selection.allSelected(picked))
        XCTAssertTrue(selection.allSelected(selection.selectableIDs))
        XCTAssertEqual(selection.bytes(of: selection.selectableIDs), 100)
        XCTAssertFalse(selection.allSelected([]))
    }

    func testCleanupSelectionWithoutSetsPreviewsTheListAsShown() {
        let items = [photo("b", bytes: 5), photo("a", bytes: 7, favorite: true)]
        let selection = CleanupSelection(items: items, sets: [])
        XCTAssertEqual(selection.previewItems.map(\.id), ["b", "a"])
        XCTAssertEqual(selection.selectable.map(\.id), ["b"])
        XCTAssertTrue(CleanupSelection(items: [], sets: []).selectable.isEmpty)
        XCTAssertFalse(CleanupSelection(items: [], sets: []).allSelected([]))
    }

    func testCleanupSelectionIsWorkedOutOncePerList() {
        let cache = CleanupSelectionCache()
        let items = [photo("a"), photo("b")]
        _ = cache.selection(items: items, sets: [])
        _ = cache.selection(items: items, sets: [])
        XCTAssertEqual(cache.builds, 1, "Ticking a box redraws the list with the same items.")
        var changed = items
        changed.append(photo("c"))
        XCTAssertEqual(cache.selection(items: changed, sets: []).selectable.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(cache.builds, 2)
        var favorited = changed
        favorited[0] = photo("a", favorite: true)
        XCTAssertEqual(cache.selection(items: favorited, sets: []).selectable.map(\.id), ["b", "c"],
                       "New items with the same ids are worked out again, so a new favorite can't be selected.")
    }

    // MARK: D10, a rejected Google sign-in

    func testOnlyARevokedOrExpiredGoogleSignInIsForgotten() {
        let rejected = Data(#"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#.utf8)
        XCTAssertTrue(GoogleTokenService.isRejectedSignIn(status: 400, body: rejected))
        XCTAssertFalse(GoogleTokenService.isRejectedSignIn(status: 500, body: rejected), "A server problem may pass.")
        XCTAssertFalse(GoogleTokenService.isRejectedSignIn(status: 400, body: Data(#"{"error":"invalid_request"}"#.utf8)))
        XCTAssertFalse(GoogleTokenService.isRejectedSignIn(status: 400, body: Data("<html>".utf8)))
    }

    func testOneDriveAndDropboxRejectedSignInsAreRecognised() {
        let microsoft = Data(#"{"error":"invalid_grant","error_description":"AADSTS70008: The refresh token has expired.","error_codes":[70008]}"#.utf8)
        let dropbox = Data(#"{"error": "invalid_grant", "error_description": "refresh token is invalid or revoked"}"#.utf8)
        XCTAssertTrue(GoogleTokenService.isRejectedSignIn(status: 400, body: microsoft))
        XCTAssertTrue(GoogleTokenService.isRejectedSignIn(status: 400, body: dropbox))
        XCTAssertFalse(GoogleTokenService.isRejectedSignIn(status: 503, body: microsoft))
        XCTAssertFalse(GoogleTokenService.isRejectedSignIn(status: 400, body: Data(#"{"error":"invalid_client"}"#.utf8)))
    }

    @MainActor
    func testArchiveRunSaysGoogleDriveNeedsSigningInAgain() {
        XCTAssertEqual(ArchiveRun.reason(for: GoogleDriveError.notConnected), "Google Drive needs you to sign in again")
        XCTAssertEqual(GoogleDriveError.notConnected.errorDescription, "Connect Google Drive first.")
        XCTAssertEqual(ArchiveRun.reason(for: CloudError.notConnected("OneDrive")), "OneDrive needs you to sign in again")
        XCTAssertEqual(ArchiveRun.reason(for: CloudError.notConnected("Dropbox")), "Dropbox needs you to sign in again")
        XCTAssertEqual(CloudError.notConnected("Dropbox").errorDescription, "Connect Dropbox first.")
    }
}
