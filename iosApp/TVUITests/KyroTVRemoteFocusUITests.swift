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
            let journal = app.descendants(matching: .any)["harness-journal"]
            if journal.exists {
                let text = XCTAttachment(string: journal.label)
                text.name = "failure-focus-journal"
                issue.add(text)
            }
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
        // The control row's chips and Search field are kept out of the focus graph while focus is
        // here; this capture is for checking they are not dimmed.
        capture("livetv-content-focused-row-undimmed")
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

    // MARK: Settings

    /// The real Settings screen, offline: Down walks the rail one entry at a time, Right enters
    /// the pane of the category it rests on, Left returns to that same category, and Back from
    /// the pane returns to the rail. No server data is needed to reach any of these.
    func testSettingsRailWalksAndPaneEntersAndReturns() {
        let app = launch(.settings)
        XCTAssertTrue(waitFor(app, timeout: 25) { $0 != "<none>" && !$0.hasPrefix("Menu ") }, "Settings takes focus")
        var path = [focusedLabel(app)]
        // Settings opens on General, never on the profile card beside it (hosted run 44934243918).
        XCTAssertTrue(path[0].hasPrefix("General"), "Settings opens on the General rail entry, got \(path[0])")
        for _ in 0..<7 { path.append(press(.down, app, "settings rail down")) }
        log("settings rail down", path)
        XCTAssertGreaterThanOrEqual(Set(path).count, 4, "Down visits distinct rail entries: \(path)")
        assertNeverMenu(path)

        // Walk back up to the entry focus started on (Up past it would reach the top menu).
        var rail = focusedLabel(app)
        for _ in 0..<8 where rail != path[0] { rail = press(.up, app, "settings rail up") }
        XCTAssertEqual(rail, path[0], "Up retraces the rail to where focus started")
        let paneEntry = press(.right, app, "settings into pane")
        log("settings pane", [rail, paneEntry])
        XCTAssertNotEqual(paneEntry, rail, "Right leaves the rail for the pane")
        XCTAssertFalse(paneEntry.hasPrefix("Menu "), "Right does not reach the top menu")
        let back = press(.left, app, "settings back to rail")
        XCTAssertEqual(back, rail, "Left returns to the rail entry the pane belongs to")
        // Left from every one of the pane's first rows returns to the selected category, not the
        // profile card that sits beside the top row.
        var rows = [press(.right, app, "settings pane again")]
        for row in 0..<3 {
            let left = press(.left, app, "settings row \(row) left")
            XCTAssertEqual(left, rail, "Left from pane row \(row) (\(rows.last ?? "")) returns to \(rail), got \(left)")
            rows.append(press(.right, app, "settings row \(row) right"))
            rows.append(press(.down, app, "settings row \(row + 1) down"))
        }
        log("settings pane rows", rows)
        remote.press(.menu)
        settle()
        XCTAssertEqual(focusedLabel(app), rail, "Back from the pane returns to the rail")
    }

    /// Opening a category and backing out, six times over with six different cards (three going
    /// right along the grid, three coming back left): each opening lands on the category's first
    /// channel, Down moves within the channels, Back returns to the card, and Back again to the chip.
    /// The intermittent failure this guards against opened onto a toolbar chip instead.
    func testCategoriesOpenRepeatedlyLandsOnTheFirstChannelEveryTime() {
        let app = launch(.livetv)
        XCTAssertTrue(waitForFocus(app, in: liveTVControls))
        XCTAssertEqual(press(.right, app, "to categories"), "Categories")
        remote.press(.select)
        settle()
        _ = press(.down, app, "into categories")
        var landed = 0
        for round in 1...6 {
            let card = press(round <= 3 ? .right : .left, app, "category card \(round)")
            remote.press(.select)
            settle(2.5)
            let channel = focusedLabel(app)
            log("category round \(round)", [card, channel])
            if channel.hasPrefix("Watch Harness") { landed += 1 }
            XCTAssertTrue(channel.hasPrefix("Watch Harness"), "round \(round): opening \(card) lands on a channel, got \(channel)")
            let down = press(.down, app, "channel down \(round)")
            XCTAssertTrue(down.hasPrefix("Watch Harness"), "round \(round): Down stays within the channels, got \(down)")
            let up = press(.up, app, "channel up \(round)")
            XCTAssertEqual(up, channel, "round \(round): Up returns to the first channel")
            remote.press(.menu)
            settle(1.5)
            XCTAssertEqual(focusedLabel(app), card, "round \(round): Back returns to the card")
        }
        log("category openings landing on a channel", ["\(landed) of 6"])
        remote.press(.menu)
        settle(1.5)
        XCTAssertEqual(focusedLabel(app), "Categories", "Back from the grid returns to the chip")
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

    private func focusedElement(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
    }

    private func focusedValue(_ app: XCUIApplication) -> String {
        (focusedElement(app).value as? String) ?? ""
    }

    /// Settings > General: a selector row opens its option sheet, the remote walks the options,
    /// Select chooses one and focus returns to the row, which shows the new value; Back from the
    /// sheet also returns to the row.
    func testSettingsSelectorOpensChoosesAndReturnsToItsRow() {
        let app = launch(.settings)
        XCTAssertTrue(waitFor(app, timeout: 25) { $0 != "<none>" && !$0.hasPrefix("Menu ") }, "Settings takes focus")
        let pane = press(.right, app, "settings into pane")
        var row = pane
        for _ in 0..<6 where !row.hasPrefix("Profile Selection") { row = press(.down, app, "settings pane down") }
        XCTAssertTrue(row.hasPrefix("Profile Selection"), "Down reaches the Profile Selection row, got \(row)")
        let before = row
        remote.press(.select)
        settle(2)
        capture("settings-selector-open")
        var options = [focusedLabel(app)]
        XCTAssertFalse(options[0].hasPrefix("Profile Selection"), "Select opens the option sheet, focus on \(options[0])")
        options.append(press(.down, app, "selector option down"))
        log("settings selector options", options)
        XCTAssertNotEqual(options[0], options[1], "Down moves between options")
        remote.press(.select)
        settle(2)
        let after = focusedLabel(app)
        log("settings selector chosen", [before, after])
        XCTAssertTrue(after.hasPrefix("Profile Selection"), "Choosing an option returns focus to its row, got \(after)")
        XCTAssertNotEqual(after, before, "The row shows the newly chosen value")
        // Back from an open sheet closes it without changing the row.
        remote.press(.select)
        settle(2)
        remote.press(.menu)
        settle(2)
        XCTAssertEqual(focusedLabel(app), after, "Back from the sheet returns to the same row, unchanged")
    }

    /// Settings > Playback: the rail's Playback entry shows its pane; a one-press On/Off row flips
    /// on Select and flips back. Skipped when no such row exists without server data.
    func testSettingsPlaybackToggleFlipsOnSelect() throws {
        let app = launch(.settings)
        XCTAssertTrue(waitFor(app, timeout: 25) { $0 != "<none>" && !$0.hasPrefix("Menu ") }, "Settings takes focus")
        var rail = focusedLabel(app)
        for _ in 0..<4 where !rail.hasPrefix("Playback") { rail = press(.down, app, "settings rail to playback") }
        XCTAssertTrue(rail.hasPrefix("Playback"), "Down reaches the Playback rail entry, got \(rail)")
        var path = [press(.right, app, "playback pane")]
        var toggle: String?
        for _ in 0..<8 {
            let value = focusedValue(app)
            if value == "On" || value == "Off" { toggle = path.last; break }
            path.append(press(.down, app, "playback pane down"))
        }
        log("settings playback pane", path)
        XCTAssertGreaterThanOrEqual(Set(path).count, 2, "Down walks the Playback pane: \(path)")
        guard let toggle else { throw XCTSkip("BLOCKED: no On/Off row in Playback without server data: \(path)") }
        let was = focusedValue(app)
        remote.press(.select)
        settle(1.5)
        let title = toggle.components(separatedBy: ", ").first ?? toggle
        XCTAssertTrue(focusedLabel(app).hasPrefix(title), "Select keeps focus on the toggle, got \(focusedLabel(app))")
        XCTAssertNotEqual(focusedValue(app), was, "Select flips \(toggle)")
        remote.press(.select)
        settle(1.5)
        XCTAssertEqual(focusedValue(app), was, "Select flips it back")
        remote.press(.left)
        settle(1)
        XCTAssertTrue(focusedLabel(app).hasPrefix("Playback"), "Left returns to the Playback rail entry, got \(focusedLabel(app))")
    }

    // MARK: Search (production SearchView, offline)

    private func searchField(_ app: XCUIApplication) -> XCUIElement { app.searchFields.firstMatch }

    private func searchText(_ app: XCUIApplication) -> String {
        let value = (searchField(app).value as? String) ?? ""
        return value.hasPrefix("Search movies") ? "" : value
    }

    /// The tvOS search screen is a query line, an always-open keyboard, a filter control and the
    /// results. Down from the stand-in menu lands on the keyboard.
    private func reachSearchKeyboard(_ app: XCUIApplication) -> Bool {
        guard app.keyboards.firstMatch.waitForExistence(timeout: 40) || app.keys.firstMatch.waitForExistence(timeout: 5) else {
            return false
        }
        settle(1.5)
        for _ in 0..<5 {
            let label = focusedLabel(app)
            if label == "Keyboard" { return true }
            _ = press(.down, app, "to search keyboard")
        }
        return focusedLabel(app) == "Keyboard"
    }

    /// The real SearchView: Down from navigation reaches the keyboard, the remote moves across keys
    /// and Select types them, and Down/Up/Back keep focus on usable elements.
    func testSearchKeyboardTypesWithTheRemoteAndFocusMovesOutAndBack() {
        let app = launch(.search)
        XCTAssertTrue(reachSearchKeyboard(app), "Down from the menu reaches the keyboard; focus \(focusedLabel(app))")
        capture("search-keyboard-focused")
        XCTAssertEqual(searchText(app), "", "The query starts empty")
        remote.press(.select)
        settle(2)
        let first = searchText(app)
        remote.press(.right)
        settle(0.6)
        remote.press(.select)
        settle(2)
        let second = searchText(app)
        log("search typed", [first, second])
        capture("search-typed")
        XCTAssertEqual(first.count, 1, "Select types the highlighted key, field shows \(first)")
        XCTAssertEqual(second.count, 2, "Right moves to the next key and Select types it, field shows \(second)")
        XCTAssertNotEqual(second.last, second.first, "Right moved the highlight to a different key: \(second)")
        // Down leaves the keyboard for the filters, Up returns, and a further Up leaves it for the menu.
        let filters: Set<String> = ["All", "Movies & TV", "Live TV"]
        let toFilters = press(.down, app, "keyboard down")
        XCTAssertTrue(filters.contains(toFilters), "Down from the keyboard reaches the filters, got \(toFilters)")
        let backToKeyboard = press(.up, app, "filters up")
        XCTAssertEqual(backToKeyboard, "Keyboard", "Up from the filters returns to the keyboard")
        let toMenu = press(.up, app, "keyboard up")
        XCTAssertTrue(toMenu.hasPrefix("Menu "), "Up from the keyboard reaches the navigation controls, got \(toMenu)")
        let intoKeyboard = press(.down, app, "menu down")
        XCTAssertEqual(intoKeyboard, "Keyboard", "Down from the menu re-enters the keyboard")
        log("search keyboard moves", [toFilters, backToKeyboard, toMenu, intoKeyboard])
        // The keyboard still types after the round trip.
        remote.press(.select)
        settle(2)
        XCTAssertEqual(searchText(app).count, 3, "Select still types after leaving and re-entering: \(searchText(app))")
        remote.press(.menu)
        settle(2)
        let afterBack = focusedLabel(app)
        log("search back", [afterBack])
        XCTAssertNotEqual(afterBack, "<none>", "Back from the keyboard leaves focus on a usable element")
    }

    /// A populated search: the fixture channels are the Live TV results. They are reachable below
    /// the keyboard and filters, Select asks Live TV to play the chosen channel, focus stays usable,
    /// and Up retraces to the stand-in menu.
    func testSearchPopulatedResultsAreReachableSelectableAndUpReturnsToNavigation() {
        let app = launch(.search, searchSeed: "Harness")
        XCTAssertTrue(reachSearchKeyboard(app), "keyboard reachable; focus \(focusedLabel(app))")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play Live TV channel'")).firstMatch
            .waitForExistence(timeout: 30), "The fixture channels appear as Live TV results")
        settle(1)
        capture("search-populated")
        var path = [focusedLabel(app)]
        for _ in 0..<8 { path.append(press(.down, app, "search results down")) }
        log("search results down", path)
        XCTAssertFalse(path.contains("<none>"), "Focus is never lost: \(path)")
        let results = path.filter { $0.hasPrefix("Play Live TV channel") }
        XCTAssertGreaterThanOrEqual(Set(results).count, 2, "Down walks several results: \(path)")
        capture("search-result-focused")
        let result = focusedLabel(app)
        XCTAssertTrue(result.hasPrefix("Play Live TV channel"), "Focus rests on a result, got \(result)")
        let name = result.replacingOccurrences(of: "Play Live TV channel ", with: "").components(separatedBy: ", ").first ?? ""
        remote.press(.select)
        settle(3)
        capture("search-result-selected")
        let marker = app.descendants(matching: .any)["harness-playback"]
        XCTAssertTrue(marker.waitForExistence(timeout: 5))
        XCTAssertTrue(marker.label.contains(name), "Select asks Live TV to play \(name), marker: \(marker.label)")
        XCTAssertEqual(focusedLabel(app), result, "Focus stays on the selected result")
        var up = [focusedLabel(app)]
        for _ in 0..<14 where !(up.last ?? "").hasPrefix("Menu ") { up.append(press(.up, app, "search up")) }
        log("search up", up)
        XCTAssertTrue((up.last ?? "").hasPrefix("Menu "), "Up reaches the navigation controls: \(up)")
        XCTAssertNotEqual(press(.down, app, "menu down again"), "<none>", "Navigation still works afterwards")
    }

    /// An empty search has nothing to select; the page stays navigable and focus is never lost.
    func testSearchEmptyResultsStayNavigable() {
        let app = launch(.search, searchSeed: "zzzzqqqq")
        XCTAssertTrue(reachSearchKeyboard(app), "keyboard reachable; focus \(focusedLabel(app))")
        settle(4)
        capture("search-empty")
        var path = [focusedLabel(app)]
        for button in [XCUIRemote.Button.down, .down, .down, .up, .up, .up, .up] { path.append(press(button, app, "search empty")) }
        log("search empty", path)
        XCTAssertFalse(path.contains("<none>"), "Focus is never lost on an empty search: \(path)")
        XCTAssertTrue((path.last ?? "").hasPrefix("Menu ") || path.last == "Keyboard", "Up returns to the keyboard or menu: \(path)")
    }

    // MARK: Production shell (TVMainTabView, offline)

    private func isBarElement(_ label: String) -> Bool {
        label.contains(", tab, ") || label == "Search" || label == "Settings" || label == "Profile"
    }

    private func tabLabels(_ app: XCUIApplication) -> [String] {
        let predicate = NSPredicate(format: "label CONTAINS ', tab, '")
        return app.buttons.matching(predicate).allElementsBoundByIndex.map(\.label)
    }

    private func tabTitle(_ label: String) -> String {
        label.components(separatedBy: ", tab, ").first ?? label
    }

    /// Up from wherever focus is until a bar element holds it.
    private func focusBar(_ app: XCUIApplication, maxPresses: Int = 8) -> String {
        var label = focusedLabel(app)
        var presses = 0
        while !isBarElement(label), presses < maxPresses {
            label = press(.up, app, "to bar")
            presses += 1
        }
        return label
    }

    /// The 1-based position the bar itself reports ("Live TV, tab, 4 of 5" is 4). The order of
    /// accessibility query results is not the bar's order, so positions come from the labels.
    private func tabIndex(_ label: String) -> Int? {
        guard let range = label.range(of: ", tab, "),
              let first = label[range.upperBound...].split(separator: " ").first else { return nil }
        return Int(first)
    }

    /// Moves along the bar to the tab titled `title`, one press at a time, and checks every press:
    /// each Left or Right must land exactly one tab over. Every step is logged (focused tab,
    /// destination, direction pressed, the element focused afterwards, and whether it is in the bar),
    /// so a failure shows whether the helper or the app went wrong.
    private func moveToTab(_ title: String, _ app: XCUIApplication,
                           file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let tabs = tabLabels(app)
        guard let targetLabel = tabs.first(where: { tabTitle($0) == title }), let target = tabIndex(targetLabel) else {
            print("KYRO-FOCUS tabnav: no \(title) tab among \(tabs)")
            return false
        }
        for step in 0..<(tabs.count + 4) {
            let label = focusedLabel(app)
            if tabTitle(label) == title, label.contains(", tab, ") { return true }
            let direction: XCUIRemote.Button
            var expected: Int?
            if let current = tabIndex(label) {
                direction = current < target ? .right : .left
                expected = current + (current < target ? 1 : -1)
            } else if label == "Search" {
                direction = .right
            } else if label == "Settings" || label == "Profile" {
                direction = .left
            } else if label == "<none>" {
                print("KYRO-FOCUS tabnav step \(step): no focus, waiting")
                settle(1)
                continue
            } else {
                direction = .up
            }
            remote.press(direction)
            settle()
            let after = focusedLabel(app)
            print("KYRO-FOCUS tabnav step \(step): at \(label) -> \(title) (\(tabIndex(label).map(String.init) ?? "-")->\(target)) pressed \(direction) -> \(after) inBar=\(isBarElement(after))")
            if let expected, let landed = tabIndex(after) {
                XCTAssertEqual(landed, expected, "\(direction) from \(label) moves one tab, landed on \(after)", file: file, line: line)
            } else if expected != nil, !isBarElement(after) {
                XCTFail("\(direction) from \(label) left the bar for \(after)", file: file, line: line)
            }
        }
        return tabTitle(focusedLabel(app)) == title
    }

    private func launchShell() -> XCUIApplication {
        let app = launch(.shell)
        _ = app.buttons.matching(NSPredicate(format: "label CONTAINS ', tab, '")).firstMatch.waitForExistence(timeout: 45)
        settle(3)
        return app
    }

    /// Every top-level tab is reachable by Right, in order, and Left retraces them.
    func testShellEveryTabIsReachableAcrossTheRealBar() {
        let app = launchShell()
        let tabs = tabLabels(app)
        log("shell tabs", tabs)
        XCTAssertGreaterThanOrEqual(tabs.count, 3, "The real bar lists Home, Live TV and the library tabs: \(tabs)")
        let start = focusBar(app)
        XCTAssertTrue(isBarElement(start), "Up reaches the bar from wherever focus starts, got \(start)")
        XCTAssertTrue(moveToTab(tabTitle(tabs[0]), app), "Left reaches the first tab")
        var seen = [focusedLabel(app)]
        for _ in 0..<(tabs.count + 1) { seen.append(press(.right, app, "shell right")) }
        log("shell right", seen)
        for tab in tabs { XCTAssertTrue(seen.contains(tab), "Right reaches \(tab): \(seen)") }
        var back = [focusedLabel(app)]
        for _ in 0..<(tabs.count + 3) { back.append(press(.left, app, "shell left")) }
        log("shell left", back)
        for tab in tabs { XCTAssertTrue(back.contains(tab), "Left reaches \(tab): \(back)") }
        capture("shell-bar")
    }

    /// Each tab: Select shows it and hands focus to its content, Up (round 1) or Back (round 2)
    /// returns to that same tab, and Down from a Movies/Series tab enters its dropdown, which Back
    /// closes onto the tab. Twice round, so repeated switching is covered.
    func testShellSwitchingTabsEntersContentAndReturnsToTheActiveTab() {
        let app = launchShell()
        let wanted = ["Live TV", "Movies", "Series", "Home", "Sports"]
        let titles = tabLabels(app).map(tabTitle)
        log("shell switch tabs", titles)
        XCTAssertTrue(titles.contains("Live TV"), "Live TV tab exists: \(titles)")
        for round in 1...2 {
            for title in wanted where titles.contains(title) {
                _ = focusBar(app)
                XCTAssertTrue(moveToTab(title, app), "round \(round): reach \(title) tab, at \(focusedLabel(app))")
                remote.press(.select)
                settle(3)
                let inContent = focusedLabel(app)
                capture("shell-\(title)-selected-\(round)")
                log("shell \(title) round \(round) select", [inContent])
                if title == "Live TV" {
                    XCTAssertTrue(liveTVControls.contains(inContent) || inContent.hasPrefix("Watch Harness") || inContent == "Set Up Provider",
                                  "round \(round): Select hands focus to the Live TV page, got \(inContent)")
                }
                if title == "Home", isBarElement(inContent) {
                    // The real Home loads from the server, which this offline shell has not got.
                    print("KYRO-FOCUS BLOCKED Home content: no focusable element offline, focus stayed on \(inContent)")
                    continue
                }
                if title == "Movies" || title == "Series" {
                    // Back from the page, then Down from the tab enters the dropdown; Back closes it.
                    _ = focusBar(app)
                    XCTAssertEqual(tabTitle(focusedLabel(app)), title, "round \(round): Up from \(title) content reaches its own tab, got \(focusedLabel(app))")
                    settle(1.2)
                    let down = press(.down, app, "\(title) dropdown down")
                    capture("shell-\(title)-dropdown-\(round)")
                    XCTAssertFalse(isBarElement(down), "round \(round): Down from the \(title) tab leaves the bar, got \(down)")
                    remote.press(.menu)
                    settle(1.5)
                } else if round == 1 {
                    _ = focusBar(app)
                } else {
                    // Back from a page's top level goes to the bar.
                    for _ in 0..<4 where !isBarElement(focusedLabel(app)) { remote.press(.menu); settle(1.2) }
                }
                let back = focusedLabel(app)
                XCTAssertEqual(tabTitle(back), title, "round \(round): returns to the \(title) tab, got \(back)")
                XCTAssertTrue(back.contains(", tab, "), "round \(round): on a tab, got \(back)")
            }
        }
    }

    /// Closed dropdowns never block neighbouring tabs: Right passes over Movies and Series.
    func testShellClosedDropdownsDoNotBlockOtherTabs() {
        let app = launchShell()
        let titles = tabLabels(app).map(tabTitle)
        guard titles.contains("Movies"), titles.contains("Series") else {
            XCTFail("Movies and Series tabs expected from the seeded libraries: \(titles)"); return
        }
        XCTAssertTrue(isBarElement(focusBar(app)))
        XCTAssertTrue(moveToTab("Movies", app))
        settle(1.2)
        XCTAssertTrue(moveToTab("Series", app), "Right from Movies reaches Series")
        XCTAssertTrue(moveToTab("Live TV", app), "Left reaches Live TV past both dropdown tabs")
        let down = press(.down, app, "live tv under closed dropdowns")
        XCTAssertFalse(isBarElement(down), "Down from Live TV enters the page, got \(down)")
    }

    /// The real Search screen pushed from the real bar: the keyboard types, Down reaches the
    /// filters, Up returns, and Back returns to the bar. Three round trips, because the failure this
    /// guards against was a race (Home's placeholder claiming focus before the bar did), and then
    /// every top-level tab must still be reachable from where Back leaves focus.
    func testShellSearchKeyboardFiltersAndBackReturnToTheBar() {
        let app = launchShell()
        XCTAssertTrue(isBarElement(focusBar(app)))
        for round in 1...3 {
            var label = focusedLabel(app)
            for _ in 0..<12 where label != "Search" { label = press(.left, app, "to search \(round)") }
            XCTAssertEqual(label, "Search", "round \(round): Left reaches Search")
            remote.press(.select)
            XCTAssertTrue(searchField(app).waitForExistence(timeout: 20), "round \(round): Search screen shows")
            XCTAssertTrue(reachSearchKeyboard(app), "round \(round): keyboard reachable; focus \(focusedLabel(app))")
            remote.press(.select)
            settle(2)
            XCTAssertGreaterThanOrEqual(searchText(app).count, 1, "round \(round): Select types a character, got \(searchText(app))")
            if round == 1 { capture("shell-search-typed") }
            let filters: Set<String> = ["All", "Movies & TV", "Live TV"]
            let down = press(.down, app, "shell search filters \(round)")
            XCTAssertTrue(filters.contains(down), "round \(round): Down from the keyboard reaches the filters, got \(down)")
            XCTAssertEqual(press(.up, app, "shell search keyboard \(round)"), "Keyboard", "round \(round): Up returns to the keyboard")
            remote.press(.menu)
            settle(3)
            let after = focusedLabel(app)
            log("shell search back \(round)", [down, after])
            XCTAssertTrue(isBarElement(after), "round \(round): Back from Search returns to the bar, got \(after)")
        }
        for title in ["Sports", "Home", "Live TV"] {
            XCTAssertTrue(moveToTab(title, app), "\(title) is reachable after returning from Search")
        }
    }

    /// BLOCKED, reported as skipped and never as passing: the real shell reads the shared Live TV
    /// service, which cannot reach the in-process fixture host, so the real shell's Search has no
    /// Live TV results to reach. Populated results are covered on the fixture harness page
    /// (testSearchPopulatedResultsAreReachableSelectableAndUpReturnsToNavigation) and Silo results
    /// need a signed-in server.
    func testShellSearchPopulatedResultsAreBlockedWithoutFixtureInjection() throws {
        throw XCTSkip("BLOCKED: real-shell Search has no injectable result source without a signed-in server or a Debug hook in the shared Live TV service")
    }

    /// Rapid presses never strand focus.
    func testShellRapidDirectionalPressesKeepFocus() {
        let app = launchShell()
        XCTAssertTrue(isBarElement(focusBar(app)))
        for _ in 0..<8 { remote.press(.right) }
        settle(2)
        let right = focusedLabel(app)
        for _ in 0..<8 { remote.press(.left) }
        settle(2)
        let left = focusedLabel(app)
        for button in [XCUIRemote.Button.down, .up, .down, .up, .down, .up] { remote.press(button) }
        settle(2.5)
        let end = focusedLabel(app)
        log("shell rapid", [right, left, end])
        XCTAssertNotEqual(right, "<none>")
        XCTAssertNotEqual(left, "<none>")
        XCTAssertNotEqual(end, "<none>", "Focus survives rapid input")
        // After the rapid input, one press at a time still reaches both ends of the bar.
        XCTAssertTrue(isBarElement(focusBar(app)))
        XCTAssertTrue(moveToTab("Home", app), "Home is reachable after rapid input")
        XCTAssertTrue(moveToTab("Sports", app), "Sports is reachable after rapid input")
    }

    /// Search and Settings open from the real bar and Back returns to the bar.
    func testShellSearchAndSettingsOpenFromTheBarAndBackReturns() {
        let app = launchShell()
        XCTAssertTrue(isBarElement(focusBar(app)))
        var label = focusedLabel(app)
        for _ in 0..<12 where label != "Search" { label = press(.left, app, "to search") }
        XCTAssertEqual(label, "Search", "Left reaches the Search button")
        remote.press(.select)
        XCTAssertTrue(searchField(app).waitForExistence(timeout: 20), "Select on Search shows the Search screen")
        settle(2)
        capture("shell-search")
        remote.press(.menu)
        settle(2.5)
        log("shell search back", [focusedLabel(app)])
        XCTAssertTrue(isBarElement(focusedLabel(app)), "Back from Search returns to the bar, got \(focusedLabel(app))")

        var settings = focusedLabel(app)
        for _ in 0..<16 where settings != "Settings" { settings = press(.right, app, "to settings") }
        XCTAssertEqual(settings, "Settings", "Right reaches the Settings button")
        remote.press(.select)
        settle(3)
        capture("shell-settings")
        let inSettings = focusedLabel(app)
        log("shell settings", [inSettings])
        XCTAssertFalse(isBarElement(inSettings) || inSettings == "<none>", "Settings takes focus on its rail, got \(inSettings)")
        remote.press(.menu)
        settle(3)
        XCTAssertNotEqual(focusedLabel(app), "<none>", "Back from Settings leaves usable focus")
    }

    // MARK: Helpers

    private enum Page: String { case livetv, movies, series, sports, settings, search, shell }

    private func launch(_ page: Page, edgeToEdge: Bool = true, dropdowns: Bool = false,
                        ungatedPanels: Bool = false, searchSeed: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-kyroTVFocusHarness", page.rawValue, "-kyro.c3.introduction.completed", "YES"]
        if !edgeToEdge { app.launchArguments.append("-kyroTVFocusHarnessNoEdgeToEdge") }
        if dropdowns { app.launchArguments.append("-kyroTVFocusHarnessDropdowns") }
        if ungatedPanels { app.launchArguments.append("-kyroTVFocusHarnessUngatedPanels") }
        if let searchSeed { app.launchArguments += ["-kyroTVFocusHarnessSearchSeed", searchSeed] }
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
