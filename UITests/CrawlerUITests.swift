import XCTest

/// Taps every control on every screen it can reach (sample items, so nothing real changes) and
/// reports what each tap did. Findings are printed as `CRAWL|…` lines and attached as a report:
/// - NO_EFFECT: the tap changed nothing visible (a dead button, or one that needs real data)
/// - UNREACHABLE: listed but never became tappable
/// - LEAF: a screen with nothing to tap except going back (fine for help pages, a dead end otherwise)
/// - DEPTH: how many taps from launch each screen takes
/// - SAME_KIND: a screen built like one already explored; opening it is checked, its inside isn't repeated
/// It fails if the app crashes, or if it can't finish, so a partial crawl never passes for a full one.
final class CrawlerUITests: XCTestCase {
    private struct Step: Hashable { let key: String }
    private var report: [String] = []
    private var depth: [String: Int] = [:]
    private var visited: Set<String> = []

    /// Controls the crawler never taps: they leave the app, spend money, sign in, start a real
    /// scan of the photo library, or delete. Each is listed in the report as SKIPPED.
    private let skip: [String] = [
        "Terms of Use", "Privacy Policy", "Open Settings", "google-connect", "Disconnect Google Drive", "cloud-connect", "Disconnect OneDrive", "Disconnect Dropbox",
        "pro-monthly", "pro-lifetime", "pro-restore", "pro-sheet-start", "Restore purchase", "Manage subscription", "Try again",
        "Pick photos or videos myself", "Pick files myself", "Choose archive folder in Files",
        "Choose where to restore it", "Change folder", "archive-scan", "archive-copy", "archive-stop",
        // These open Apple's own file window, which belongs to another process and covers the app.
        "Choose an iCloud Drive file", "Choose a different drive or folder", "Choose a folder", "delete-selected", "free-up-space", "check-again",
        "Check my photos instead", "Stop", "Allow Access to Photos", "See TidyAway Pro", "Switch to lifetime",
        // Check-ins: switching these on asks for notification and calendar access, a system prompt that covers the app.
        "checkins-daily", "checkins-weekly", "checkins-monthly", "checkins-low", "checkins-junk", "checkins-photos", "checkins-calendar"
    ]

    /// Finishing takes a fraction of this; running out means coverage is incomplete.
    private let budget: TimeInterval = 1_200
    private var app = XCUIApplication()
    private var rootSignatures: [String: String] = [:]
    private var shapes: Set<String> = []
    private var tapped: [String: Int] = [:]
    /// Controls already tapped, by screen, however the screen was reached.
    private var done: Set<String> = []
    private var relaunches = 0

    override func setUp() {
        continueAfterFailure = true
        executionTimeAllowance = 1_800
    }

    func testCrawlEveryScreen() {
        let started = Date()
        var queue: [[Step]] = ["Free up", "Archive", "More"].map { [Step(key: "tab:\($0)")] }
        while !queue.isEmpty, Date().timeIntervalSince(started) < budget {
            let path = queue.removeFirst()
            guard open(path) else { continue }
            let screen = screenKey(app)
            let controls = candidates(app)
            // A screen with a menu or sheet open has different controls, so it counts as its own state.
            guard visited.insert(screen + "#" + controls.sorted().joined(separator: ",")).inserted else { continue }
            if depth[screen] == nil {
                depth[screen] = path.count
                log("DEPTH", path, "", "\(path.count) taps → \(screen)")
            }
            if controls.isEmpty { log("LEAF", path, "", screen) }
            let shape = Set(controls.map(Self.kind)).sorted().joined(separator: ",")
            if controls.count >= 3, !shapes.insert(shape).inserted {
                log("SAME_KIND", path, "", screen)
                continue
            }
            var pending = controls
            var index = 0
            var restarts = 0
            while index < pending.count, Date().timeIntervalSince(started) < budget {
                let key = pending[index]
                index += 1
                if skip.contains(where: { key.contains($0) }) {
                    log("SKIPPED", path, key, "leaves the app, buys, signs in, scans or deletes")
                    continue
                }
                // Rows of one kind behave alike: two of each on a screen are enough.
                let kindOnScreen = screen + "|" + Self.kind(key)
                if tapped[kindOnScreen, default: 0] >= 2 || !done.insert(screen + "|" + key).inserted { continue }
                tapped[kindOnScreen, default: 0] += 1
                let before = signature(app)
                guard let element = find(key, in: app), reveal(element, in: app) else {
                    if restarts < 3, controls.contains(key) {
                        // Something chosen earlier on this screen put it away. Start the screen again and go on from here.
                        restarts += 1
                        index -= 1
                        tapped[kindOnScreen, default: 1] -= 1
                        done.remove(screen + "|" + key)
                        guard open(path, fresh: true) else { break }
                        if find(key, in: app) == nil {
                            log("UNREACHABLE", path, key, "listed but not found")
                            index += 1
                        }
                    } else if controls.contains(key) {
                        log("UNREACHABLE", path, key, "listed but not tappable")
                    }
                    continue
                }
                guard tap(element) else {
                    log("UNREACHABLE", path, key, "covered by something else")
                    guard open(path, fresh: true) else { break }
                    continue
                }
                let after = settle(changedFrom: before)
                if dismissSystemPrompt() {
                    log("SYSTEM_PROMPT", path, key, "opened an iOS permission dialog (dismissed)")
                    guard open(path) else { break }
                    continue
                }
                checkHealthy(app, path + [Step(key: key)])
                if after == before {
                    log("NO_EFFECT", path, key, "nothing changed on \(screen)")
                    continue
                }
                let title = navTitleFrom(after)
                // No title at all means something on top, such as a popover.
                let opens = !title.isEmpty && title != navTitleFrom(before)
                log(opens ? "OPENS" : "CHANGES", path, key, title.isEmpty ? "sheet, popover or state change" : title)
                let found = candidates(app)
                let covered = place(after) != place(before) || !(find(key, in: app).map { canTap($0, in: app) } ?? false)
                if opens || covered {
                    // Somewhere else, or a menu or sheet on top: look at it later, and go back now.
                    let revealed = !Set(found.map(Self.kind)).subtracting(controls.map(Self.kind)).isEmpty
                    // A menu or popover has no title of its own: opening it is the check, so it isn't explored again and again.
                    let overlay = title == navTitleFrom(before) && place(after) != place(before) && revealed
                    if path.count < 6, opens || overlay { queue.append(path + [Step(key: key)]) }
                    guard undo(key, to: before, opened: opens) || open(path) else { break }
                } else {
                    // A choice on the same screen. Nothing needs undoing; anything it revealed is tapped here too.
                    for extra in found where !pending.contains(extra) { pending.append(extra) }
                }
            }
        }
        let seconds = Int(Date().timeIntervalSince(started))
        let counts = Dictionary(grouping: report, by: { $0.split(separator: "|").dropFirst().first.map(String.init) ?? "" })
            .map { "\($0.key)=\($0.value.count)" }.sorted().joined(separator: " ")
        report.insert("CRAWL|TOTALS|\(counts)", at: 0)
        let summary = report.joined(separator: "\n")
        let attachment = XCTAttachment(string: summary)
        attachment.name = "ui-crawl-report"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("CRAWL|SUMMARY|complete=\(queue.isEmpty)|left=\(queue.count)|screens=\(visited.count)|lines=\(report.count)|relaunches=\(relaunches)|seconds=\(seconds)")
        XCTAssertTrue(queue.isEmpty, "Ran out of time with \(queue.count) screens left, so coverage is incomplete.")
    }

    /// The same key with numbers and sample names taken out, so rows of one kind compare equal.
    private static func kind(_ key: String) -> String {
        key.replacingOccurrences(of: "sample-[A-Za-z0-9-]+", with: "sample", options: .regularExpression)
            .replacingOccurrences(of: "[0-9]+", with: "#", options: .regularExpression)
    }

    // MARK: - Navigation

    /// Waits only as long as the screen is still changing.
    @discardableResult
    private func settle(changedFrom before: String? = nil, timeout: TimeInterval = 1.2) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var last = signature(app)
        while Date() < deadline {
            usleep(80_000)
            let now = signature(app)
            if now == last, before == nil || now != before { return now }
            last = now
        }
        return last
    }

    /// Which screen this is and what is on top of it, ignoring what is selected there.
    private func place(_ signature: String) -> String {
        signature.components(separatedBy: "§").prefix(2).joined(separator: "§")
    }

    /// Goes back the way a person would. Much faster than starting the app again.
    private func undo(_ key: String, to before: String, opened: Bool) -> Bool {
        func back() -> Bool {
            guard place(settle(timeout: 0.6)) == place(before), let element = find(key, in: app) else { return false }
            return canTap(element, in: app) || reveal(element, in: app)
        }
        func outside() -> Bool {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.07)).tap()
            return back()
        }
        if opened {
            if goBack(app), back() { return true }
        } else if outside() {
            return true
        }
        for name in ["Done", "Not now", "Cancel", "Close"] {
            let button = app.buttons[name].firstMatch
            if canTap(button, in: app) {
                if tap(button), back() { return true }
            }
        }
        return false
    }

    /// Gets to a path: from the tab's own first screen when the app is there, otherwise by starting again.
    private func open(_ path: [Step], fresh: Bool = false) -> Bool {
        guard let first = path.first else { return false }
        if !fresh, app.state == .runningForeground, let root = rootSignatures[first.key] {
            let tab = app.tabBars.buttons[String(first.key.dropFirst(4))]
            if canTap(tab, in: app) {
                var reached = tap(tab)
                if reached, place(settle(timeout: 0.5)) != place(root), canTap(tab, in: app) { reached = tap(tab) }
                if reached, place(settle(timeout: 0.6)) == place(root), replay(path.dropFirst(), from: path, quiet: true) { return true }
            }
        }
        relaunches += 1
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = ["--skip-welcome", "--demo", "--demo-archive", "--pro", "--ui-fast"]
        app.launch()
        guard app.tabBars.firstMatch.waitForExistence(timeout: 20) else {
            XCTFail("The app did not start.")
            return false
        }
        guard replay(path.prefix(1), from: path) else { return false }
        rootSignatures[first.key] = settle(timeout: 2)
        return replay(path.dropFirst(), from: path)
    }

    private func replay(_ steps: ArraySlice<Step>, from path: [Step], quiet: Bool = false) -> Bool {
        for step in steps {
            let before = signature(app)
            guard let element = find(step.key, in: app), reveal(element, in: app) else {
                if !quiet { log("PATH_BROKEN", path, step.key, "could not replay") }
                return false
            }
            guard tap(element) else { return false }
            settle(changedFrom: step.key.hasPrefix("tab:") ? nil : before)
        }
        return true
    }

    /// Taps the navigation bar's Back button, if there is one.
    private func goBack(_ app: XCUIApplication) -> Bool {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        guard canTap(back, in: app), back.frame.minX < 120 else { return false }
        return tap(back)
    }

    /// A tap that something else covers is reported as false instead of ending the crawl.
    private func tap(_ element: XCUIElement) -> Bool {
        var failed = false
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        options.issueMatcher = { _ in
            failed = true
            return true
        }
        XCTExpectFailure("Something covered the element.", options: options) { element.tap() }
        return !failed
    }

    /// iOS permission dialogs belong to the system, not the app, so they need their own check.
    private func dismissSystemPrompt() -> Bool {
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        guard alert.exists else { return false }
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
            if canTap(element, in: app) { return true }
            app.swipeUp(velocity: .fast)
        }
        return canTap(element, in: app)
    }

    /// Asking a closing menu's item whether it can be tapped raises a test error of its own ("activation
    /// point invalid"), which ended the whole crawl. That one question may fail; crashes still fail the test.
    private func canTap(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard element.exists else { return false }
        var hittable = false
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("The element moved away while it was being read.", options: options) {
            let frame = element.frame
            guard !frame.isEmpty, !frame.isInfinite, app.frame.intersects(frame) else { return }
            hittable = element.isHittable
        }
        return hittable
    }

    // MARK: - Reading the screen

    /// Buttons and switches on screen, read from one frozen snapshot so a screen that's still
    /// animating can't make an element vanish halfway through reading it. Skips the tab bar and Back.
    private func candidates(_ app: XCUIApplication) -> [String] {
        guard let root = try? app.snapshot() else { return [] }
        var keys: [String] = []
        func walk(_ node: XCUIElementSnapshot, inTabBar: Bool, inNavBar: Bool) {
            let tab = inTabBar || node.elementType == .tabBar
            let nav = inNavBar || node.elementType == .navigationBar
            if node.elementType == .button || node.elementType == .switch, !tab,
               !(nav && node.frame.minX < 120),
               !(node.label.isEmpty && node.identifier.isEmpty) {
                let key = node.identifier.isEmpty ? "label:\(node.label)" : "id:\(node.identifier)"
                if !keys.contains(key) { keys.append(key) }
            }
            for child in node.children { walk(child, inTabBar: tab, inNavBar: nav) }
        }
        walk(root, inTabBar: false, inNavBar: false)
        return Array(keys.prefix(60))
    }

    private func navTitle(_ app: XCUIApplication) -> String {
        let bar = app.navigationBars.firstMatch
        return bar.exists ? bar.identifier : ""
    }

    private func navTitleFrom(_ signature: String) -> String {
        signature.components(separatedBy: "§").first ?? ""
    }

    private func screenKey(_ app: XCUIApplication) -> String {
        let selectedTab = app.tabBars.buttons.allElementsBoundByIndex.first { $0.isSelected }?.label ?? "?"
        let title = navTitle(app)
        return "\(selectedTab) › \(title.isEmpty ? "(untitled)" : title)"
    }

    /// What's on screen, from one frozen snapshot (texts, buttons, switches and their state).
    private func signature(_ app: XCUIApplication) -> String {
        guard let root = try? app.snapshot() else { return navTitle(app) }
        var parts: [String] = []
        var overlays = 0
        var title: String?
        func walk(_ node: XCUIElementSnapshot) {
            if node.elementType == .navigationBar, title == nil { title = node.identifier }
            if node.elementType == .sheet || node.elementType == .popover { overlays += 1 }
            if [.staticText, .button, .switch].contains(node.elementType), parts.count < 150 {
                parts.append("\(node.elementType.rawValue)|\(node.identifier)|\(node.label)|\(node.isSelected)|\(node.isEnabled)|\(node.value as? String ?? "")")
            }
            node.children.forEach(walk)
        }
        walk(root)
        return ([title ?? "", "\(overlays)"] + parts).joined(separator: "§")
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
