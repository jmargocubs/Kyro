#if os(tvOS)
import XCTest
@testable import Silo

/// Build 98: the Live TV page's focus topology and Back hierarchy. The view applies these rules as
/// native region defaults and one Back handler; these tests pin the rules themselves. They cannot
/// press a physical Siri Remote, so device acceptance still confirms the engine honours them.
@MainActor
final class KyroTVLiveTVBrowseFocusTests: XCTestCase {
    private let controlRow: [TVLiveTVBrowseFocus] = [
        .section(.channels), .section(.categories), .section(.favorites), .guide, .providers, .search,
    ]

    private func navigation(_ section: TVLiveTVSection, category: String? = nil,
                            focusedCategory: String? = nil) -> TVLiveTVBrowseNavigation {
        var state = TVLiveTVBrowseNavigation()
        state.select(section)
        if let category { state.openCategory(category) }
        if let focusedCategory { state.focusedCategory = focusedCategory }
        return state
    }

    // MARK: Down from every control in the row

    func testDownFromEveryControlEntersTheSameContentTarget() {
        // The destination is a property of the content region, not of the chip pressed, so the
        // left chips (All Channels, Categories, Favorites) behave exactly like TV Guide and Providers.
        let cases: [(TVLiveTVBrowseContent, TVLiveTVBrowseNavigation, TVLiveTVBrowseFocus)] = [
            (.channels(firstID: "news"), navigation(.channels), .channel("news")),
            (.categories(visible: ["News", "Sports"]), navigation(.categories, focusedCategory: "Sports"), .category("Sports")),
            (.categories(visible: ["News"]), navigation(.categories), .category(TVLiveTVBrowseFocusPlanner.allChannelsCardID)),
            (.channels(firstID: "fav"), navigation(.favorites), .channel("fav")),
            (.channels(firstID: nil), navigation(.favorites), .placeholder),
            (.placeholder, navigation(.channels), .placeholder),
            (.action, navigation(.channels), .retry),
        ]
        for (content, state, expected) in cases {
            for control in controlRow {
                XCTAssertTrue(control.isControlRow)
                let target = TVLiveTVBrowseFocusPlanner.contentEntry(content, navigation: state,
                                                                     rememberedChannelID: nil,
                                                                     rememberedChannelIsListed: false)
                XCTAssertEqual(target, expected, "Down from \(control) into \(content)")
                XCTAssertFalse(target.isControlRow, "Down never lands back in the control row")
            }
        }
    }

    func testEmptyFavoritesAndLoadingPagesStillOwnAFocusTarget() {
        XCTAssertEqual(TVLiveTVBrowseFocusPlanner.contentEntry(.channels(firstID: nil), navigation: navigation(.favorites),
                                                               rememberedChannelID: "gone", rememberedChannelIsListed: false),
                       .placeholder)
        XCTAssertEqual(TVLiveTVBrowseFocusPlanner.contentEntry(.placeholder, navigation: navigation(.categories, category: "News"),
                                                               rememberedChannelID: nil, rememberedChannelIsListed: false),
                       .placeholder)
    }

    func testProviderSetupButtonIsReachableWithOneDownFromEveryControl() {
        for _ in controlRow {
            XCTAssertEqual(TVLiveTVBrowseFocusPlanner.contentEntry(.action, navigation: navigation(.channels),
                                                                   rememberedChannelID: nil, rememberedChannelIsListed: false),
                           .retry)
        }
    }

    func testReentryReturnsToTheLastChannelOnlyWhileItIsStillListed() {
        XCTAssertEqual(TVLiveTVBrowseFocusPlanner.contentEntry(.channels(firstID: "a"), navigation: navigation(.channels),
                                                               rememberedChannelID: "c", rememberedChannelIsListed: true),
                       .channel("c"))
        XCTAssertEqual(TVLiveTVBrowseFocusPlanner.contentEntry(.channels(firstID: "a"), navigation: navigation(.channels),
                                                               rememberedChannelID: "c", rememberedChannelIsListed: false),
                       .channel("a"))
    }

    // MARK: Up into the row

    func testUpFromContentReturnsToTheSelectedSectionChip() {
        XCTAssertEqual(TVLiveTVBrowseFocusPlanner.controlEntry(navigation(.channels)), .section(.channels))
        XCTAssertEqual(TVLiveTVBrowseFocusPlanner.controlEntry(navigation(.favorites)), .section(.favorites))
        XCTAssertEqual(TVLiveTVBrowseFocusPlanner.controlEntry(navigation(.categories, category: "News")),
                       .section(.categories), "Category channels sit under Categories, never All Channels")
    }

    // MARK: Back

    func testBackTraversesEveryLevelInReverse() {
        var state = navigation(.categories)
        state.openCategory("NFHS Network")

        // 1. Category channels → category grid, restoring the category it came from.
        XCTAssertEqual(TVLiveTVBrowseFocusPlanner.back(from: .channel("nfhs-1"), navigation: state),
                       .closeCategory("NFHS Network"))
        XCTAssertTrue(state.back())
        XCTAssertEqual(TVLiveTVBrowseFocusPlanner.categoryGridRestoration(pending: "NFHS Network",
                                                                          visible: ["News", "NFHS Network"]),
                       .category("NFHS Network"))

        // 2. Category grid → Live TV controls, on Categories.
        XCTAssertEqual(TVLiveTVBrowseFocusPlanner.back(from: .category("NFHS Network"), navigation: state),
                       .focusControls(.categories))

        // 3. Controls → main navigation, only on this further press.
        XCTAssertEqual(TVLiveTVBrowseFocusPlanner.back(from: .section(.categories), navigation: state), .topMenu)
    }

    func testBackFromAnyContentStopsAtTheControlRowFirst() {
        for section in TVLiveTVSection.allCases {
            let state = navigation(section)
            for content in [TVLiveTVBrowseFocus.channel("x"), .placeholder, .retry, .category("News")] {
                XCTAssertEqual(TVLiveTVBrowseFocusPlanner.back(from: content, navigation: state),
                               .focusControls(section), "Back from \(content) in \(section)")
            }
            for control in controlRow {
                XCTAssertEqual(TVLiveTVBrowseFocusPlanner.back(from: control, navigation: state), .topMenu)
            }
        }
        XCTAssertEqual(TVLiveTVBrowseFocusPlanner.back(from: nil, navigation: navigation(.channels)), .topMenu)
    }

    func testBackFromCategoryChannelsKeepsTheBuild97Behaviour() {
        var state = navigation(.categories)
        state.openCategory("Sports")
        state.scrollAnchor = "News"
        XCTAssertEqual(TVLiveTVBrowseFocusPlanner.back(from: .placeholder, navigation: state), .closeCategory("Sports"))
        XCTAssertTrue(state.back())
        XCTAssertEqual(state.section, .categories)
        XCTAssertNil(state.selectedCategory)
        XCTAssertEqual(state.focusedCategory, "Sports")
        XCTAssertEqual(state.scrollAnchor, "News", "Back keeps the grid's scroll anchor")
    }

    func testRestoredCategoryThatWasHiddenFallsBackToAllChannelsCard() {
        XCTAssertEqual(TVLiveTVBrowseFocusPlanner.categoryGridRestoration(pending: "Gone", visible: ["News"]),
                       .category(TVLiveTVBrowseFocusPlanner.allChannelsCardID))
    }

    // MARK: Category selection (no jump to All Channels)

    func testOpeningACategoryMovesFocusIntoItsChannelsNotAllChannels() {
        var state = navigation(.categories)
        state.openCategory("News")
        XCTAssertEqual(state.section, .categories, "Categories stays the selected chip")
        // While the category loads, the placeholder owns focus; then its first channel does.
        XCTAssertEqual(TVLiveTVBrowseFocusPlanner.afterChannelResults(currentFocus: .placeholder, firstChannelID: "news-1"),
                       .channel("news-1"))
        // An empty category keeps focus on its own placeholder rather than any chip.
        XCTAssertNil(TVLiveTVBrowseFocusPlanner.afterChannelResults(currentFocus: .placeholder, firstChannelID: nil))
        XCTAssertNotEqual(TVLiveTVBrowseFocusPlanner.contentEntry(.placeholder, navigation: state,
                                                                  rememberedChannelID: nil, rememberedChannelIsListed: false),
                          .section(.channels))
        // Up from the category's channels goes to Categories; Back goes to the grid.
        XCTAssertEqual(TVLiveTVBrowseFocusPlanner.controlEntry(state), .section(.categories))
        XCTAssertEqual(TVLiveTVBrowseFocusPlanner.back(from: .channel("news-1"), navigation: state), .closeCategory("News"))
    }

    // MARK: No unsolicited focus changes

    func testResultsNeverPullFocusAfterTheUserMovedAway() {
        for moved in controlRow + [.channel("other"), .category("News")] {
            XCTAssertNil(TVLiveTVBrowseFocusPlanner.afterChannelResults(currentFocus: moved, firstChannelID: "news-1"),
                         "A legitimate move to \(moved) must not be undone")
        }
        XCTAssertNil(TVLiveTVBrowseFocusPlanner.afterChannelResults(currentFocus: nil, firstChannelID: "news-1"))
    }

    func testShowingTheCategoryGridWithoutBackDoesNotStealFocus() {
        XCTAssertNil(TVLiveTVBrowseFocusPlanner.categoryGridRestoration(pending: nil, visible: ["News", "Sports"]),
                     "Selecting the Categories chip leaves focus on the chip")
    }

    func testRepeatedStateUpdatesProduceNoFocusWrites() {
        // Catalog, refresh-progress and favorites updates re-run the planners with the same inputs.
        // None of them is a write; only removal of the focused card or an explicit Back is.
        for _ in 0..<50 {
            XCTAssertNil(TVLiveTVBrowseFocusPlanner.categoryGridRestoration(pending: nil, visible: ["News"]))
            XCTAssertNil(TVLiveTVBrowseFocusPlanner.afterChannelResults(currentFocus: .channel("a"), firstChannelID: "a"))
        }
    }
}
#endif
