import XCTest

/// Build 100: real Siri Remote focus transitions on the hosted Apple TV simulator.
///
/// Each test launches the Debug-only focus harness (`-kyroTVFocusHarness`), which shows a real
/// tvOS root page over offline fixtures under a stand-in top menu, then presses directions with
/// `XCUIRemote` and reads which element holds focus. Every press and the element it landed on is
/// printed as a `KYRO-FOCUS` line, so a failing run shows the exact path focus took.
///
/// The simulator's focus engine is the same engine the device runs, but the simulator does not
/// reproduce touch-surface swipes, so passing here does not prove physical Siri Remote behaviour.
final class KyroTVRemoteFocusUITests: XCTestCase {
    private let remote = XCUIRemote.shared
    private let liveTVControls = ["All Channels", "Categories", "Favorites", "TV Guide", "Providers"]

    override func setUp() {
        continueAfterFailure = true
    }

    // MARK: Live TV

    func testLiveTVControlRowMovesOneControlAtATimeInBothDirections() {
        let app = launch(.livetv)
        XCTAssertTrue(waitForFocus(app, in: liveTVControls), "Live TV starts on its control row")
        let start = focusedLabel(app)
        XCTAssertEqual(start, "All Channels")

        var path = [start]
        for _ in 0..<5 { path.append(press(.right, app, "livetv right")) }
        log("livetv control row right", path)
        XCTAssertEqual(Array(path.prefix(5)), liveTVControls, "Right visits each control in order")
        XCTAssertTrue(path[5].localizedCaseInsensitiveContains("search"), "Right reaches channel search, got \(path[5])")

        var back = [path[5]]
        for _ in 0..<5 { back.append(press(.left, app, "livetv left")) }
        log("livetv control row left", back)
        XCTAssertEqual(Array(back.suffix(5)), liveTVControls.reversed(), "Left retraces the row")
        assertNeverMenu(path + back)
    }

    /// Evidence for the Build 99 investigation: the same walk with `tvEdgeToEdgeScroll` disabled.
    /// Recorded, not asserted, so the run reports both paths side by side.
    func testLiveTVControlRowWithoutEdgeToEdgeGeometryForComparison() {
        let app = launch(.livetv, edgeToEdge: false)
        _ = waitForFocus(app, in: liveTVControls)
        var path = [focusedLabel(app)]
        for _ in 0..<5 { path.append(press(.right, app, "livetv-noedge right")) }
        for _ in 0..<5 { path.append(press(.left, app, "livetv-noedge left")) }
        log("livetv control row without edge-to-edge", path)
    }

    func testLiveTVDownEntersChannelsAndUpReturnsToTheSelectedChip() {
        let app = launch(.livetv)
        XCTAssertTrue(waitForFocus(app, in: liveTVControls))
        XCTAssertTrue(waitForChannels(app), "fixture channels loaded")
        capture("livetv-channels")
        let first = press(.down, app, "livetv down")
        XCTAssertTrue(first.hasPrefix("Watch Harness"), "Down enters the channel grid, got \(first)")
        let right = press(.right, app, "livetv grid right")
        XCTAssertTrue(right.hasPrefix("Watch Harness"), "Right stays in the grid, got \(right)")
        XCTAssertNotEqual(right, first)
        let up = press(.up, app, "livetv grid up")
        XCTAssertEqual(up, "All Channels", "Up returns to the selected section chip")
        let menu = press(.up, app, "livetv row up")
        XCTAssertEqual(menu, "Menu Live TV", "Up from the row is the one boundary to the top menu")
        let down = press(.down, app, "menu down")
        XCTAssertTrue(liveTVControls.contains(down) || down.hasPrefix("Watch Harness"),
                      "Down from the menu re-enters the page, got \(down)")
    }

    func testLiveTVScrollingDownAndBackUpRestoresTheSameCard() {
        let app = launch(.livetv)
        XCTAssertTrue(waitForFocus(app, in: liveTVControls))
        XCTAssertTrue(waitForChannels(app))
        let first = press(.down, app, "scroll down")
        var path = [first]
        for _ in 0..<5 { path.append(press(.down, app, "scroll down")) }
        for _ in 0..<5 { path.append(press(.up, app, "scroll up")) }
        log("livetv scroll down/up", path)
        XCTAssertEqual(Set(path).count, 6, "each Down reached a new row")
        XCTAssertEqual(path.last, first, "Up retraces to the first card")
        assertNeverMenu(path)
    }

    func testCategoriesOpenAndBackRestoresTheCategoryCard() {
        let app = launch(.livetv)
        XCTAssertTrue(waitForFocus(app, in: liveTVControls))
        XCTAssertEqual(press(.right, app, "to categories"), "Categories")
        remote.press(.select)
        settle()
        capture("livetv-categories")
        let firstCard = press(.down, app, "into categories")
        XCTAssertFalse(liveTVControls.contains(firstCard), "Down enters the category grid, got \(firstCard)")
        let card = press(.right, app, "category right")
        XCTAssertNotEqual(card, firstCard)
        remote.press(.select)
        settle(2)
        let channel = focusedLabel(app)
        log("category opened", [card, channel])
        XCTAssertTrue(channel.hasPrefix("Watch Harness"), "opening a category focuses its first channel, got \(channel)")
        remote.press(.menu)
        settle()
        XCTAssertEqual(focusedLabel(app), card, "Back returns to the category card it opened")
        remote.press(.menu)
        settle()
        XCTAssertEqual(focusedLabel(app), "Categories", "Back again returns to the selected chip")
    }

    func testGuideOpensOnItsToolbarAndEntersChannelsBeforePrograms() {
        let app = launch(.livetv)
        XCTAssertTrue(waitForFocus(app, in: liveTVControls))
        XCTAssertTrue(waitForChannels(app))
        for _ in 0..<3 { _ = press(.right, app, "to guide") }
        XCTAssertEqual(focusedLabel(app), "TV Guide")
        remote.press(.select)
        settle(2)
        capture("guide-open")
        let header = focusedLabel(app)
        let channel = press(.down, app, "guide down")
        let program = press(.right, app, "guide right")
        for _ in 0..<12 { _ = press(.down, app, "guide scroll") }
        capture("guide-scrolled")
        log("guide", [header, channel, program])
        XCTAssertNotEqual(channel, header, "Down leaves the guide toolbar")
        XCTAssertNotEqual(program, channel, "Right moves from the channel tile into its listings")
        remote.press(.menu)
        settle()
        let afterBack = focusedLabel(app)
        XCTAssertFalse(afterBack.hasPrefix("Watch Harness"), "Back from listings returns to the toolbar, got \(afterBack)")
        assertNeverMenu([header, channel, program, afterBack])
    }

    // MARK: Movies (IPTV VOD)

    func testMoviesGridMovesCardByCardAndUpReachesTheControls() {
        let app = launch(.movies)
        XCTAssertTrue(waitFor(app, timeout: 20) { $0.hasPrefix("Harness Movie") }, "Movies enters on its first card")
        capture("movies")
        let first = focusedLabel(app)
        var path = [first]
        for _ in 0..<3 { path.append(press(.right, app, "movies right")) }
        path.append(press(.down, app, "movies down"))
        path.append(press(.left, app, "movies left"))
        log("movies grid", path)
        XCTAssertTrue(path.allSatisfy { $0.hasPrefix("Harness Movie") }, "grid moves stay on cards")
        XCTAssertEqual(Set(path).count, path.count, "every press moved to a new card")
        let up1 = press(.up, app, "movies up")
        let up2 = press(.up, app, "movies up")
        log("movies up", [up1, up2])
        XCTAssertTrue(up2.contains("All Titles") || up2.localizedCaseInsensitiveContains("search")
                      || up2 == "Refresh Catalog" || up2 == "Continue Watching" || up2 == "Favorites",
                      "Up from the first row reaches the controls, got \(up2)")
        let controls = [press(.right, app, "movies controls right"), press(.right, app, "movies controls right")]
        log("movies controls", controls)
        assertNeverMenu(path + [up1, up2] + controls)
    }

    func testMoviesMenuRoundTripAndModeSwitchKeepFocusOnThePage() {
        let app = launch(.movies)
        XCTAssertTrue(waitFor(app, timeout: 20) { $0.hasPrefix("Harness Movie") })
        let controls = press(.up, app, "movies to controls")
        XCTAssertFalse(controls.hasPrefix("Harness Movie"), "Up from the first row reaches the controls, got \(controls)")
        var path = [controls]
        // Walk the control row to Continue Watching, open it (empty), then come back to All Titles.
        for _ in 0..<4 where focusedLabel(app) != "Continue Watching" { path.append(press(.right, app, "movies controls right")) }
        XCTAssertEqual(focusedLabel(app), "Continue Watching")
        remote.press(.select)
        settle(1.5)
        path.append(focusedLabel(app))
        path.append(press(.left, app, "movies controls left"))
        XCTAssertEqual(path.last, "All Titles", "Left moves to the neighbouring mode")
        remote.press(.select)
        settle(1.5)
        path.append(press(.down, app, "movies back to grid"))
        XCTAssertTrue(path.last?.hasPrefix("Harness Movie") == true, "Down returns to the catalog grid, got \(path.last ?? "")")
        let menu = upUntilMenu(app, path: &path)
        XCTAssertEqual(menu, "Menu Live TV", "Up from the control row reaches the top menu")
        path.append(press(.down, app, "movies menu down"))
        log("movies menu/mode", path)
        XCTAssertFalse(path.last?.hasPrefix("Menu ") ?? true, "Down from the menu re-enters the page")
        assertNeverMenu(Array(path.dropLast(2)))
    }

    // MARK: Sports

    func testSportsCategoryRowStillMovesOneChipAtATime() {
        let app = launch(.sports)
        XCTAssertTrue(waitFor(app, timeout: 20) { !$0.isEmpty && $0 != "<none>" }, "Sports takes focus")
        var path = [focusedLabel(app)]
        for _ in 0..<4 { path.append(press(.right, app, "sports right")) }
        log("sports", path)
        XCTAssertEqual(Set(path).count, path.count, "each Right reached a new control")
        assertNeverMenu(path)
    }

    // MARK: Helpers

    private enum Page: String { case livetv, movies, sports }

    private func launch(_ page: Page, edgeToEdge: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-kyroTVFocusHarness", page.rawValue, "-kyro.c3.introduction.completed", "YES"]
        if !edgeToEdge { app.launchArguments.append("-kyroTVFocusHarnessNoEdgeToEdge") }
        app.launch()
        return app
    }

    private func focusedLabel(_ app: XCUIApplication) -> String {
        let element = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
        guard element.exists else { return "<none>" }
        return element.label.isEmpty ? element.identifier : element.label
    }

    private func press(_ button: XCUIRemote.Button, _ app: XCUIApplication, _ note: String) -> String {
        remote.press(button)
        settle()
        let label = focusedLabel(app)
        print("KYRO-FOCUS \(note): \(label)")
        return label
    }

    private func settle(_ seconds: TimeInterval = 0.8) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func waitFor(_ app: XCUIApplication, timeout: TimeInterval, _ predicate: (String) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(focusedLabel(app)) { return true }
            settle(0.5)
        }
        print("KYRO-FOCUS wait timed out on: \(focusedLabel(app))")
        return false
    }

    private func waitForFocus(_ app: XCUIApplication, in labels: [String]) -> Bool {
        waitFor(app, timeout: 25) { labels.contains($0) }
    }

    private func waitForChannels(_ app: XCUIApplication) -> Bool {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Watch Harness'")).firstMatch
            .waitForExistence(timeout: 20)
    }

    private func upUntilMenu(_ app: XCUIApplication, path: inout [String]) -> String {
        for _ in 0..<4 {
            let label = press(.up, app, "up to menu")
            path.append(label)
            if label.hasPrefix("Menu ") { return label }
        }
        return path.last ?? "<none>"
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func assertNeverMenu(_ labels: [String], file: StaticString = #filePath, line: UInt = #line) {
        let menu = labels.filter { $0.hasPrefix("Menu ") }
        XCTAssertTrue(menu.isEmpty, "focus jumped to the top menu: \(labels)", file: file, line: line)
    }

    private func log(_ name: String, _ path: [String]) {
        print("KYRO-FOCUS \(name): \(path.joined(separator: " → "))")
    }
}
