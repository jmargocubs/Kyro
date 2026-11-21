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
    private var currentApp: XCUIApplication?
    private let liveTVControls = ["All Channels", "Categories", "Favorites", "TV Guide", "Providers"]
    private let sportsCategories = ["All", "NFL", "NCAA", "NBA", "NHL", "MLB", "SOC", "ATP", "WTA"]
    private let sportsModes = ["Live", "Upcoming", "Recent"]
    private let moviesControls = ["Search movies", "All Titles", "Continue Watching", "Favorites", "Refresh Catalog"]

    override func setUp() {
        continueAfterFailure = true
    }

    /// Every failure carries the screen and the app's accessibility tree at that moment.
    override func record(_ issue: XCTIssue) {
        var issue = issue
        if let app = currentApp {
            let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screen.name = "failure-screen"
            issue.add(screen)
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "failure-accessibility-tree"
            issue.add(tree)
        }
        super.record(issue)
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

    /// Navigation recovery: the shell keeps its dropdowns mounted over the page. Closed ones must
    /// not take part in focus, or the row beneath them loses Right. Walks the row both ways, then
    /// repeats the reported device path: select Categories, then Right to every later control.
    func testLiveTVControlRowTraversesUnderClosedDropdowns() {
        let app = launch(.livetv, dropdowns: true)
        XCTAssertTrue(waitForFocus(app, in: liveTVControls), "Live TV starts on its control row")
        var path = [focusedLabel(app)]
        for _ in 0..<5 { path.append(press(.right, app, "dropdowns right")) }
        log("livetv under dropdowns right", path)
        XCTAssertEqual(Array(path.prefix(5)), liveTVControls, "Right visits each control under closed dropdowns")
        var back = [path.last ?? ""]
        for _ in 0..<5 { back.append(press(.left, app, "dropdowns left")) }
        log("livetv under dropdowns left", back)
        XCTAssertEqual(Array(back.suffix(5)), liveTVControls.reversed(), "Left retraces the row")

        XCTAssertEqual(press(.right, app, "to categories"), "Categories")
        remote.press(.select)
        settle()
        let afterCategories = (0..<3).map { _ in press(.right, app, "from selected categories right") }
        log("livetv right from selected categories", afterCategories)
        XCTAssertEqual(afterCategories, ["Favorites", "TV Guide", "Providers"],
                       "Right leaves a selected Categories chip")
        assertNeverMenu(path + back + afterCategories)
    }

    /// The pre-refactor shell kept closed dropdowns in the focus graph. Recorded, not asserted,
    /// so a run shows whether the simulator's engine reproduces the device's stuck Right.
    func testLiveTVControlRowUnderUngatedDropdownsForComparison() {
        let app = launch(.livetv, dropdowns: true, ungatedPanels: true)
        guard waitForFocus(app, in: liveTVControls) else { return }
        var path = [focusedLabel(app)]
        for _ in 0..<5 { path.append(press(.right, app, "ungated right")) }
        log("livetv under ungated dropdowns right", path)
    }

    /// Movies tab → Down enters the dropdown at once (no dwell wait), Right opens the sections,
    /// and Browse, Collections and the IPTV provider are each selectable. Entry and exit repeat.
    func testMoviesDropdownEntersOnDownAndReachesEveryChoice() {
        let app = launch(.livetv, dropdowns: true)
        XCTAssertTrue(waitForFocus(app, in: liveTVControls), "Live TV starts on its control row")

        // Browse: tab → Down → Right (Recommended) → Down (Collections) → Down (Browse) → Select.
        XCTAssertTrue(focusMoviesTab(app), "Up then Right reaches Menu Movies")
        XCTAssertTrue(enterDropdown(app, "movies down"), "Down enters the dropdown")
        pressInDropdown(.right, "sections")
        pressInDropdown(.down, "collections")
        pressInDropdown(.down, "browse")
        remote.press(.select)
        XCTAssertTrue(selection(app, "Browse"), "Browse is selectable")

        // Collections.
        XCTAssertTrue(focusMoviesTab(app), "back to Menu Movies")
        XCTAssertTrue(enterDropdown(app, "movies down"), "Down enters the dropdown again")
        pressInDropdown(.right, "sections")
        pressInDropdown(.down, "collections")
        remote.press(.select)
        XCTAssertTrue(selection(app, "Collections"), "Collections is selectable")

        // IPTV provider: the row below the library.
        XCTAssertTrue(focusMoviesTab(app), "back to Menu Movies")
        XCTAssertTrue(enterDropdown(app, "movies down"), "Down enters the dropdown again")
        pressInDropdown(.down, "provider row")
        remote.press(.select)
        XCTAssertTrue(selection(app, "Provider Harness VOD"), "The IPTV provider is selectable")

        // Repeated entry and exit: Up past the first row returns to the tab every time.
        XCTAssertTrue(focusMoviesTab(app), "back to Menu Movies")
        for round in 1...3 {
            XCTAssertTrue(enterDropdown(app, "enter \(round)"), "entry \(round)")
            XCTAssertEqual(press(.up, app, "exit \(round)"), "Menu Movies", "exit \(round) returns to the tab")
        }
        // Back from inside the dropdown also returns to the tab.
        XCTAssertTrue(enterDropdown(app, "enter for back"))
        XCTAssertEqual(press(.menu, app, "back from dropdown"), "Menu Movies")
        // Sideways from the tab is never captured by the dropdown below it.
        XCTAssertEqual(press(.left, app, "tab left"), "Menu Live TV")
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
        recordInitialFocus(app, page: "movies", marker: app.buttons["All Titles"]) {
            $0.hasPrefix("Harness Movie") || self.moviesControls.contains($0)
        }
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
        recordInitialFocus(app, page: "movies", marker: app.buttons["All Titles"]) {
            $0.hasPrefix("Harness Movie") || self.moviesControls.contains($0)
        }
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
        // After a mode switch XCUITest does not report focus on the chip it moved to (Build 100 run
        // 44679136854: the recording shows the ring on All Titles while hasFocus stays false), so
        // prove where Left went by what Select does there. Left onto the search field or no move
        // at all would leave All Titles unselected and fail here.
        remote.press(.left)
        settle()
        remote.press(.select)
        settle(1.5)
        let allTitles = app.buttons["All Titles"]
        let continueWatching = app.buttons["Continue Watching"]
        XCTAssertTrue(waitUntil(5) { allTitles.isSelected },
                      "Left then Select chose All Titles, the neighbouring mode")
        XCTAssertFalse(continueWatching.isSelected, "Continue Watching is no longer selected")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Harness Movie'")).firstMatch
                        .waitForExistence(timeout: 10), "the catalog reappears")
        path.append("All Titles (selected)")
        path.append(press(.down, app, "movies back to grid"))
        XCTAssertTrue(path.last?.hasPrefix("Harness Movie") == true, "Down returns to the catalog grid, got \(path.last ?? "")")
        let menu = upUntilMenu(app, path: &path)
        XCTAssertEqual(menu, "Menu Live TV", "Up from the control row reaches the top menu")
        path.append(press(.down, app, "movies menu down"))
        log("movies menu/mode", path)
        XCTAssertFalse(path.last?.hasPrefix("Menu ") ?? true, "Down from the menu re-enters the page")
        assertNeverMenu(Array(path.dropLast(2)))
    }

    // MARK: Reachability sweep (navigation recovery)

    /// Every Live TV control acts on Select and Back/Up return usable focus: Favorites content,
    /// the Providers screen and its Back, the search field, rapid Lefts, and repeated menu trips.
    func testLiveTVEveryControlActsOnSelectAndBackRestoresIt() {
        let app = launch(.livetv)
        XCTAssertTrue(waitForFocus(app, in: liveTVControls), "Live TV starts on its control row")
        XCTAssertEqual(press(.right, app, "to categories"), "Categories")
        XCTAssertEqual(press(.right, app, "to favorites"), "Favorites")
        remote.press(.select)
        settle()
        let favorites = press(.down, app, "favorites content")
        XCTAssertFalse(liveTVControls.contains(favorites) || favorites == "<none>" || favorites.hasPrefix("Menu "),
                       "Down from Favorites reaches its content (channels or empty state), got \(favorites)")
        XCTAssertEqual(press(.up, app, "favorites up"), "Favorites", "Up returns to the selected chip")

        XCTAssertEqual(press(.right, app, "to guide"), "TV Guide")
        XCTAssertEqual(press(.right, app, "to providers"), "Providers")
        remote.press(.select)
        settle(1.5)
        var providers = [focusedLabel(app)]
        for _ in 0..<3 { providers.append(press(.down, app, "providers down")) }
        log("providers screen", providers)
        XCTAssertFalse(liveTVControls.contains(providers[0]) || providers.contains("<none>"),
                       "Providers opens with focus inside it and stays focusable: \(providers)")
        remote.press(.menu)
        settle(1.5)
        XCTAssertEqual(focusedLabel(app), "Providers", "Back from Providers restores its chip")

        XCTAssertTrue(press(.right, app, "to search").localizedCaseInsensitiveContains("search"),
                      "the channel search field is reachable")
        for _ in 0..<4 { remote.press(.left) }
        settle(1.5)
        XCTAssertEqual(focusedLabel(app), "Categories", "four rapid Lefts move exactly four controls")

        for round in 1...3 {
            XCTAssertEqual(press(.up, app, "menu round \(round)"), "Menu Live TV",
                           "Up from the row lands on the page's own tab (round \(round))")
            let back = press(.down, app, "page round \(round)")
            XCTAssertTrue(liveTVControls.contains(back), "Down from the tab re-enters the row (round \(round)), got \(back)")
        }
    }

    /// IPTV Movies: a poster opens its detail, every detail control is reachable, Favorite acts on
    /// Select, and Back returns to the same poster. Playback needs a real stream: not pressed here.
    func testIPTVMoviesPosterDetailControlsAndBackRestoreTheCard() {
        assertVODDetailRoundTrip(.movies, prefix: "Harness Movie",
                                 controls: ["Back", "Add Favorite", "Play Movie"])
    }

    /// IPTV Series: same round trip. Seasons and episodes come from the provider's series info,
    /// which the offline fixture does not serve, so they are not covered here.
    func testIPTVSeriesPosterDetailControlsAndBackRestoreTheCard() {
        assertVODDetailRoundTrip(.series, prefix: "Harness Series", controls: ["Back", "Add Favorite"])
    }

    /// IPTV Series page: grid card-by-card, Up to its controls, Up to its own tab, Down back in.
    func testIPTVSeriesGridControlsAndMenuAreReachable() {
        let app = launch(.series)
        XCTAssertTrue(waitFor(app, timeout: 25) { $0.hasPrefix("Harness Series") }, "Series grid takes focus")
        var path = [focusedLabel(app)]
        for _ in 0..<3 { path.append(press(.right, app, "series right")) }
        path.append(press(.down, app, "series down"))
        XCTAssertEqual(Set(path).count, path.count, "each press moves to a new card: \(path)")
        let menu = upUntilMenu(app, path: &path, maxPresses: 6)
        XCTAssertEqual(menu, "Menu Live TV", "Up lands on the page's tab, never a neighbour: \(path)")
        let controls = press(.down, app, "series menu down")
        XCTAssertFalse(controls.hasPrefix("Menu ") || controls == "<none>", "Down re-enters the page, got \(controls)")
        var row = [controls]
        for _ in 0..<5 { row.append(press(.right, app, "series controls right")) }
        log("series controls", row)
        XCTAssertTrue(row.contains("Refresh Catalog") || row.contains("Refreshing Catalog"),
                      "the last control in the row is reachable: \(row)")
    }

    private func assertVODDetailRoundTrip(_ page: Page, prefix: String, controls: [String],
                                          file: StaticString = #filePath, line: UInt = #line) {
        let app = launch(page)
        XCTAssertTrue(waitFor(app, timeout: 25) { $0.hasPrefix(prefix) }, "\(prefix) grid takes focus",
                      file: file, line: line)
        let card = press(.right, app, "to second card")
        remote.press(.select)
        settle(1.5)
        var seen = [focusedLabel(app)]
        for button in [XCUIRemote.Button.up, .down, .right, .left, .up, .down] {
            seen.append(press(button, app, "detail sweep"))
        }
        log("\(page.rawValue) detail", seen)
        for control in controls {
            XCTAssertTrue(seen.contains(control) || (control == "Add Favorite" && seen.contains("Remove Favorite")),
                          "\(control) is reachable in the detail: \(seen)", file: file, line: line)
        }
        // Select acts: Favorite toggles and toggles back.
        var label = focusedLabel(app)
        for _ in 0..<3 where !label.hasSuffix("Favorite") { label = press(.down, app, "to favorite") }
        if label.hasSuffix("Favorite") {
            let before = label
            remote.press(.select)
            settle()
            XCTAssertNotEqual(focusedLabel(app), before, "Select on \(before) acts", file: file, line: line)
            remote.press(.select)
            settle()
        }
        remote.press(.menu)
        settle(1.5)
        XCTAssertEqual(focusedLabel(app), card, "Back returns to the poster that opened the detail",
                       file: file, line: line)
    }

    // MARK: Sports

    /// The two Sports chip rows are fixed in code (`KyroSportsCategory.filterOrder` and
    /// `TVSportsMode`), so this walk does not depend on live sports data: only the game cards below
    /// them come from the network, and an empty "No live events" page is normal. Where focus enters
    /// the page does depend on that data, so the test first moves to a known chip, All.
    /// Build 103: the Sports page has no directional handler at all. Up from wherever focus
    /// enters reaches the always-enabled top menu natively, including while a refresh runs.
    func testSportsUpReachesTheTopMenuWithoutAPageHandler() {
        let app = launch(.sports)
        XCTAssertTrue(app.buttons["All"].waitForExistence(timeout: 20), "Sports page is showing")
        XCTAssertTrue(waitFor(app, timeout: 20) { $0 != "<none>" }, "Sports takes focus")
        var path = [focusedLabel(app)]
        let menu = upUntilMenu(app, path: &path, maxPresses: 6)
        log("sports up to menu", path)
        XCTAssertEqual(menu, "Menu Live TV", "Up lands on the menu's selected item, got \(path)")
        path.append(press(.down, app, "sports menu down"))
        XCTAssertFalse(path.last?.hasPrefix("Menu ") ?? true, "Down from the menu re-enters the page")
    }

    func testSportsChipRowsMoveOneChipAtATimeAndStopAtTheirEnds() {
        let app = launch(.sports)
        XCTAssertTrue(app.buttons["All"].waitForExistence(timeout: 20), "Sports page is showing")
        XCTAssertTrue(waitFor(app, timeout: 20) { $0 != "<none>" }, "Sports takes focus")
        var path = [focusedLabel(app)]

        // Known start: Up until focus is on the category row (from a game card, the day row or the
        // mode row), then Left to its first chip.
        for _ in 0..<4 where !sportsCategories.contains(focusedLabel(app)) {
            if focusedLabel(app) == "Refresh" { path.append(press(.down, app, "sports to categories")) }
            else { path.append(press(.up, app, "sports to categories")) }
        }
        XCTAssertTrue(sportsCategories.contains(focusedLabel(app)), "reached the category row, got \(focusedLabel(app))")
        for _ in 0..<sportsCategories.count where focusedLabel(app) != "All" {
            path.append(press(.left, app, "sports to All"))
        }
        XCTAssertEqual(focusedLabel(app), "All", "known start on the first category chip")
        log("sports start", path)

        // Category row: Right visits every chip in order, then stays on the last one.
        var categories = ["All"]
        for _ in 1..<sportsCategories.count { categories.append(press(.right, app, "sports category right")) }
        XCTAssertEqual(categories, sportsCategories, "Right moves to each adjacent category chip")
        XCTAssertEqual(press(.right, app, "sports category right at end"), "WTA", "Right at the last chip stays there")
        var back = ["WTA"]
        for _ in 1..<sportsCategories.count { back.append(press(.left, app, "sports category left")) }
        XCTAssertEqual(back, Array(sportsCategories.reversed()), "Left retraces the category row")

        // Mode row, directly below All.
        XCTAssertEqual(press(.down, app, "sports to modes"), "Live", "Down from All enters the mode row on Live")
        let modes = ["Live", press(.right, app, "sports mode right"), press(.right, app, "sports mode right")]
        XCTAssertEqual(modes, sportsModes, "Right moves to each adjacent mode chip")
        XCTAssertEqual(press(.right, app, "sports mode right at end"), "Recent", "Right at the last mode stays there")
        let modesBack = ["Recent", press(.left, app, "sports mode left"), press(.left, app, "sports mode left")]
        XCTAssertEqual(modesBack, Array(sportsModes.reversed()), "Left retraces the mode row")
        log("sports rows", categories + back + modes + modesBack)
        assertNeverMenu(path + categories + back + modes + modesBack)
    }

    // MARK: Helpers

    private enum Page: String { case livetv, movies, series, sports }

    private func launch(_ page: Page, edgeToEdge: Bool = true, dropdowns: Bool = false,
                        ungatedPanels: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-kyroTVFocusHarness", page.rawValue, "-kyro.c3.introduction.completed", "YES"]
        if !edgeToEdge { app.launchArguments.append("-kyroTVFocusHarnessNoEdgeToEdge") }
        if dropdowns { app.launchArguments.append("-kyroTVFocusHarnessDropdowns") }
        if ungatedPanels { app.launchArguments.append("-kyroTVFocusHarnessUngatedPanels") }
        app.launch()
        currentApp = app
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
        // A page reloading under focus can report no focused element for a moment. Wait up to
        // 2.5 s before recording a real loss of focus.
        var label = focusedLabel(app)
        var waited = 0.0
        while label == "<none>", waited < 2.5 {
            settle(0.5)
            waited += 0.5
            label = focusedLabel(app)
        }
        print("KYRO-FOCUS \(note): \(label)\(waited > 0 ? " (settled after \(waited) s)" : "")")
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

    /// Logs the first element on the harness page that holds focus after it opens, before any
    /// press. The harness cover sits over the app's sign-in screen, whose controls stay in the
    /// accessibility tree, so wait for the page's marker and for focus on one of the page's own
    /// elements; report anything else after 10 s.
    private func recordInitialFocus(_ app: XCUIApplication, page: String, marker: XCUIElement,
                                    onPage: (String) -> Bool) {
        guard marker.waitForExistence(timeout: 20) else {
            print("KYRO-FOCUS \(page) initial focus: page never appeared; focus \(focusedLabel(app))")
            return
        }
        let deadline = Date().addingTimeInterval(10)
        var label = focusedLabel(app)
        while !onPage(label), Date() < deadline {
            settle(0.25)
            label = focusedLabel(app)
        }
        print("KYRO-FOCUS \(page) initial focus: \(onPage(label) ? label : "not on the page after 10 s (\(label))")")
        capture("\(page)-initial-focus")
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            settle(0.25)
        }
        return condition()
    }

    private func upUntilMenu(_ app: XCUIApplication, path: inout [String], maxPresses: Int = 4) -> String {
        for _ in 0..<maxPresses {
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

    /// From anywhere on the Live TV page: Up until the menu, then Right to Movies.
    private func focusMoviesTab(_ app: XCUIApplication) -> Bool {
        var label = focusedLabel(app)
        for _ in 0..<4 where !label.hasPrefix("Menu ") { label = press(.up, app, "to menu") }
        for _ in 0..<3 where label != "Menu Movies" { label = press(.right, app, "to movies tab") }
        return label == "Menu Movies"
    }

    /// XCUITest does not report `hasFocus` on the cascade: it is one composite focus item whose rows
    /// are labels (docs/tvos-focus.md). Entry is proven by what the remote press changed: the bar
    /// became inert (the shell disables it only while a dropdown holds focus), the dropdown is on
    /// screen, and no page or menu element holds focus. Later Select presses prove which row.
    private func enterDropdown(_ app: XCUIApplication, _ note: String) -> Bool {
        remote.press(.down)
        settle()
        let tab = app.buttons["Menu Movies"]
        let cascade = app.otherElements["cascade.movies"].firstMatch
        let deadline = Date().addingTimeInterval(3)
        var entered = false
        while Date() < deadline {
            entered = tab.exists && !tab.isEnabled && cascade.exists && focusedLabel(app) == "<none>"
            if entered { break }
            settle(0.3)
        }
        print("KYRO-FOCUS \(note): \(entered ? "dropdown entered" : "not entered, focus \(focusedLabel(app))")")
        return entered
    }

    private func pressInDropdown(_ button: XCUIRemote.Button, _ note: String) {
        remote.press(button)
        settle(0.6)
        print("KYRO-FOCUS \(note): dropdown highlight moved")
    }

    private func selection(_ app: XCUIApplication, _ value: String) -> Bool {
        let text = app.staticTexts["harness-selection"]
        guard text.waitForExistence(timeout: 5) else { return false }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if text.label == "Harness selection: \(value)" { return true }
            settle(0.3)
        }
        print("KYRO-FOCUS selection was: \(text.label)")
        return false
    }

    private func assertNeverMenu(_ labels: [String], file: StaticString = #filePath, line: UInt = #line) {
        let menu = labels.filter { $0.hasPrefix("Menu ") }
        XCTAssertTrue(menu.isEmpty, "focus jumped to the top menu: \(labels)", file: file, line: line)
    }

    private func log(_ name: String, _ path: [String]) {
        print("KYRO-FOCUS \(name): \(path.joined(separator: " → "))")
    }
}
