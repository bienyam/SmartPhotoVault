import XCTest

final class DashboardUITests: XCTestCase {
    // CI runs this once before the unit/integration suite to initialize PhotoKit's
    // authorization through the real consent UI, not only the simulator TCC preset.
    func testPrepareFullPhotoAccess() {
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .photos)
        app.launchArguments += ["--skip-welcome"]
        app.launch()
        let start = app.buttons["free-up-space"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertFalse(springboard.alerts.firstMatch.exists, "Opening the app must not request Photos access.")
        start.tap()
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: 10) else {
            XCTFail("Expected the Photos consent dialog after tapping Free up space.")
            return
        }
        let labels = ["Allow Full Access", "Allow Access to All Photos"]
        guard let allow = labels.map({ alert.buttons[$0] }).first(where: { $0.exists }) else {
            XCTFail("Full-access choice missing: \(alert.debugDescription)")
            return
        }
        allow.tap()
        XCTAssertTrue(app.buttons["check-again"].waitForExistence(timeout: 90), "The check should finish.")
        XCTAssertTrue(app.buttons["row-duplicates"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Authorized Free up results"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
    }

    func testAuthorizedLibraryScanReviewsRealResources() {
        let app = XCUIApplication()
        app.launchArguments += ["--skip-welcome"]
        app.launch()
        let again = app.buttons["check-again"]
        let start = app.buttons["free-up-space"]
        XCTAssertTrue(again.waitForExistence(timeout: 15) || start.exists)
        if again.exists { again.tap() } else { start.tap() }
        XCTAssertTrue(app.buttons["check-again"].waitForExistence(timeout: 90), "The check should finish.")
        let duplicates = app.buttons["row-duplicates"]
        guard duplicates.waitForExistence(timeout: 5) else {
            XCTFail("Real Photos scan did not produce results: \(app.debugDescription)")
            return
        }
        reveal(duplicates, in: app)
        duplicates.tap()
        XCTAssertTrue(app.navigationBars["Duplicates"].waitForExistence(timeout: 10))
        let fixture = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "SPV-test-")).firstMatch
        XCTAssertTrue(fixture.waitForExistence(timeout: 5), "Expected actual simulator-library fixture files in review.")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Real Photos duplicate scan"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
    }

    func testDeniedPhotosAccessShowsSettings() {
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .photos)
        app.launchArguments += ["--skip-welcome"]
        app.launch()
        let start = app.buttons["free-up-space"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        start.tap()
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "Photo access should be requested only after Free up space is tapped.")
        let curlyApostrophe = alert.buttons["Don’t Allow"]
        let straightApostrophe = alert.buttons["Don't Allow"]
        if curlyApostrophe.exists { curlyApostrophe.tap() }
        else if straightApostrophe.exists { straightApostrophe.tap() }
        else { XCTFail("Expected a deny-access button: \(alert.debugDescription)"); return }
        XCTAssertTrue(app.buttons["Open Settings"].waitForExistence(timeout: 10))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Denied photo permission"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
    }

    func testFreeUpLeadsWithOneAction() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Storage full? Get your camera back."].exists || app.staticTexts["hero-bytes"].exists)
        XCTAssertTrue(app.buttons["free-up-space"].exists || app.buttons["check-again"].exists,
                      "One action leads: start a check, or check again after a saved one.")
        XCTAssertEqual(app.tabBars.buttons.count, 3)
    }

    func testSampleDuplicateReview() {
        let app = launchWithSamples()
        reveal(app.buttons["row-duplicates"], in: app)
        app.buttons["row-duplicates"].tap()
        XCTAssertTrue(app.navigationBars["Duplicates"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["kept-sample-1"].exists, "The copy to keep is listed, not selectable.")
        XCTAssertTrue(app.staticTexts["Keeping this one"].exists)
        XCTAssertTrue(app.buttons["select-sample-2"].exists)
        XCTAssertFalse(app.buttons["select-sample-4"].exists, "A Live Photo with different motion is not a duplicate.")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Sample duplicate review"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testDuplicateRemovalNeedsSelectionAndSignOff() {
        let app = launchWithSamples()
        reveal(app.buttons["row-duplicates"], in: app)
        app.buttons["row-duplicates"].tap()
        XCTAssertTrue(app.navigationBars["Duplicates"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["delete-selected"].exists, "Nothing is selected for you.")
        app.buttons["select-all"].tap()
        let delete = app.buttons["delete-selected"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        XCTAssertFalse(delete.isEnabled, "Removal stays off until the user signs off.")
        app.buttons["signoff"].tap()
        XCTAssertTrue(delete.isEnabled)
        delete.tap()
        XCTAssertTrue(app.staticTexts["Sample data. Nothing was removed."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["backup-title"].exists, "Duplicates skip the backup check: the kept copy stays.")
        XCTAssertFalse(delete.isEnabled, "Each removal needs a fresh sign-off.")
    }

    func testCategoryRemovalNeedsSelectionAndSignOff() {
        let app = launchWithSamples()
        reveal(app.buttons["row-screenshots"], in: app)
        app.buttons["row-screenshots"].tap()
        XCTAssertTrue(app.navigationBars["Screenshots"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["delete-selected"].exists, "Nothing is selected for you.")
        XCTAssertFalse(app.descendants(matching: .any)["kept-sample-1"].exists || app.buttons["select-sample-1"].exists, "Only screenshots are listed.")
        let pick = app.buttons["select-sample-6"]
        XCTAssertTrue(pick.waitForExistence(timeout: 5))
        pick.tap()
        let delete = app.buttons["delete-selected"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        XCTAssertFalse(delete.isEnabled, "Delete stays off until the sign-off is checked.")
        app.buttons["signoff"].tap()
        XCTAssertTrue(delete.isEnabled)
        delete.tap()
        // The screenshot has no archive copy, so TidyAway asks once more before Apple does.
        let anyway = app.buttons["backup-delete-anyway"]
        XCTAssertTrue(anyway.waitForExistence(timeout: 5))
        anyway.tap()
        XCTAssertTrue(app.staticTexts["Sample data. Nothing was removed."].waitForExistence(timeout: 5))
    }

    // MARK: - 1.0.1 round 2: the "not backed up" check

    func testDeletingItemsThatAreNotBackedUpAsksFirstAndDeleteAnywayGoesOn() {
        let app = launchWithSamples()
        let videos = app.buttons["row-videos"]
        reveal(videos, in: app)
        videos.tap()
        XCTAssertTrue(app.navigationBars["Large videos"].waitForExistence(timeout: 5))
        app.buttons["select-all"].tap()
        let delete = app.buttons["delete-selected"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["backup-title"].exists, "The alert comes only after the sign-off and Delete.")
        app.buttons["signoff"].tap()
        delete.tap()
        let title = app.staticTexts["backup-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "Some selected videos have no verified archive copy.")
        XCTAssertEqual(title.label, "2 of these aren't backed up")
        XCTAssertTrue(app.descendants(matching: .any)["backup-have"].firstMatch.label.contains("0 backed up"))
        XCTAssertTrue(app.descendants(matching: .any)["backup-missing"].firstMatch.label.contains("2 not backed up"))
        XCTAssertTrue(app.buttons["backup-copy-first"].exists)
        XCTAssertFalse(app.staticTexts["Sample data. Nothing was removed."].exists, "Nothing has been handed to Photos yet.")
        keepScreenshot(of: app, named: "Backup alert")
        app.buttons["backup-delete-anyway"].tap()
        XCTAssertTrue(app.staticTexts["Sample data. Nothing was removed."].waitForExistence(timeout: 5),
                      "Delete anyway goes on to the delete itself.")
        XCTAssertFalse(app.staticTexts["backup-title"].exists)
        // No "don't ask again": the same delete asks again.
        app.buttons["signoff"].tap()
        delete.tap()
        XCTAssertTrue(app.staticTexts["backup-title"].waitForExistence(timeout: 5), "It asks every time.")
    }

    func testCopyFirstSendsTheItemsToArchiveAndDeletesNothing() {
        let app = launchWithSamples()
        let videos = app.buttons["row-videos"]
        reveal(videos, in: app)
        videos.tap()
        XCTAssertTrue(app.navigationBars["Large videos"].waitForExistence(timeout: 5))
        app.buttons["select-sample-11"].tap()
        let delete = app.buttons["delete-selected"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        app.buttons["signoff"].tap()
        delete.tap()
        let copy = app.buttons["backup-copy-first"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["backup-title"].label, "This one isn't backed up")
        copy.tap()
        let summary = app.staticTexts["copy-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 10), "Copy first opens Archive on its copy screen.")
        XCTAssertTrue(summary.label.hasPrefix("1 item"), summary.label)
        XCTAssertFalse(app.staticTexts["Sample data. Nothing was removed."].exists, "Nothing was handed to Photos.")
        keepScreenshot(of: app, named: "Copy first in Archive")
    }

    func testTappingOutsideTheBackupAlertCancelsAndDeletesNothing() {
        let app = launchWithSamples()
        let videos = app.buttons["row-videos"]
        reveal(videos, in: app)
        videos.tap()
        XCTAssertTrue(app.navigationBars["Large videos"].waitForExistence(timeout: 5))
        app.buttons["select-all"].tap()
        let delete = app.buttons["delete-selected"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        app.buttons["signoff"].tap()
        delete.tap()
        let title = app.staticTexts["backup-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        // Above the card, on the dimmed list.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        let closed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: title)
        wait(for: [closed], timeout: 5)
        XCTAssertFalse(app.staticTexts["Sample data. Nothing was removed."].exists, "Nothing was handed to Photos.")
        XCTAssertFalse(app.staticTexts["copy-summary"].exists, "Nothing was sent to Archive either.")
        XCTAssertTrue(app.navigationBars["Large videos"].waitForExistence(timeout: 5), "Still on the list.")
        XCTAssertTrue(delete.exists)
    }

    // MARK: - 1.0.1 round 2: Worth a look as picture cards

    func testWorthALookGroupsArePictureCardsWithTheSameGating() {
        let app = launchWithSamples()
        XCTAssertTrue(app.staticTexts["Ready to tidy"].exists, "The heading stays.")
        let card = app.buttons["smart-screenshots"]
        reveal(card, in: app)
        XCTAssertTrue(card.exists)
        XCTAssertTrue(card.label.contains("Screenshots, read"), card.label)
        XCTAssertTrue(card.label.contains("Pro"), "The PRO badge is on the card. \(card.label)")
        XCTAssertTrue(card.label.contains("screenshots"), "Size and count are on the card. \(card.label)")
        let plain = app.buttons["row-screenshots"]
        // A card is a picture card (96 points or more); the Safe to clear rows stay plain rows.
        XCTAssertGreaterThanOrEqual(card.frame.height, 96)
        if plain.exists { XCTAssertLessThan(plain.frame.height, 96) }
        keepScreenshot(of: app, named: "Worth a look cards")
        // Locked: the half sheet, exactly as before.
        card.tap()
        XCTAssertTrue(app.staticTexts["pro-sheet-title"].waitForExistence(timeout: 5))
        app.buttons["pro-sheet-not-now"].tap()
        // A free card opens its list.
        let more = app.buttons["row-more"]
        reveal(more, in: app)
        XCTAssertGreaterThanOrEqual(more.frame.height, 96, "More types is on Worth a look, so it is a card too.")
        XCTAssertFalse(more.label.contains("Pro"))
        more.tap()
        XCTAssertTrue(app.navigationBars["More types"].waitForExistence(timeout: 5))
    }

    func testEveryFreeUpRowOpens() {
        let app = launchWithSamples()
        let rows = ["row-videos": "Large videos", "row-duplicates": "Duplicates",
                    "row-screenshots": "Screenshots", "row-more": "More types"]
        let order = ["row-duplicates", "row-videos", "row-screenshots", "row-more"]
        for (id, title) in rows.sorted(by: { order.firstIndex(of: $0.key)! < order.firstIndex(of: $1.key)! }) {
            reveal(app.buttons[id], in: app)
            app.buttons[id].tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5), "\(id) should open \(title)")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 5))
        }
        reveal(app.buttons["row-more"], in: app)
        app.buttons["row-more"].tap()
        XCTAssertTrue(app.buttons["category-bursts"].waitForExistence(timeout: 5))
        app.buttons["category-gifs"].tap()
        XCTAssertTrue(app.navigationBars["GIFs"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["category-bursts"].tap()
        XCTAssertTrue(app.navigationBars["Bursts"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["select-all"].exists, "Bursts stay review-only.")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Bursts review only"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testEveryMoreRowOpens() {
        let app = launch()
        app.tabBars.buttons["More"].tap()
        // Top to bottom, as the page is laid out.
        let rows = [("more-pro", "TidyAway Pro"), ("more-checkins", "Check-ins"), ("more-insights", "Storage insights"),
                    ("more-activity", "Activity"), ("more-places", "Archive places"), ("more-tips", "Tips"),
                    ("more-appearance", "Appearance"), ("more-help", "Help & FAQ"), ("more-privacy", "Privacy"),
                    ("more-contact", "Contact us")]
        for (id, title) in rows {
            let row = app.buttons[id]
            reveal(row, in: app)
            XCTAssertTrue(row.waitForExistence(timeout: 5), "\(id) is missing")
            row.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5), "\(id) should open \(title)")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.navigationBars["More"].waitForExistence(timeout: 5))
        }
        XCTAssertTrue(app.buttons["more-restore"].exists, "Restore Purchases is one tap from More.")
        let rate = app.buttons["more-rate"]
        reveal(rate, in: app)
        XCTAssertTrue(rate.exists)
        XCTAssertTrue(app.staticTexts["more-version"].label.hasPrefix("TidyAway 1."), "The version line closes the page.")
        keepScreenshot(of: app, named: "More tab")
    }

    /// Contact us keeps both routes: email and the support page (which links on to the issue list).
    func testContactOffersEmailAndTheSupportPage() {
        let app = launch()
        app.tabBars.buttons["More"].tap()
        let contact = app.buttons["more-contact"]
        reveal(contact, in: app)
        contact.tap()
        XCTAssertTrue(app.navigationBars["Contact us"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["contact-email"].waitForExistence(timeout: 5), "Email support is offered.")
        XCTAssertEqual(app.buttons["contact-email"].label, "Email hello@tidyaway.app")
        XCTAssertTrue(app.buttons["contact-open"].exists, "The support page is still offered.")
        XCTAssertTrue(app.buttons["contact-copy"].exists)
    }

    /// Regression guard: every tip that shipped is still there, behind the one Tips row.
    func testEveryTipIsStillUnderTips() {
        let app = launch()
        app.tabBars.buttons["More"].tap()
        let tips = app.buttons["more-tips"]
        reveal(tips, in: app)
        XCTAssertTrue(tips.label.contains("This week:"), "The row previews one tip. \(tips.label)")
        tips.tap()
        XCTAssertTrue(app.navigationBars["Tips"].waitForExistence(timeout: 5))
        let rows = [("guide-messages", "Messages attachments"), ("more-explainer", "Where your storage goes"),
                    ("more-optimize", "Keep smaller copies"), ("more-icloud-downloads", "Remove a file download")]
        for (id, title) in rows {
            let row = app.buttons[id]
            XCTAssertTrue(row.waitForExistence(timeout: 5), "\(id) is missing")
            row.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5), "\(id) should open \(title)")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.navigationBars["Tips"].waitForExistence(timeout: 5))
        }
        XCTAssertTrue(app.buttons["Free iCloud Drive downloads"].exists || app.staticTexts["Free iCloud Drive downloads"].exists,
                      "The iCloud Drive tool keeps its own label.")
    }

    func testAppearanceIsChosenAndKept() {
        var app = launch()
        app.tabBars.buttons["More"].tap()
        var row = app.buttons["more-appearance"]
        reveal(row, in: app)
        row.tap()
        XCTAssertTrue(app.navigationBars["Appearance"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["More"].exists, "The tab bar stays on Appearance.")
        app.buttons["appearance-dark"].tap()
        XCTAssertTrue(app.buttons["appearance-dark"].isSelected)
        XCTAssertFalse(app.buttons["appearance-system"].isSelected)
        keepScreenshot(of: app, named: "Appearance dark")
        app.terminate()

        app = launch()
        keepScreenshot(of: app, named: "Home dark")
        app.tabBars.buttons["More"].tap()
        row = app.buttons["more-appearance"]
        reveal(row, in: app)
        XCTAssertTrue(row.label.contains("Dark"), "The choice is kept between launches. \(row.label)")
        keepScreenshot(of: app, named: "More dark")
        row.tap()
        // Back to the default, so later tests and pictures follow the iPhone again.
        app.buttons["appearance-system"].tap()
        XCTAssertTrue(app.buttons["appearance-system"].isSelected)
    }

    func testHelpAndPrivacyOpenInPlaceAndKeepEveryParagraph() {
        let app = launch()
        app.tabBars.buttons["More"].tap()
        let help = app.buttons["more-help"]
        reveal(help, in: app)
        help.tap()
        XCTAssertTrue(app.navigationBars["Help & FAQ"].waitForExistence(timeout: 5))
        // Six short titles, every answer closed to begin with.
        let questions = [("faq-free-up", "Free up finds the biggest things"),
                         ("faq-archive", "Archive copies photos and files from your"),
                         ("faq-space", "Deleted photos and videos wait in Recently Deleted"),
                         ("faq-favorites", "No. Favorites are never offered for deletion"),
                         ("faq-score", "One number from free space alone"),
                         ("faq-apps", "No app can. The Storage Checkup shows the steps")]
        for (id, _) in questions {
            XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 5), "\(id) is missing")
            XCTAssertFalse(app.staticTexts["\(id)-answer"].exists, "\(id) starts closed.")
        }
        XCTAssertEqual(app.buttons["faq-free-up"].label, "Free up")
        XCTAssertEqual(app.buttons["faq-archive"].label, "Archive")
        keepScreenshot(of: app, named: "Help closed")
        var last: String?
        for (id, start) in questions {
            app.buttons[id].tap()
            let answer = app.staticTexts["\(id)-answer"]
            XCTAssertTrue(answer.waitForExistence(timeout: 5), "\(id) opens in place.")
            XCTAssertTrue(answer.label.hasPrefix(start), answer.label)
            if let last { XCTAssertFalse(app.staticTexts["\(last)-answer"].exists, "One open at a time.") }
            last = id
        }
        // The Archive answer says where the photos come from.
        app.buttons["faq-archive"].tap()
        XCTAssertTrue(app.staticTexts["faq-archive-answer"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["faq-archive-answer"].label.contains("and iCloud to a place you choose and checks every copy."))
        keepScreenshot(of: app, named: "Help one open")
        // Tapping an open title closes it again.
        app.buttons["faq-archive"].tap()
        XCTAssertFalse(app.staticTexts["faq-archive-answer"].exists)

        app.navigationBars.buttons.element(boundBy: 0).tap()
        let privacy = app.buttons["more-privacy"]
        reveal(privacy, in: app)
        privacy.tap()
        XCTAssertTrue(app.navigationBars["Privacy"].waitForExistence(timeout: 5))
        let topics = [("privacy-reads", "TidyAway reads the Apple Photos items you authorize"),
                      ("privacy-keeps", "The app stores the latest completed check"),
                      ("privacy-maps", "When you choose a place on the Archive tab"),
                      ("privacy-checkins", "Check-ins, if you turn them on"),
                      ("privacy-google", "If you connect Google Drive"),
                      ("privacy-copies", "Checks read originals already available"),
                      ("privacy-list", "After a verified archive copy"),
                      ("privacy-delete", "If you approve deleting items"),
                      ("privacy-controls", "You can change Photos access in Settings"),
                      ("privacy-purchases", "Apple handles in-app purchases."),
                      ("privacy-history", "The Storage Checkup and Storage insights keep a short history")]
        XCTAssertFalse(app.staticTexts["privacy-reads-answer"].exists, "Privacy starts closed too.")
        for (id, start) in topics {
            let title = app.buttons[id]
            reveal(title, in: app)
            XCTAssertTrue(title.waitForExistence(timeout: 5), "\(id) is missing")
            title.tap()
            let answer = app.staticTexts["\(id)-answer"]
            XCTAssertTrue(answer.waitForExistence(timeout: 5), "\(id) opens in place.")
            XCTAssertTrue(answer.label.hasPrefix(start), answer.label)
        }
        keepScreenshot(of: app, named: "Privacy one open")
    }

    func testProUnlockedShowsAsUnlocked() {
        let app = XCUIApplication()
        app.launchArguments += ["--skip-welcome", "--pro"]
        app.launch()
        app.tabBars.buttons["More"].tap()
        app.buttons["more-pro"].tap()
        XCTAssertTrue(app.navigationBars["TidyAway Pro"].waitForExistence(timeout: 5))
        // The Pro list is longer than one screen now; the purchase part sits below the features.
        reveal(app.staticTexts["Pro is unlocked."], in: app)
        XCTAssertTrue(app.staticTexts["Pro is unlocked."].waitForExistence(timeout: 5))
    }

    func testCheckInsOpensFromMoreWithProRowsLocked() {
        let app = XCUIApplication()
        app.launchArguments += ["--skip-welcome", "--demo"]
        app.launch()
        app.tabBars.buttons["More"].tap()
        let row = app.buttons["more-checkins"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.navigationBars["Check-ins"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["checkins-monthly"].exists, "Monthly is offered to everyone.")
        XCTAssertTrue(app.buttons["checkins-weekly"].exists)
        let note = app.descendants(matching: .any)["checkins-note"]
        reveal(note, in: app)
        XCTAssertTrue(note.exists, "The reminders-arrive-on-time note is shown.")
        // Without Pro, a Pro row opens the Pro screen instead of switching on.
        let low = app.buttons["checkins-low"]
        reveal(low, in: app)
        low.tap()
        XCTAssertTrue(app.buttons["Not now"].waitForExistence(timeout: 5), "A locked row offers Pro.")
        app.buttons["Not now"].tap()
        let report = app.buttons["checkins-report"]
        reveal(report, in: app)
        report.tap()
        XCTAssertTrue(app.navigationBars["Check-in"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["report-headline"].exists)
    }

    func testCheckInsProRowsAreSwitchesWithPro() {
        let app = XCUIApplication()
        app.launchArguments += ["--skip-welcome", "--demo", "--pro"]
        app.launch()
        app.tabBars.buttons["More"].tap()
        app.buttons["more-checkins"].tap()
        XCTAssertTrue(app.navigationBars["Check-ins"].waitForExistence(timeout: 5))
        let calendar = app.switches["checkins-calendar"]
        reveal(calendar, in: app)
        XCTAssertTrue(calendar.exists, "With Pro the calendar row is a switch.")
        app.buttons["checkins-daily"].tap()
        XCTAssertTrue(app.buttons["checkins-daily"].isSelected)
    }

    func testMessagesAttachmentsGuideOpensWithoutAScan() {
        let app = launch()
        app.tabBars.buttons["More"].tap()
        let tips = app.buttons["more-tips"]
        reveal(tips, in: app)
        tips.tap()
        app.buttons["guide-messages"].tap()
        XCTAssertTrue(app.navigationBars["Messages attachments"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Wait for the list to load, then tap Messages."].exists)
    }

    func testProOpensFromMore() {
        let app = launch()
        app.tabBars.buttons["More"].tap()
        app.buttons["more-pro"].tap()
        XCTAssertTrue(app.navigationBars["TidyAway Pro"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Monthly, yearly, or once for life. Your choice."].exists)
        XCTAssertTrue(app.staticTexts["Archive up to 5 GB, with every copy checked"].exists)
        // The Pro list is longer than one screen now; the purchase part sits below the features.
        reveal(app.buttons["pro-monthly"], in: app)
        XCTAssertTrue(app.buttons["pro-monthly"].waitForExistence(timeout: 5), "The monthly option is offered.")
        reveal(app.buttons["pro-lifetime"], in: app)
        XCTAssertTrue(app.buttons["pro-lifetime"].exists, "The lifetime option is offered.")
        reveal(app.buttons["Terms of Use"], in: app)
        XCTAssertTrue(app.buttons["Terms of Use"].exists, "Subscription terms are linked.")
        XCTAssertTrue(app.buttons["Privacy Policy"].exists)
        reveal(app.buttons["pro-restore"], in: app)
        XCTAssertTrue(app.buttons["pro-restore"].waitForExistence(timeout: 15))
    }

    func testArchiveTabHasMoveOutAndGetBack() {
        let app = launch()
        app.tabBars.buttons["Archive"].tap()
        let moveOut = app.buttons["archive-move-out"], getBack = app.buttons["archive-get-back"]
        XCTAssertTrue(moveOut.waitForExistence(timeout: 10))
        XCTAssertTrue(getBack.exists)
        XCTAssertGreaterThan(moveOut.frame.height, 80, "Move out and Get back are large buttons.")
        XCTAssertGreaterThan(getBack.frame.height, 80)
        XCTAssertTrue(moveOut.isSelected)
        let promise = app.descendants(matching: .any)["archive-write-only"].firstMatch
        reveal(promise, in: app)
        XCTAssertTrue(promise.exists)
        let files = app.buttons["Pick files myself"]
        reveal(files, in: app)
        XCTAssertTrue(files.waitForExistence(timeout: 5))
        keepScreenshot(of: app, named: "Archive move out")
        getBack.tap()
        XCTAssertTrue(app.staticTexts["Nothing archived yet."].waitForExistence(timeout: 5)
                      || app.descendants(matching: .any)["archive-day"].firstMatch.exists)
        keepScreenshot(of: app, named: "Archive get back")
        moveOut.tap()
        XCTAssertTrue(promise.waitForExistence(timeout: 5))
    }

    func testGoogleDriveAsksToConnectInsteadOfShowingFolders() {
        let app = launch()
        app.tabBars.buttons["Archive"].tap()
        let picker = app.buttons["storage-location"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        reveal(picker, in: app)
        picker.tap()
        let google = app.buttons["Google Drive"].firstMatch
        XCTAssertTrue(google.waitForExistence(timeout: 5))
        google.tap()
        let connect = app.buttons["google-connect"]
        reveal(connect, in: app)
        XCTAssertTrue(connect.waitForExistence(timeout: 5), "Google Drive offers a sign-in, not a folder list.")
        XCTAssertFalse(app.buttons["Choose archive folder in Files"].exists)
    }

    func testOneDriveOffersASignIn() { cloudOffersASignIn("OneDrive") }

    func testDropboxOffersASignIn() { cloudOffersASignIn("Dropbox") }

    private func cloudOffersASignIn(_ name: String) {
        let app = launch()
        app.tabBars.buttons["Archive"].tap()
        let picker = app.buttons["storage-location"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        reveal(picker, in: app)
        picker.tap()
        let tile = app.buttons[name].firstMatch
        reveal(tile, in: app)
        XCTAssertTrue(tile.waitForExistence(timeout: 5), "\(name) is offered once TidyAway is registered there.")
        tile.tap()
        let connect = app.buttons["cloud-connect"]
        reveal(connect, in: app)
        XCTAssertTrue(connect.waitForExistence(timeout: 5), "\(name) offers a sign-in, not a folder list.")
        XCTAssertFalse(app.buttons["Choose archive folder in Files"].exists)
        keepScreenshot(of: app, named: "\(name) destination")
    }

    /// Regression guard: every archive destination that has shipped stays available.
    func testEveryArchiveDestinationIsStillOffered() {
        let app = launch()
        app.tabBars.buttons["Archive"].tap()
        let picker = app.buttons["storage-location"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        reveal(picker, in: app)
        picker.tap()
        for name in ["Drive plugged into this iPhone", "Google Drive", "iCloud Drive", "Other Files location",
                     "Home file server", "Another Apple Account"] {
            XCTAssertTrue(app.buttons[name].firstMatch.waitForExistence(timeout: 5), "\(name) must stay available.")
        }
        app.buttons["Drive plugged into this iPhone"].firstMatch.tap()
        reveal(app.buttons["Choose archive folder in Files"], in: app)
        XCTAssertTrue(app.buttons["Choose archive folder in Files"].waitForExistence(timeout: 5))
        keepScreenshot(of: app, named: "Archive destinations")
        let help = app.buttons["drive-help"]
        reveal(help, in: app)
        help.tap()
        XCTAssertTrue(app.staticTexts["Where to find it"].waitForExistence(timeout: 5))
        keepScreenshot(of: app, named: "Drive help")
        app.buttons["drive-help-done"].tap()
    }

    private func launchArchiveGroups(pro: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--skip-welcome", "--demo-archive"] + (pro ? ["--pro"] : [])
        app.launch()
        app.tabBars.buttons["Archive"].tap()
        return app
    }

    func testAGroupOpensSelectedAndGoesToCopyInOneShot() {
        let app = launchArchiveGroups(pro: true)
        let group = app.buttons["group-large-videos"]
        XCTAssertTrue(group.waitForExistence(timeout: 15), "Very large videos is offered.")
        keepScreenshot(of: app, named: "Archive groups")
        XCTAssertTrue(app.buttons["group-pick-10"].exists, "A pick for 10 GB is ready.")
        app.buttons["goal-5"].tap()
        XCTAssertTrue(app.buttons["group-pick-5"].waitForExistence(timeout: 5), "Choosing a goal changes the pick.")
        app.buttons["section-topics"].tap()
        XCTAssertTrue(app.buttons["group-topic-food"].waitForExistence(timeout: 5), "Food is a topic.")
        keepScreenshot(of: app, named: "Archive topics")
        app.buttons["section-videos"].tap()
        XCTAssertTrue(app.buttons["group-large-videos"].waitForExistence(timeout: 5))
        app.buttons["section-moments"].tap()
        let trip = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'group-trip'")).firstMatch
        XCTAssertTrue(trip.waitForExistence(timeout: 5), "The trip is offered.")
        XCTAssertTrue(trip.label.contains("Beach trip"), "Named by what it shows. \(trip.label)")
        let party = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'group-event'")).firstMatch
        XCTAssertTrue(party.label.contains("Birthday party"), party.label)
        keepScreenshot(of: app, named: "Archive moments")
        trip.tap()
        let next = app.buttons["skim-next"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        XCTAssertTrue(next.label.contains("120 items"), next.label)
        keepScreenshot(of: app, named: "Archive skim")
        XCTAssertFalse(app.staticTexts["Seen 120 of 120"].exists, "Only what has been on screen counts as seen.")
        app.buttons["skim-sample-trip0-0"].tap()
        XCTAssertTrue(next.label.contains("119 items"), "One tap leaves one out. \(next.label)")
        next.tap()
        XCTAssertTrue(app.staticTexts["copy-summary"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["copy-summary"].label.contains("119 items"))
        XCTAssertFalse(app.buttons["archive-copy"].isEnabled, "Nothing copies without a destination and sign-off.")
        keepScreenshot(of: app, named: "Archive copy")
    }

    func testGroupsNeedProButEveryoneSeesThem() {
        let app = launchArchiveGroups(pro: false)
        let group = app.buttons["group-large-videos"]
        XCTAssertTrue(group.waitForExistence(timeout: 15))
        group.tap()
        XCTAssertTrue(app.staticTexts["pro-sheet-title"].waitForExistence(timeout: 5), "Opening a group shows the Pro half sheet.")
        app.buttons["pro-sheet-plans"].tap()
        XCTAssertTrue(app.navigationBars["TidyAway Pro"].waitForExistence(timeout: 5), "See all plans opens the Pro page.")
        reveal(app.buttons["pro-monthly"], in: app)
        XCTAssertTrue(app.buttons["pro-monthly"].waitForExistence(timeout: 5), "Opening a group shows Pro.")
    }

    /// Regression guard: the filters that shipped stay available, free.
    func testArchiveFiltersAreStillAvailable() {
        let app = launchArchiveGroups(pro: false)
        let filter = app.buttons["archive-filter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 15))
        reveal(filter, in: app)
        filter.tap()
        XCTAssertTrue(app.buttons["Show matching photos"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["archive-filters-pro"].exists)
        XCTAssertTrue(app.buttons["archive-suggest-videos"].exists)
    }

    /// Regression guard: restored features stay reachable.
    func testScanDetailsAndUnreadableItemsAreAvailable() {
        let app = launchWithSamples()
        let details = app.buttons["scan-details"]
        reveal(details, in: app)
        XCTAssertTrue(details.waitForExistence(timeout: 5))
        details.tap()
        XCTAssertTrue(app.navigationBars["Scan details"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Items checked"].exists)
        app.buttons["scan-unreadable"].tap()
        XCTAssertTrue(app.navigationBars["Couldn't read"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Cloud-only.heic"].exists)
    }

    func testFirstLaunchWelcomeLeadsToFreeUp() {
        let app = XCUIApplication()
        app.launchArguments += ["--reset-welcome"]
        app.launch()
        let start = app.buttons["Get started"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Nothing is removed until you approve it."].exists)
        start.tap()
        XCTAssertTrue(app.buttons["free-up-space"].waitForExistence(timeout: 10)
                      || app.buttons["check-again"].exists)
        XCTAssertTrue(app.tabBars.buttons["Archive"].exists)
    }

    func testWelcomeStorySkipLandsOnEveryWelcomeElement() {
        let app = XCUIApplication()
        app.launchArguments += ["--reset-welcome"]
        app.launch()
        let skip = app.buttons["welcome-skip"]
        XCTAssertTrue(skip.waitForExistence(timeout: 10), "The story should open with a Skip button.")
        keepScreenshot(of: app, named: "Welcome moment")
        skip.tap()
        XCTAssertTrue(app.buttons["Get started"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Try it with sample photos"].exists, "Samples are not offered to people.")
        XCTAssertTrue(app.staticTexts["Out of space? Let's fix it safely."].exists)
        XCTAssertTrue(app.staticTexts["The check runs on your iPhone. Your photos stay put."].exists)
        XCTAssertTrue(app.staticTexts["Nothing is removed until you approve it."].exists)
        XCTAssertTrue(app.staticTexts["Every change is logged and can be traced."].exists)
        XCTAssertFalse(app.buttons["welcome-skip"].exists, "Skip goes away on the last screen.")
        keepScreenshot(of: app, named: "Welcome payoff")
        app.buttons["Get started"].tap()
        XCTAssertTrue(app.buttons["free-up-space"].waitForExistence(timeout: 10)
                      || app.buttons["check-again"].exists)
        XCTAssertFalse(app.buttons["try-samples"].exists)
    }

    func testWelcomeStoryTapMovesOnAndEndsOnGetStarted() {
        let app = XCUIApplication()
        app.launchArguments += ["--reset-welcome"]
        app.launch()
        XCTAssertTrue(app.buttons["welcome-skip"].waitForExistence(timeout: 10))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        usleep(1_500_000)
        keepScreenshot(of: app, named: "Welcome scan")
        XCTAssertTrue(app.buttons["Get started"].waitForExistence(timeout: 15), "The story should end by itself.")
    }

    func testLandingPageShowsTheDialAndEveryFind() {
        let before = launch()
        XCTAssertTrue(before.buttons["free-up-space"].waitForExistence(timeout: 10) || before.buttons["check-again"].exists)
        if before.buttons["free-up-space"].exists {
            XCTAssertGreaterThan(before.buttons["free-up-space"].frame.width, 150, "Free up space is the biggest button on the page.")
        }
        keepScreenshot(of: before, named: "Landing before scan")
        before.terminate()

        let app = launchWithSamples()
        XCTAssertTrue(app.staticTexts["hero-bytes"].waitForExistence(timeout: 5))
        keepScreenshot(of: app, named: "Landing results")
        XCTAssertTrue(app.descendants(matching: .any)["storage-score"].exists, "The Storage Score ring leads the page.")
        XCTAssertTrue(app.staticTexts["Ready to tidy"].exists)
        for tag in ["Safe to clear", "Worth a look", "Move it, keep it"] {
            XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", tag)).firstMatch.exists, tag)
        }
        for row in ["row-duplicates", "row-videos", "row-screenshots", "row-more", "scan-details", "check-again", "review-next",
                    "whats-using", "storage-checkup", "score-info", "home-settings", "freeup-forYou", "freeup-smart", "freeup-byType"] {
            XCTAssertTrue(app.buttons[row].exists, "\(row) must stay available.")
        }
        XCTAssertTrue(app.buttons["recently-deleted-card"].exists)
        app.swipeUp()
        keepScreenshot(of: app, named: "Landing results scrolled")
        app.buttons["review-next"].tap()
        XCTAssertTrue(app.navigationBars["Duplicates"].waitForExistence(timeout: 5), "The next step opens the safe finds first.")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let using = app.buttons["whats-using"]
        for _ in 0..<4 where !using.isHittable { app.swipeDown() }
        using.tap()
        XCTAssertTrue(app.staticTexts["What's using your iPhone"].waitForExistence(timeout: 5))
    }

    func testRecentlyDeletedGuideOpensWithClearStepsAndMeasures() {
        let app = launch()
        let card = app.buttons["recently-deleted-card"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()
        let measure = app.buttons["recently-deleted-measure"]
        XCTAssertTrue(app.staticTexts["Empty Recently Deleted"].waitForExistence(timeout: 5))
        keepScreenshot(of: app, named: "Recently Deleted guide")
        for _ in 0..<5 where !measure.isHittable { app.swipeUp() }
        measure.tap()
        XCTAssertTrue(app.descendants(matching: .any)["recently-deleted-result"].waitForExistence(timeout: 5))
        app.buttons["recently-deleted-done"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
    }

    func testFreeUpSelectionGoesStraightToArchiveCopy() {
        let app = launchWithSamples()
        let videos = app.buttons["row-videos"]
        reveal(videos, in: app)
        videos.tap()
        XCTAssertTrue(app.navigationBars["Large videos"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["archive-selected"].exists, "Nothing selected, nothing to archive.")
        app.buttons["select-sample-11"].tap()
        let archive = app.buttons["archive-selected"]
        XCTAssertTrue(archive.waitForExistence(timeout: 5), "Selected items can be archived from here.")
        keepScreenshot(of: app, named: "Free up archive selected")
        archive.tap()
        XCTAssertTrue(app.tabBars.buttons["Archive"].waitForExistence(timeout: 5))
        let summary = app.staticTexts["copy-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 10), "Archive opens on its copy screen.")
        XCTAssertTrue(summary.label.hasPrefix("1 item"), summary.label)
        XCTAssertTrue(app.buttons["Drive plugged into this iPhone"].firstMatch.exists, "Every destination is offered.")
        keepScreenshot(of: app, named: "Archive copy from Free up")
        let clear = app.buttons["copy-clear"]
        reveal(clear, in: app)
        clear.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: summary)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.buttons["archive-next"].exists, "Cleared: nothing left selected.")
    }

    // MARK: - 1.0.1 home, Pro sheet and Storage Checkup

    func testStorageScoreInfoExplainsTheScore() {
        let app = launchWithSamples()
        let info = app.buttons["score-info"]
        for _ in 0..<4 where !info.isHittable { app.swipeDown() }
        let meaning = NSPredicate(format: "label BEGINSWITH %@", "Storage Score, based only on free space")
        let iosNote = NSPredicate(format: "label BEGINSWITH %@", "iOS doesn't share how the rest is split")
        XCTAssertEqual(app.staticTexts.matching(meaning).count, 0, "The card carries no explanation sentence.")
        XCTAssertEqual(app.staticTexts.matching(iosNote).count, 0)
        XCTAssertTrue(app.staticTexts["storage-used"].exists && app.descendants(matching: .any)["storage-band"].firstMatch.exists,
                      "The ring's neighbours stay: how full, and the grade.")
        info.tap()
        XCTAssertTrue(app.navigationBars["How the Storage Score works"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["score-meaning"].waitForExistence(timeout: 5), "The score sentence moved here.")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Score = free space")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["score-yours"].exists, "It works the score out with this iPhone's own numbers.")
        let barPart = app.buttons["score-part-bar"]
        for _ in 0..<3 where !barPart.isHittable { app.swipeUp() }
        barPart.tap()
        XCTAssertTrue(app.staticTexts["score-bar-note"].waitForExistence(timeout: 5), "Measured, worked out and the iOS note are here.")
        XCTAssertFalse(app.staticTexts["score-yours"].exists, "One section open at a time.")
        keepScreenshot(of: app, named: "Storage Score info")
        app.buttons["score-info-done"].tap()
        XCTAssertTrue(app.buttons["row-duplicates"].waitForExistence(timeout: 5))
    }

    func testPillsFilterTheShelvesAndKeepEveryRowReachable() {
        let app = launchWithSamples()
        reveal(app.buttons["freeup-byType"], in: app)
        // The bottom dock is taller than its button: with the shorter score card the pills can sit
        // under the dock's estimate line, where a tap lands on the dock. Bring them clear of it.
        let pill = app.buttons["freeup-byType"]
        let dock = app.staticTexts["hero-bytes"]
        if dock.exists && pill.frame.maxY > dock.frame.minY - 8 {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -160)))
        }
        app.buttons["freeup-byType"].tap()
        XCTAssertTrue(app.buttons["row-duplicates"].exists)
        XCTAssertTrue(app.buttons["row-videos"].exists)
        XCTAssertFalse(app.buttons["smart-screenshots"].exists, "By type leaves the smart rows out.")
        app.buttons["freeup-smart"].tap()
        XCTAssertTrue(app.buttons["smart-screenshots"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["row-duplicates"].exists)
        app.buttons["freeup-forYou"].tap()
        XCTAssertTrue(app.buttons["row-duplicates"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["smart-screenshots"].exists)
    }

    func testAProRowOpensTheHalfSheetAndNotNowClosesIt() {
        let app = launchWithSamples()
        let row = app.buttons["smart-screenshots"]
        reveal(row, in: app)
        XCTAssertTrue(row.label.contains("Pro"), "A Pro row stays visible, with its badge. \(row.label)")
        row.tap()
        XCTAssertTrue(app.staticTexts["pro-sheet-title"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["pro-sheet-title"].label, "Available in TidyAway Pro")
        XCTAssertTrue(app.buttons["pro-sheet-start"].exists)
        XCTAssertTrue(app.buttons["pro-sheet-plans"].exists)
        keepScreenshot(of: app, named: "Pro half sheet")
        app.buttons["pro-sheet-not-now"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["pro-sheet-title"].exists)
        // The free lists never ask.
        XCTAssertFalse(app.buttons["row-duplicates"].label.contains("Pro"))
    }

    func testSeeAllPlansOpensTheProPageFromTheSheet() {
        let app = launchWithSamples()
        let row = app.buttons["smart-screenshots"]
        reveal(row, in: app)
        row.tap()
        XCTAssertTrue(app.buttons["pro-sheet-plans"].waitForExistence(timeout: 5))
        app.buttons["pro-sheet-plans"].tap()
        XCTAssertTrue(app.navigationBars["TidyAway Pro"].waitForExistence(timeout: 5))
    }

    func testWithProTheSameRowOpensItsList() {
        let app = XCUIApplication()
        app.launchArguments += ["--skip-welcome", "--demo", "--pro"]
        app.launch()
        let row = app.buttons["smart-screenshots"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        reveal(row, in: app)
        row.tap()
        XCTAssertTrue(app.navigationBars["Screenshots, read"].waitForExistence(timeout: 5))
    }

    func testTheGearOpensMore() {
        let app = launch()
        app.buttons["home-settings"].tap()
        XCTAssertTrue(app.navigationBars["More"].waitForExistence(timeout: 5))
    }

    func testStorageCheckupGuidesStepsAndMeasures() {
        let app = XCUIApplication()
        app.launchArguments += ["--skip-welcome", "--reset-checkup"]
        app.launch()
        let link = app.buttons["storage-checkup"]
        XCTAssertTrue(link.waitForExistence(timeout: 15))
        link.tap()
        XCTAssertTrue(app.navigationBars["Storage Checkup"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.tabBars.buttons["More"].isHittable, "The tab bar steps aside for the guided flow.")
        XCTAssertEqual(app.staticTexts["checkup-count"].label, "0 of 7 done")
        let path = app.staticTexts["checkup-path"]
        XCTAssertTrue(path.exists, "Each step gives its Settings path as text.")
        XCTAssertTrue(path.label.contains("Software Update"), path.label)
        XCTAssertFalse(app.buttons["Open Settings"].exists, "No links into Settings.")
        keepScreenshot(of: app, named: "Storage Checkup")
        let measure = app.buttons["checkup-measure"]
        for _ in 0..<5 where !measure.isHittable { app.swipeUp() }
        measure.tap()
        XCTAssertTrue(app.descendants(matching: .any)["checkup-result"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["checkup-count"].label, "1 of 7 done", "Measuring marks the step.")
        let skip = app.buttons["checkup-skip"]
        for _ in 0..<5 where !skip.isHittable { app.swipeUp() }
        skip.tap()
        XCTAssertTrue(app.staticTexts["checkup-path"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["checkup-path"].label.contains("WhatsApp"), "The next step opens.")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "restart")).firstMatch.exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.tabBars.buttons["More"].waitForExistence(timeout: 5))
    }

    func testStorageTipHasNoRestartAdvice() {
        let app = launch()
        app.tabBars.buttons["More"].tap()
        let tips = app.buttons["more-tips"]
        reveal(tips, in: app)
        tips.tap()
        let row = app.buttons["more-explainer"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.navigationBars["Where your storage goes"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "restart")).firstMatch.exists,
                       "Apps must not suggest restarting the iPhone.")
    }

    // MARK: - Preview before delete

    func testAPictureOpensThePreviewAndSelectingThereNeverDeletes() {
        let app = launchWithSamples()
        let videos = app.buttons["row-videos"]
        reveal(videos, in: app)
        videos.tap()
        XCTAssertTrue(app.navigationBars["Large videos"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["preview-hint"].firstMatch.exists, "The list says how looking and choosing work.")
        let picture = app.buttons["preview-sample-11"]
        XCTAssertTrue(picture.waitForExistence(timeout: 5), "The picture is its own button.")
        picture.tap()
        let select = app.buttons["preview-select"]
        XCTAssertTrue(select.waitForExistence(timeout: 5), "The viewer opens full screen.")
        XCTAssertTrue(app.buttons["preview-keep"].isSelected, "Nothing is selected for you.")
        XCTAssertTrue(app.descendants(matching: .any)["preview-position"].firstMatch.label.contains(" of "))
        let viewer = app.descendants(matching: .any)["preview-viewer"].firstMatch
        XCTAssertTrue(viewer.exists, "The viewer is one container.")
        let deleteWord = NSPredicate(format: "label CONTAINS[c] %@", "delete")
        // Inside the viewer there is never a Delete, and nothing behind it can be reached while it is open:
        // the list's own "Delete 1 item" button appears once something is ticked, and it must stay hidden.
        let deletingInViewer = viewer.buttons.matching(deleteWord)
        let deletingAnywhere = app.buttons.matching(deleteWord)
        XCTAssertEqual(deletingInViewer.count, 0, "There is no Delete in the viewer.")
        XCTAssertEqual(deletingAnywhere.count, 0, "Nothing behind the viewer can be reached.")
        keepScreenshot(of: app, named: "Preview viewer")
        select.tap()
        XCTAssertTrue(select.isSelected)
        XCTAssertEqual(deletingInViewer.count, 0, "Selecting in the viewer deletes nothing.")
        // The full-screen cover leaves the list in the hierarchy XCUITest sees, so check what a person can do:
        // the list's Delete must be neither tappable nor enabled while the viewer is open.
        let listDelete = app.buttons["delete-selected"]
        if listDelete.exists {
            XCTAssertFalse(listDelete.isHittable, "The list's Delete can't be tapped from the viewer.")
            XCTAssertFalse(listDelete.isEnabled, "Deleting still needs the sign-off.")
        }
        app.buttons["preview-info"].tap()
        XCTAssertTrue(app.navigationBars["File info"].waitForExistence(timeout: 5))
        keepScreenshot(of: app, named: "Preview file info")
        app.buttons["preview-info-done"].tap()
        app.buttons["preview-done"].tap()
        // Back on the list: the item is ticked, and deleting still needs the sign-off.
        let delete = app.buttons["delete-selected"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "The tick made in the viewer shows on the list.")
        XCTAssertFalse(delete.isEnabled, "Deleting still needs the sign-off.")
        XCTAssertTrue(app.buttons["select-sample-11"].label.hasPrefix("Selected"))
    }

    func testKeepInThePreviewUnticksAndClearsTheSignOff() {
        let app = launchWithSamples()
        let videos = app.buttons["row-videos"]
        reveal(videos, in: app)
        videos.tap()
        XCTAssertTrue(app.navigationBars["Large videos"].waitForExistence(timeout: 5))
        app.buttons["select-sample-11"].tap()
        let delete = app.buttons["delete-selected"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        app.buttons["signoff"].tap()
        XCTAssertTrue(delete.isEnabled)
        app.buttons["preview-sample-11"].tap()
        let keep = app.buttons["preview-keep"]
        XCTAssertTrue(keep.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["preview-select"].isSelected, "The viewer shows what is ticked on the list.")
        keep.tap()
        XCTAssertTrue(keep.isSelected)
        app.buttons["preview-done"].tap()
        XCTAssertTrue(app.buttons["select-sample-11"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["select-sample-11"].label.hasPrefix("Select "), "Keep unticked it.")
        XCTAssertFalse(app.buttons["delete-selected"].exists, "Nothing selected, nothing to delete.")
    }

    func testAKeptCopyOpensViewOnly() {
        let app = launchWithSamples()
        reveal(app.buttons["row-duplicates"], in: app)
        app.buttons["row-duplicates"].tap()
        XCTAssertTrue(app.navigationBars["Duplicates"].waitForExistence(timeout: 5))
        let kept = app.buttons["preview-sample-1"]
        XCTAssertTrue(kept.waitForExistence(timeout: 5), "The copy that stays can still be looked at.")
        kept.tap()
        XCTAssertTrue(app.descendants(matching: .any)["preview-stays"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["preview-select"].exists, "The copy that stays can't be selected in the viewer either.")
        app.buttons["preview-done"].tap()
        XCTAssertTrue(app.navigationBars["Duplicates"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["delete-selected"].exists)
    }

    private func keepScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--skip-welcome"]
        app.launch()
        XCTAssertTrue(app.navigationBars["TidyAway"].waitForExistence(timeout: 15)
                      || app.tabBars.buttons["Free up"].exists)
        return app
    }

    private func launchWithSamples() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--skip-welcome", "--demo"]
        app.launch()
        XCTAssertTrue(app.buttons["row-duplicates"].waitForExistence(timeout: 15), "Sample results should load.")
        return app
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<12 {
            // The landing page's bottom button floats over the list; what is under it isn't really reachable.
            let bar = app.buttons["review-next"]
            let clear = !bar.exists || element.identifier == "review-next" || (element.exists && element.frame.maxY < bar.frame.minY - 8)
            if element.exists && element.isHittable && clear { return }
            // Lists scroll as collection views; Free up is a plain scroll view.
            let list = app.collectionViews.firstMatch
            if list.exists { list.swipeUp(velocity: .slow) } else { app.swipeUp(velocity: .slow) }
        }
    }
}
