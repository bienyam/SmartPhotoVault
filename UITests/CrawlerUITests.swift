import XCTest

/// Taps every control on every screen it can reach (sample photos, so nothing real changes) and
/// reports what each tap did. Findings are printed as `CRAWL|…` lines and attached as a report:
/// - NO_EFFECT: the tap changed nothing visible (a dead button, or one that needs real data)
/// - UNREACHABLE: listed but never became tappable
/// - LEAF: a screen with nothing to tap except going back (fine for help pages, a dead end otherwise)
/// - DEPTH: how many taps from launch each screen takes
/// It fails only if the app crashes or shows an error screen.
final class CrawlerUITests: XCTestCase {
    private struct Step: Hashable { let key: String }
    private var report: [String] = []
    private var depth: [String: Int] = [:]
    private var visited: Set<String> = []

    /// Controls the crawler never taps: they leave the app, spend money, sign in, start a real
    /// scan of the photo library, or delete. Each is listed in the report as SKIPPED.
    private let skip: [String] = [
        "Terms of Use", "Privacy Policy", "Open Settings", "google-connect", "Disconnect Google Drive",
        "pro-monthly", "pro-lifetime", "pro-restore", "Restore purchase", "Manage subscription", "Try again",
        "Pick photos or videos myself", "Pick files myself", "Choose archive folder in Files",
        "Choose where to restore it", "Change folder", "delete-selected", "free-up-space", "check-again",
        "Check my photos instead", "Stop", "Allow Access to Photos", "See TidyAway Pro", "Switch to lifetime"
    ]

    override func setUp() {
        continueAfterFailure = true
        executionTimeAllowance = 2400
    }

    func testCrawlEveryScreen() {
        let started = Date()
        var queue: [[Step]] = ["Free up", "Archive", "More"].map { [Step(key: "tab:\($0)")] }
        while !queue.isEmpty, Date().timeIntervalSince(started) < 2100 {
            let path = queue.removeFirst()
            guard let app = open(path) else { continue }
            let screen = screenKey(app)
            let controls = candidates(app)
            // A screen with a menu or sheet open has different controls, so it counts as its own state.
            guard visited.insert(screen + "#" + controls.sorted().joined(separator: ",")).inserted else { continue }
            if depth[screen] == nil {
                depth[screen] = path.count
                log("DEPTH", path, "", "\(path.count) taps → \(screen)")
            }
            if controls.isEmpty { log("LEAF", path, "", screen) }
            var fresh = true
            for key in controls.prefix(30) {
                if skip.contains(where: { key.contains($0) }) {
                    log("SKIPPED", path, key, "leaves the app, buys, signs in, scans or deletes")
                    continue
                }
                if !fresh { guard reopen(app, path) else { break } }
                let before = signature(app)
                guard let element = find(key, in: app), reveal(element, in: app) else {
                    log("UNREACHABLE", path, key, "listed but not tappable")
                    fresh = true
                    continue
                }
                element.tap()
                _ = app.wait(for: .runningForeground, timeout: 2)
                usleep(700_000)
                if dismissSystemPrompt() {
                    log("SYSTEM_PROMPT", path, key, "opened an iOS permission dialog (dismissed)")
                    fresh = false
                    continue
                }
                checkHealthy(app, path + [Step(key: key)])
                let after = signature(app)
                if after == before {
                    log("NO_EFFECT", path, key, "nothing changed on \(screen)")
                    fresh = true
                } else {
                    let title = navTitle(app)
                    let kind = title != navTitleFrom(before) ? "OPENS" : "CHANGES"
                    log(kind, path, key, title.isEmpty ? "sheet, popover or state change" : title)
                    let revealedNew = !Set(candidates(app)).subtracting(controls).isEmpty
                    if kind == "OPENS" || revealedNew {
                        queue.append(path + [Step(key: key)])
                    }
                    // Going back is much faster than relaunching; fall back to a relaunch if it doesn't return.
                    fresh = kind == "OPENS" && goBack(app) && signature(app) == before
                }
            }
        }
        let counts = Dictionary(grouping: report, by: { $0.split(separator: "|").dropFirst().first.map(String.init) ?? "" })
            .map { "\($0.key)=\($0.value.count)" }.sorted().joined(separator: " ")
        report.insert("CRAWL|TOTALS|\(counts)", at: 0)
        let summary = report.joined(separator: "\n")
        let attachment = XCTAttachment(string: summary)
        attachment.name = "ui-crawl-report"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("CRAWL|SUMMARY|screens=\(visited.count)|lines=\(report.count)|seconds=\(Int(Date().timeIntervalSince(started)))")
    }

    // MARK: - Navigation

    private func open(_ path: [Step]) -> XCUIApplication? {
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = ["--skip-welcome", "--demo"]
        app.launch()
        guard app.tabBars.firstMatch.waitForExistence(timeout: 15) else { return nil }
        for (index, step) in path.enumerated() {
            guard let element = find(step.key, in: app), reveal(element, in: app) else {
                log("PATH_BROKEN", Array(path.prefix(index)), step.key, "could not replay")
                return nil
            }
            element.tap()
            usleep(900_000)
        }
        return app
    }

    private func reopen(_ app: XCUIApplication, _ path: [Step]) -> Bool { open(path) != nil }

    /// Taps the navigation bar's Back button, if there is one.
    private func goBack(_ app: XCUIApplication) -> Bool {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        guard back.exists, back.isHittable, back.frame.minX < 120 else { return false }
        back.tap()
        usleep(700_000)
        return true
    }

    /// iOS permission dialogs belong to the system, not the app, so they need their own check.
    private func dismissSystemPrompt() -> Bool {
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        guard alert.waitForExistence(timeout: 1) else { return false }
        for label in ["Don’t Allow", "Don't Allow", "Cancel", "Not Now", "OK"] where alert.buttons[label].exists {
            alert.buttons[label].tap()
            return true
        }
        alert.buttons.element(boundBy: 0).tap()
        return true
    }

    private func find(_ key: String, in app: XCUIApplication) -> XCUIElement? {
        if key.hasPrefix("tab:") { return app.tabBars.buttons[String(key.dropFirst(4))] }
        if key.hasPrefix("id:") {
            let element = app.descendants(matching: .any).matching(identifier: String(key.dropFirst(3))).firstMatch
            return element.exists ? element : nil
        }
        let label = String(key.dropFirst(6))
        for query in [app.buttons, app.switches, app.cells] {
            let element = query.matching(NSPredicate(format: "label == %@", label)).firstMatch
            if element.exists { return element }
        }
        return nil
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<6 {
            if element.exists && element.isHittable { return true }
            app.swipeUp(velocity: .slow)
        }
        return element.exists && element.isHittable
    }

    // MARK: - Reading the screen

    private func candidates(_ app: XCUIApplication) -> [String] {
        var keys: [String] = []
        let backLabel = app.navigationBars.buttons.firstMatch.exists ? app.navigationBars.buttons.firstMatch.label : nil
        for query in [app.buttons, app.switches] {
            for element in query.allElementsBoundByIndex.prefix(60) where element.exists {
                if app.tabBars.buttons.matching(NSPredicate(format: "label == %@", element.label)).count > 0 { continue }
                if element.label == backLabel && element.frame.minY < 120 { continue }
                let key = element.identifier.isEmpty ? "label:\(element.label)" : "id:\(element.identifier)"
                if element.label.isEmpty && element.identifier.isEmpty { continue }
                if !keys.contains(key) { keys.append(key) }
            }
        }
        return keys
    }

    private func navTitle(_ app: XCUIApplication) -> String {
        let bar = app.navigationBars.firstMatch
        return bar.exists ? bar.identifier : ""
    }

    private func navTitleFrom(_ signature: String) -> String {
        String(signature.split(separator: "§").first ?? "")
    }

    private func screenKey(_ app: XCUIApplication) -> String {
        let selectedTab = app.tabBars.buttons.allElementsBoundByIndex.first { $0.isSelected }?.label ?? "?"
        let title = navTitle(app)
        return "\(selectedTab) › \(title.isEmpty ? "(untitled)" : title)"
    }

    private func signature(_ app: XCUIApplication) -> String {
        let texts = app.staticTexts.allElementsBoundByIndex.prefix(50).map(\.label)
        let buttons = app.buttons.allElementsBoundByIndex.prefix(50).map { "\($0.identifier)|\($0.label)|\($0.isSelected)|\($0.isEnabled)" }
        let switches = app.switches.allElementsBoundByIndex.prefix(20).map { "\($0.label)=\($0.value as? String ?? "")" }
        return ([navTitle(app)] + ["\(app.sheets.count)/\(app.popovers.count)"] + texts + buttons + switches).joined(separator: "§")
    }

    private func checkHealthy(_ app: XCUIApplication, _ path: [Step]) {
        if app.state != .runningForeground {
            log("CRASH", path, "", "app is not running")
            XCTFail("The app stopped after: \(path.map(\.key).joined(separator: " → "))")
        }
    }

    private func log(_ kind: String, _ path: [Step], _ key: String, _ detail: String) {
        let line = "CRAWL|\(kind)|\(path.map(\.key).joined(separator: " → "))|\(key)|\(detail)"
        report.append(line)
        print(line)
    }
}
