import Foundation
import XCTest
@testable import Silo

/// Build 73: the full-page Live TV Categories browser. Covers the one-pass category directory
/// (counts, artwork, favorites), search and empty results, unusual names, provider changes, and
/// the navigation decisions each caller (Home, channel browser, Guide) makes.
final class KyroBuild73CategoriesTests: XCTestCase {
    private func channel(_ id: String, _ category: String, logo: Bool = false) -> LiveTVChannel {
        LiveTVChannel(id: id, guideID: nil, name: id, streamURL: URL(string: "https://example.com/\(id).ts")!,
                      logoURL: logo ? URL(string: "https://example.com/\(id).png") : nil, category: category)
    }

    // MARK: Directory

    func testDirectoryCountsEveryCategoryInProviderOrder() {
        let categories = ["USA | News", "UK | Sports", "Empty"]
        let channels = [channel("a", "UK | Sports"), channel("b", "USA | News"), channel("c", "UK | Sports"),
                        channel("d", "Not Listed")]
        let directory = LiveTVCategoryDirectory.build(categories: categories, channels: channels, favoriteIDs: [])
        XCTAssertEqual(directory.categories, categories)
        XCTAssertEqual(directory.entry(for: "UK | Sports").channelCount, 2)
        XCTAssertEqual(directory.entry(for: "USA | News").channelCount, 1)
        XCTAssertEqual(directory.entry(for: "Empty").channelCount, 0)
        XCTAssertEqual(directory.totalChannelCount, 4)
    }

    func testDirectoryArtworkIsFirstChannelWithALogo() {
        let channels = [channel("a", "Sports"), channel("b", "Sports", logo: true), channel("c", "Sports", logo: true)]
        let directory = LiveTVCategoryDirectory.build(categories: ["Sports", "News"], channels: channels, favoriteIDs: [])
        XCTAssertEqual(directory.entry(for: "Sports").artworkChannel?.id, "b")
        XCTAssertNil(directory.entry(for: "News").artworkChannel)
    }

    func testDirectoryCountsFavoritesAndRanksFrequentOnce() {
        let channels = [channel("a", "News"), channel("b", "Sports"), channel("c", "Sports")]
        let directory = LiveTVCategoryDirectory.build(categories: ["News", "Sports"], channels: channels,
                                                      favoriteIDs: ["a", "missing"])
        XCTAssertEqual(directory.favoriteChannelCount, 1)
        // A favorite outranks a larger category, as in Build 72.
        XCTAssertEqual(directory.frequent.first, "News")
    }

    func testDuplicateProviderCategoriesDoNotCrashAndKeepOneEntry() {
        let directory = LiveTVCategoryDirectory.build(categories: ["News", "News"], channels: [channel("a", "News")],
                                                      favoriteIDs: [])
        XCTAssertEqual(directory.entry(for: "News").channelCount, 1)
    }

    func testProviderChangeDropsRemovedCategories() {
        let before = LiveTVCategoryDirectory.build(categories: ["Old", "Kept"], channels: [channel("a", "Old")],
                                                   favoriteIDs: [])
        let after = LiveTVCategoryDirectory.build(categories: ["Kept", "New"], channels: [channel("b", "New")],
                                                  favoriteIDs: [])
        XCTAssertEqual(before.entry(for: "Old").channelCount, 1)
        XCTAssertEqual(after.categories, ["Kept", "New"])
        XCTAssertEqual(after.entry(for: "Old").channelCount, 0)
        let projection = LiveTVGuideCategoryPickerModel.projection(categories: after.categories, query: "",
                                                                   frequent: after.frequent)
        XCTAssertFalse((projection.frequent + projection.remaining).contains("Old"))
    }

    // MARK: Search and identities

    func testSearchHidesFrequentAndFindsSpecialCharacters() {
        let categories = ["USA | NCAA MEN's BASKETBALL (Alt) ⚽️", "España | Copa del Rey Replay", "DE | Sky Sports+"]
        let projection = LiveTVGuideCategoryPickerModel.projection(categories: categories, query: "espana",
                                                                   frequent: [categories[0]])
        XCTAssertEqual(projection.frequent, [])
        // Case- and diacritic-tolerant matching is not promised; the exact accented text matches.
        let accented = LiveTVGuideCategoryPickerModel.projection(categories: categories, query: "España",
                                                                 frequent: [])
        XCTAssertEqual(accented.remaining, ["España | Copa del Rey Replay"])
        let plus = LiveTVGuideCategoryPickerModel.projection(categories: categories, query: "sports+", frequent: [])
        XCTAssertEqual(plus.remaining, ["DE | Sky Sports+"])
        let apostrophe = LiveTVGuideCategoryPickerModel.projection(categories: categories, query: "men's", frequent: [])
        XCTAssertEqual(apostrophe.remaining.count, 1)
    }

    func testSearchWithNoMatchesIsEmpty() {
        let projection = LiveTVGuideCategoryPickerModel.projection(categories: ["News"], query: "zzz", frequent: [])
        XCTAssertTrue(projection.frequent.isEmpty && projection.remaining.isEmpty)
    }

    func testRowIdentitiesAreUniqueAndStable() {
        let categories = (0..<300).map { "Category \($0)" }
        let frequent = Array(categories.prefix(4))
        let first = LiveTVGuideCategoryPickerModel.projection(categories: categories, query: "", frequent: frequent)
        let second = LiveTVGuideCategoryPickerModel.projection(categories: categories, query: "", frequent: frequent)
        let ids = (first.frequent + first.remaining).map(LiveTVGuideCategoryPickerID.category)
        XCTAssertEqual(Set(ids).count, categories.count)
        XCTAssertEqual(first, second)
        XCTAssertFalse(ids.contains(.allCategories))
    }

    // MARK: Fallback icon

    func testFallbackLetterUsesNameAfterRegionPrefix() {
        XCTAssertEqual(LiveTVCategoryFallbackIcon.letter(for: "UK | Amazon Prime Channels"), "A")
        XCTAssertEqual(LiveTVCategoryFallbackIcon.letter(for: "fight club"), "F")
        XCTAssertEqual(LiveTVCategoryFallbackIcon.letter(for: "USA | 🏈"), "U")
        XCTAssertEqual(LiveTVCategoryFallbackIcon.letter(for: "★ ★"), "#")
        XCTAssertEqual(LiveTVCategoryFallbackIcon.letter(for: ""), "#")
    }

    func testFallbackHueIsStableAndInRange() {
        let hue = LiveTVCategoryFallbackIcon.hue(for: "Live | F1 TV")
        XCTAssertEqual(hue, LiveTVCategoryFallbackIcon.hue(for: "Live | F1 TV"))
        XCTAssertTrue((0..<1).contains(hue))
    }

    // MARK: Navigation

    func testHomeChoicesBecomeBrowserFilters() {
        XCTAssertEqual(LiveTVCategoryNavigation.homeFilters(for: .category("USA | News")), .category("USA | News"))
        XCTAssertEqual(LiveTVCategoryNavigation.homeFilters(for: .all), .channels)
        XCTAssertEqual(LiveTVCategoryNavigation.homeFilters(for: .favorites), .favorites)
    }

    /// Home → Categories → Channels → Back: the Categories page owns the pushed browser, so popping
    /// it lands on Categories; Home's own destination never pushes a second browser.
    func testOnlyOneDestinationOwnsThePushedBrowser() {
        for showingCategories in [false, true] {
            let owners = [false, true].filter {
                LiveTVCategoryNavigation.ownsPushedBrowser(fromCategories: $0, isBrowserPushed: true,
                                                           openedFromCategories: showingCategories)
            }
            XCTAssertEqual(owners, [showingCategories])
        }
        XCTAssertFalse(LiveTVCategoryNavigation.ownsPushedBrowser(fromCategories: true, isBrowserPushed: false,
                                                                  openedFromCategories: true))
    }

    func testNestedCategorySelectionKeepsItsParentAndOnlyOwnerHandlesBack() {
        let filters = LiveTVCategoryNavigation.homeFilters(for: .category("Sports"))
        XCTAssertEqual(filters.category, "Sports")
        XCTAssertTrue(LiveTVCategoryNavigation.ownsPushedBrowser(
            fromCategories: true, isBrowserPushed: true, openedFromCategories: true))
        XCTAssertFalse(LiveTVCategoryNavigation.shouldHandleBrowserPop(
            fromCategories: false, openedFromCategories: true,
            showingBrowser: true, stackShowsBrowser: false))
        XCTAssertFalse(LiveTVCategoryNavigation.shouldDismissCategories(
            showingCategories: true, browserPushedFromCategories: true))
        XCTAssertTrue(LiveTVCategoryNavigation.shouldHandleBrowserPop(
            fromCategories: true, openedFromCategories: true,
            showingBrowser: true, stackShowsBrowser: false))
        XCTAssertTrue(LiveTVCategoryNavigation.shouldDismissCategories(
            showingCategories: true, browserPushedFromCategories: false))
    }

    func testRepeatedSelectionsDoNotMakeTwoBrowserOwners() {
        for category in ["News", "Sports", "Empty", "News"] {
            XCTAssertEqual(LiveTVCategoryNavigation.homeFilters(for: .category(category)).category, category)
            let owners = [false, true].filter {
                LiveTVCategoryNavigation.ownsPushedBrowser(
                    fromCategories: $0, isBrowserPushed: true, openedFromCategories: true)
            }
            XCTAssertEqual(owners, [true])
        }
    }

    func testCategoriesStaysUnderThePushedBrowserInTabs() {
        XCTAssertFalse(LiveTVCategoryNavigation.popsCategoriesOnChoice(isTabRoot: true))
        XCTAssertTrue(LiveTVCategoryNavigation.popsCategoriesOnChoice(isTabRoot: false))
    }

    func testFilterChoiceSetsSelection() {
        XCTAssertEqual(LiveTVCategoryNavigation.filterSelection(for: .category("Sports")), "Sports")
        XCTAssertNil(LiveTVCategoryNavigation.filterSelection(for: .all))
    }

    /// The watch screen's Guide keeps Watch and its player: a fixed full-height page, never a push
    /// into the tab under the player. The full Guide pushes.
    func testGuidePresentationMatchesItsHost() {
        XCTAssertEqual(LiveTVCategoryNavigation.guidePresentation(isWatchGuide: true), .fullHeightSheet)
        XCTAssertEqual(LiveTVCategoryNavigation.guidePresentation(isWatchGuide: false), .push)
    }

    /// Home, browser and Guide each keep their own remembered row; cancelling (no remember call
    /// with a new row) leaves another caller's state alone.
    func testCallersKeepIndependentPositions() {
        let provider = UUID()
        let categories = ["A", "B", "C"]
        var home = LiveTVGuideCategoryPickerState()
        var guide = LiveTVGuideCategoryPickerState()
        home.remember(.category("C"), providerID: provider, categories: categories)
        XCTAssertEqual(home.target(providerID: provider, selectedCategory: nil, categories: categories), .category("C"))
        XCTAssertEqual(guide.target(providerID: provider, selectedCategory: "B", categories: categories), .category("B"))
        guide.reconcile(providerID: provider, categories: categories)
        XCTAssertEqual(home.target(providerID: provider, selectedCategory: nil, categories: ["A"]), .allCategories)
    }

    // MARK: Performance

    /// Data preparation runs once per page open or catalog change, separately from scrolling.
    func testDirectoryBuildIsFastForLargeCatalogs() {
        let categories = (0..<600).map { "Region \($0 % 12) | Category \($0)" }
        let channels = (0..<40_000).map { channel("ch\($0)", categories[$0 % categories.count], logo: $0 % 3 == 0) }
        let favorites = Set((0..<200).map { "ch\($0 * 7)" })
        let start = ProcessInfo.processInfo.systemUptime
        let directory = LiveTVCategoryDirectory.build(categories: categories, channels: channels, favoriteIDs: favorites)
        let buildMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
        let projStart = ProcessInfo.processInfo.systemUptime
        for query in ["", "R", "Region 3", "Category 59", "zzz"] {
            _ = LiveTVGuideCategoryPickerModel.projection(categories: categories, query: query,
                                                          frequent: directory.frequent)
        }
        let projectionMS = (ProcessInfo.processInfo.systemUptime - projStart) * 1000 / 5
        print("Build 73 category directory: build \(String(format: "%.1f", buildMS)) ms, "
              + "projection \(String(format: "%.2f", projectionMS)) ms/query (600 categories, 40k channels)")
        XCTAssertEqual(directory.entry(for: categories[0]).channelCount, 40_000 / 600 + 1)
        XCTAssertLessThan(buildMS, 500, "unoptimized host build; device Release is far faster")
        XCTAssertLessThan(projectionMS, 50)
    }
}
