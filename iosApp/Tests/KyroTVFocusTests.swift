#if os(tvOS)
import XCTest
@testable import Silo

/// Phase 3A: Siri Remote focus rules for the TV Guide and the Providers screen, and the Kyro
/// focus treatment. These are the rules the views call; the views add only the focus bindings.
@MainActor
final class KyroTVFocusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let rows = ["news", "sports", "movies"]

    func testEnteredDropdownExcludesBackgroundButPreviewDoesNot() {
        XCTAssertFalse(tvPanelDisablesUnderlyingContent(isOpen: false, isEntered: false))
        XCTAssertFalse(tvPanelDisablesUnderlyingContent(isOpen: true, isEntered: false))
        XCTAssertTrue(tvPanelDisablesUnderlyingContent(isOpen: true, isEntered: true))
    }

    func testSingleLibraryDropdownWalksEveryVisibleOptionWithoutEscaping() {
        let pills = TVLibraryPill.allCases
        let ids = [7]
        let recommended = TVCascadeSelection.section(7, .recommended)
        let collections = TVCascadeSelection.section(7, .collections)
        let browse = TVCascadeSelection.section(7, .browse)
        XCTAssertEqual(TVCascadeFocusPlanner.move(from: recommended, direction: .down, libraryIDs: ids, pills: pills, singleLibrary: true), .select(collections))
        XCTAssertEqual(TVCascadeFocusPlanner.move(from: collections, direction: .down, libraryIDs: ids, pills: pills, singleLibrary: true), .select(browse))
        XCTAssertEqual(TVCascadeFocusPlanner.move(from: browse, direction: .up, libraryIDs: ids, pills: pills, singleLibrary: true), .select(collections))
        XCTAssertEqual(TVCascadeFocusPlanner.move(from: browse, direction: .down, libraryIDs: ids, pills: pills, singleLibrary: true), .content)
        XCTAssertEqual(TVCascadeFocusPlanner.move(from: recommended, direction: .up, libraryIDs: ids, pills: pills, singleLibrary: true), .close)
    }

    func testCascadeDirectionalMovesNeverJumpSideways() {
        let ids = [7, 9]
        let pills = TVLibraryPill.allCases
        XCTAssertEqual(TVCascadeFocusPlanner.move(from: .library(7), direction: .right, libraryIDs: ids, pills: pills, singleLibrary: false), .select(.section(7, .recommended)))
        XCTAssertEqual(TVCascadeFocusPlanner.move(from: .section(7, .recommended), direction: .down, libraryIDs: ids, pills: pills, singleLibrary: false), .select(.section(7, .collections)))
        XCTAssertEqual(TVCascadeFocusPlanner.move(from: .section(7, .collections), direction: .left, libraryIDs: ids, pills: pills, singleLibrary: false), .select(.library(7)))
        XCTAssertEqual(TVCascadeFocusPlanner.move(from: .library(7), direction: .down, libraryIDs: ids, pills: pills, singleLibrary: false), .select(.library(9)))
    }

    private func program(_ channel: String, from start: TimeInterval, to end: TimeInterval) -> EPGProgram {
        EPGProgram(channelID: channel, start: now.addingTimeInterval(start), end: now.addingTimeInterval(end), title: "\(channel) \(start)")
    }

    // MARK: Guide: Down from the filters

    func testDownFromFiltersEntersTheRememberedChannelTile() {
        let target = TVLiveTVGuideFocusPlanner.entryTarget(rowIDs: rows, remembered: "sports")
        XCTAssertEqual(target, .channel("sports"))
    }

    func testDownFromFiltersFallsBackToTheFirstChannelWhenNothingIsRemembered() {
        let target = TVLiveTVGuideFocusPlanner.entryTarget(rowIDs: rows, remembered: nil)
        XCTAssertEqual(target, .channel("news"))
    }

    func testRememberedChannelRemovedByAFilterFallsBackToTheFirstRow() {
        let target = TVLiveTVGuideFocusPlanner.entryTarget(rowIDs: ["movies"], remembered: "sports")
        XCTAssertEqual(target, .channel("movies"))
    }

    func testChannelWithoutCurrentListingsLandsOnItsNameTile() {
        let target = TVLiveTVGuideFocusPlanner.entryTarget(rowIDs: rows, remembered: "news")
        XCTAssertEqual(target, .channel("news"), "predictable fallback, never a future cell")
    }

    func testEmptyGuideHasNoEntryTarget() {
        XCTAssertNil(TVLiveTVGuideFocusPlanner.entryTarget(rowIDs: [], remembered: "news"))
    }

    func testIdleToolbarEntryPreferenceExpiresAtTheNextListingBoundary() {
        let programs = [program("news", from: -60, to: 60), program("news", from: 120, to: 600)]
        XCTAssertEqual(TVLiveTVGuideFocusPlanner.nextListingBoundary(in: programs, after: now), now.addingTimeInterval(60))
        XCTAssertEqual(TVLiveTVGuideFocusPlanner.nextListingBoundary(in: programs, after: now.addingTimeInterval(60)), now.addingTimeInterval(120))
        XCTAssertNil(TVLiveTVGuideFocusPlanner.nextListingBoundary(in: [], after: now))
        var history = TVLiveTVGuideFocusHistory()
        history.observe(.program(channelID: "news", programID: "old"))
        XCTAssertEqual(history.gridDefault(entry: .channel("news")), history.grid,
                       "A schedule boundary is not permission to move active focus")
    }

    func testCurrentProgramIsTheOneAiringNowNotTheNextOne() {
        let programs = [program("news", from: -3_600, to: -60), program("news", from: -60, to: 1_740),
                        program("news", from: 1_740, to: 3_600)]
        XCTAssertEqual(TVLiveTVGuideFocusPlanner.currentProgram(in: programs, at: now), programs[1])
        // A gap in the listings has no current program, so focus uses the name-tile fallback.
        XCTAssertNil(TVLiveTVGuideFocusPlanner.currentProgram(in: [program("news", from: 600, to: 1_200)], at: now))
        // The end instant belongs to the next programme.
        XCTAssertEqual(TVLiveTVGuideFocusPlanner.currentProgram(in: programs, at: now.addingTimeInterval(1_740)), programs[2])
    }

    // MARK: Guide: Up, filter changes, restoration

    func testGuideReturnsToTheFilterThatLaunchedIt() {
        for header in [TVLiveTVGuideFocus.back, .category, .favorites, .refresh] {
            var history = TVLiveTVGuideFocusHistory()
            history.observe(header)
            history.observe(.program(channelID: "news", programID: "now"))
            XCTAssertEqual(history.header, header)
            // The toolbar's native region default is available before Up,
            // not a second focus assignment after Back has been highlighted.
            history.observe(history.header)
            XCTAssertFalse(history.isInGrid)
            XCTAssertEqual(history.grid?.channelID, "news")
        }
    }

    func testBackFromDeepGuideReturnsToFiltersAndDownRestoresChannelTile() {
        var history = TVLiveTVGuideFocusHistory()
        history.observe(.favorites)
        for index in 0..<500 {
            history.observe(.program(channelID: "channel-\(index)", programID: "live"))
        }
        XCTAssertTrue(history.returnToHeader())
        XCTAssertEqual(history.header, .favorites)
        XCTAssertEqual(history.gridDefault(entry: .channel("channel-0")), .channel("channel-499"))
        XCTAssertTrue(history.allowsGridEntry(.channel("channel-0"), laidOutRows: ["channel-499"]))
        history.observe(history.header)
        XCTAssertFalse(history.isInGrid)
        let restored = history.gridDefault(entry: .channel("channel-0"))
        history.observe(restored)
        XCTAssertEqual(history.grid, .channel("channel-499"))
    }

    func testBackFromFiltersExitsWhetherOrNotGridWasEntered() {
        var history = TVLiveTVGuideFocusHistory()
        history.observe(.category)
        XCTAssertFalse(history.returnToHeader(), "Back from untouched filters exits Live TV Home")
        history.observe(.channel("news"))
        XCTAssertTrue(history.returnToHeader())
        history.observe(.category)
        XCTAssertFalse(history.returnToHeader(), "The second Back exits; it cannot re-enter the grid")
    }

    func testRepeatedBackPressesDoNotBounceBetweenGridAndFilters() {
        var history = TVLiveTVGuideFocusHistory()
        history.observe(.channel("news"))
        XCTAssertTrue(history.returnToHeader())
        for _ in 0..<10 {
            XCTAssertFalse(history.returnToHeader())
        }
        XCTAssertEqual(history.gridDefault(entry: .channel("sports")), .channel("news"))
    }

    func testPastListingsDoNotCompeteWithLiveAndUpcomingForRightFocus() {
        XCTAssertFalse(TVLiveTVGuideFocusPlanner.canFocusProgram(
            program("news", from: -600, to: -60), at: now, isFocused: false))
        XCTAssertTrue(TVLiveTVGuideFocusPlanner.canFocusProgram(
            program("news", from: -60, to: 600), at: now, isFocused: false))
        XCTAssertTrue(TVLiveTVGuideFocusPlanner.canFocusProgram(
            program("news", from: 600, to: 1_200), at: now, isFocused: false))
        XCTAssertTrue(TVLiveTVGuideFocusPlanner.canFocusProgram(
            program("news", from: -600, to: -60), at: now, isFocused: true),
            "A listing boundary cannot evict the focused program")
    }

    func testGuideCannotEnterAnotherRowWhileItsLazyTargetIsNotLaidOut() {
        var history = TVLiveTVGuideFocusHistory()
        let target = TVLiveTVGuideFocus.program(channelID: "sports", programID: "now")
        XCTAssertFalse(history.allowsGridEntry(target, laidOutRows: ["news"]))
        XCTAssertFalse(history.allowsGridEntry(nil, laidOutRows: ["news"]))
        XCTAssertTrue(history.allowsGridEntry(target, laidOutRows: ["sports"]))
        history.observe(target)
        XCTAssertTrue(history.allowsGridEntry(nil, laidOutRows: []),
                      "Virtualization must not disable the active grid during scrolling")
    }

    func testRapidGuideTransitionsHaveNoQueuedCorrection() {
        var history = TVLiveTVGuideFocusHistory()
        for index in 0..<1_000 {
            let target = TVLiveTVGuideFocus.program(channelID: "news", programID: "\(index)")
            history.observe(.favorites)
            XCTAssertEqual(history.gridDefault(entry: .channel("news")), .channel("news"))
            history.observe(target)
            history.observe(nil)
            XCTAssertEqual(history.gridDefault(entry: .channel("other")), target)
            history.observe(.category)
            XCTAssertEqual(history.gridDefault(entry: .channel("other")), .channel("news"))
        }
    }

    func testPlaybackAndDetailsRestoreTheExactProgramDespiteNewEntryData() {
        var history = TVLiveTVGuideFocusHistory()
        let target = TVLiveTVGuideFocus.program(channelID: "sports", programID: "past-program")
        history.observe(target)
        history.observe(nil) // cover/sheet owns the window
        XCTAssertEqual(history.gridDefault(entry: .program(channelID: "sports", programID: "live")), target)
        XCTAssertTrue(history.isInGrid)
    }

    func testEPGRefreshKeepsActiveRowIdentityAndGeometry() {
        let old = [program("news", from: -60, to: 600)]
        let refreshed = [program("news", from: -30, to: 900)]
        let snapshot = TVLiveTVGuideListingSnapshot(channelID: "news", programs: old)
        XCTAssertEqual(snapshot.programs(for: "news") { refreshed }, old)
        XCTAssertEqual(snapshot.programs(for: "sports") { refreshed }, refreshed)
        let empty = TVLiveTVGuideListingSnapshot(channelID: "news", programs: [])
        XCTAssertTrue(empty.programs(for: "news") { refreshed }.isEmpty,
                      "Loading EPG must not replace a focused no-guide cell")
    }

    func testCategorySwitchDropsRemovedRestorationTargetButKeepsToolbarOrigin() {
        var history = TVLiveTVGuideFocusHistory()
        history.observe(.favorites)
        history.observe(.channel("news"))
        history.reconcile(rowIDs: ["news", "sports"])
        XCTAssertEqual(history.grid, .channel("news"))
        XCTAssertTrue(history.isInGrid)
        history.reconcile(rowIDs: ["sports"])
        XCTAssertNil(history.grid)
        XCTAssertFalse(history.isInGrid)
        XCTAssertEqual(history.header, .favorites)
        XCTAssertEqual(history.gridDefault(entry: .channel("sports")), .channel("sports"))
    }

    func testChangingACategoryNeverMovesFocusOffTheFilters() {
        for header in [TVLiveTVGuideFocus.back, .category, .favorites, .refresh] {
            XCTAssertFalse(TVLiveTVGuideFocusPlanner.mustRelocate(header, rowIDs: []), "\(header)")
            XCTAssertFalse(TVLiveTVGuideFocusPlanner.mustRelocate(header, rowIDs: ["movies"]))
            XCTAssertTrue(header.isHeader)
        }
        XCTAssertFalse(TVLiveTVGuideFocusPlanner.mustRelocate(nil, rowIDs: ["movies"]))
    }

    func testFocusOnARowAFilterRemovedIsRelocatedButAKeptRowIsNot() {
        XCTAssertTrue(TVLiveTVGuideFocusPlanner.mustRelocate(.program(channelID: "sports", programID: "p"), rowIDs: ["news"]))
        XCTAssertFalse(TVLiveTVGuideFocusPlanner.mustRelocate(.program(channelID: "news", programID: "p"), rowIDs: ["news"]))
    }

    func testGuideFocusIdentitiesCarryTheirChannel() {
        XCTAssertEqual(TVLiveTVGuideFocus.program(channelID: "a", programID: "p").channelID, "a")
        XCTAssertEqual(TVLiveTVGuideFocus.noGuide("b").channelID, "b")
        XCTAssertNil(TVLiveTVGuideFocus.refresh.channelID)
    }

    func testReopenedGuideReturnsToTheLastChannel() {
        TVLiveTVGuideMemory.lastChannelID = "movies"
        defer { TVLiveTVGuideMemory.lastChannelID = nil }
        let target = TVLiveTVGuideFocusPlanner.entryTarget(rowIDs: rows, remembered: TVLiveTVGuideMemory.lastChannelID)
        XCTAssertEqual(target?.channelID, "movies")
    }

    func testNavigationStateReconcilesToTheFirstVisibleChannel() {
        var state = TVLiveTVGuideNavigationState()
        state.focus(channelID: "sports")
        state.reconcile(visibleChannelIDs: ["news", "sports"])
        XCTAssertEqual(state.focusedChannelID, "sports")
        state.reconcile(visibleChannelIDs: ["movies"])
        XCTAssertEqual(state.focusedChannelID, "movies")
    }

    // MARK: Providers screen stability

    func testTopProviderRowDoesNotRequestBackWhenMovingUp() {
        let first = UUID(), second = UUID()
        let ids = [first, second]
        for target in [TVLiveTVProviderFocus.provider(first), .refresh(first), .remove(first),
                       .phoneSetup, .addProvider, .hiddenManagement] {
            XCTAssertNil(TVLiveTVProviderFocusPlanner.relocationIfRemoved(target, providerIDs: ids),
                         "Navigation must be native until a row is actually removed")
        }
    }

    func testWithNoProvidersSetUpWithPhoneIsTheTopControlAndTheEntryPoint() {
        XCTAssertEqual(TVLiveTVProviderFocusPlanner.initialFocus(providerIDs: []), .phoneSetup)
        XCTAssertNil(TVLiveTVProviderFocusPlanner.relocationIfRemoved(.phoneSetup, providerIDs: []))
    }

    func testFocusAfterRemovingAProviderLandsOnTheNextOneOrPhoneSetup() {
        let next = UUID()
        XCTAssertEqual(TVLiveTVProviderFocusPlanner.afterRemoval(remainingProviderIDs: [next]), .provider(next))
        XCTAssertEqual(TVLiveTVProviderFocusPlanner.afterRemoval(remainingProviderIDs: []), .phoneSetup)
        XCTAssertEqual(TVLiveTVProviderFocusPlanner.initialFocus(providerIDs: [next]), .provider(next))
    }

    func testProviderStatusAndRefreshUpdatesNeverRequestAnotherFocusTarget() {
        let first = UUID(), second = UUID()
        let ids = [first, second]
        for target in [TVLiveTVProviderFocus.back, .provider(first), .refresh(first),
                       .remove(second), .phoneSetup, .addProvider, .hiddenManagement] {
            for _ in 0..<100 {
                XCTAssertNil(TVLiveTVProviderFocusPlanner.relocationIfRemoved(target, providerIDs: ids))
            }
        }
        XCTAssertNil(TVLiveTVProviderFocusPlanner.relocationIfRemoved(nil, providerIDs: ids),
                     "Sheet presentation may clear FocusState without authorizing a new target")
        XCTAssertEqual(TVLiveTVProviderFocusPlanner.relocationIfRemoved(.refresh(first), providerIDs: [second]),
                       .provider(second))
    }

    func testAddProviderDismissalAndNavigationRestorationAreExplicit() {
        let saved = UUID()
        XCTAssertEqual(TVLiveTVProviderFocusPlanner.afterAddProvider(savedProviderID: nil), .addProvider)
        XCTAssertEqual(TVLiveTVProviderFocusPlanner.afterAddProvider(savedProviderID: saved), .provider(saved))
        let target = TVLiveTVRootView.FocusTarget.channel("news")
        XCTAssertEqual(TVLiveTVRootView.restorationTarget(target, channelIDs: ["news"],
                                                          categories: [], section: .channels), target)
        XCTAssertEqual(TVLiveTVRootView.restorationTarget(target, channelIDs: [],
                                                          categories: [], section: .channels), .section(.channels))
    }

    func testGuideLayoutUsesViewportAndNeverOverlapsAdjacentProgramCells() {
        XCTAssertLessThan(TVLiveTVGuideLayout.horizontalInset(viewportWidth: 1920), 30)
        XCTAssertGreaterThan(TVLiveTVGuideLayout.channelWidth(viewportWidth: 1920), 310)
        XCTAssertGreaterThan(TVLiveTVGuideLayout.rowHeight(viewportHeight: 1080), 112)
        XCTAssertGreaterThan(TVLiveTVGuideLayout.visibleProgramWidth(viewportWidth: 1920), 1400)
        for viewport in [CGFloat(1280), 1920, 3840] {
            let channel = TVLiveTVGuideLayout.channelWidth(viewportWidth: viewport)
            let insets = 2 * TVLiveTVGuideLayout.horizontalInset(viewportWidth: viewport)
            XCTAssertLessThanOrEqual(channel + insets, viewport * 0.38)
            XCTAssertGreaterThan(TVLiveTVGuideLayout.visibleProgramWidth(viewportWidth: viewport), viewport * 0.6)
        }
        for width in [CGFloat(1), 6, 20, 90, 180] {
            let rendered = TVLiveTVGuideLayout.programCellWidth(width)
            XCTAssertGreaterThan(rendered, 0)
            XCTAssertLessThanOrEqual(rendered, width)
        }
    }

    func testRemovingTopProviderKeepsNextRowAsEntryWithoutBackRedirect() {
        let first = UUID(), next = UUID()
        XCTAssertEqual(TVLiveTVProviderFocusPlanner.initialFocus(providerIDs: [first, next]), .provider(first))
        let target = TVLiveTVProviderFocusPlanner.afterRemoval(remainingProviderIDs: [next])
        XCTAssertEqual(target, .provider(next))
        XCTAssertNil(TVLiveTVProviderFocusPlanner.relocationIfRemoved(target, providerIDs: [next]))
    }

    func testCategoryBrowsingIsNestedUnderCategoriesAndBackRestoresOrigin() {
        var state = TVLiveTVBrowseNavigation()
        state.select(.categories)
        state.openCategory("News")
        XCTAssertEqual(state.section, .categories)
        XCTAssertEqual(state.selectedCategory, "News")
        XCTAssertTrue(state.back())
        XCTAssertEqual(state.section, .categories)
        XCTAssertNil(state.selectedCategory)
        XCTAssertEqual(state.focusedCategory, "News")
        state.scrollAnchor = "Earlier Category"
        XCTAssertEqual(state.scrollAnchor, "Earlier Category")
        XCTAssertFalse(state.back(), "Back must not loop into the category grid")
        state.select(.favorites)
        XCTAssertNil(state.selectedCategory)
    }

    func testCategoryNavigationSurvivesTabSwitchSnapshot() {
        var state = TVLiveTVBrowseNavigation()
        state.openCategory("Sports")
        state.scrollAnchor = "News"
        let scope = TVLiveTVVisibilityScope(profileID: "focus-test-\(UUID())", providerID: UUID())
        TVLiveTVBrowseMemory.save(state, for: scope)
        state.select(.channels)
        let restored = TVLiveTVBrowseMemory.restore(for: scope)
        XCTAssertEqual(restored?.section, .categories)
        XCTAssertEqual(restored?.selectedCategory, "Sports")
        XCTAssertEqual(restored?.focusedCategory, "Sports")
        XCTAssertEqual(restored?.scrollAnchor, "News")
        XCTAssertNil(TVLiveTVBrowseMemory.restore(for: .init(profileID: "other", providerID: scope.providerID)))
    }

    func testHidingCategoryPreservesNearbyFocusAndScrollAnchor() {
        var state = TVLiveTVBrowseNavigation()
        state.openCategory("Sports")
        state.scrollAnchor = "Sports"
        XCTAssertEqual(state.hideCategory("Sports", visibleCategories: ["News", "Sports", "Movies"]), "Movies")
        XCTAssertNil(state.selectedCategory)
        XCTAssertEqual(state.section, .categories)
        XCTAssertEqual(state.focusedCategory, "Movies")
        XCTAssertEqual(state.scrollAnchor, "Movies")
    }

    func testNativeLongPressMenusExposeExpectedActionsWithoutChangingShortPress() {
        XCTAssertEqual(TVLiveTVChannelMenuAction.allCases.map { $0.title(isFavorite: false) },
                       ["Watch Channel", "Add to Favorites", "Hide Channel", "Channel Information"])
        XCTAssertEqual(TVLiveTVChannelMenuAction.favorite.title(isFavorite: true), "Remove from Favorites")
        XCTAssertEqual(TVLiveTVCategoryMenuAction.allCases, [.browse, .guide, .hide])
    }

    func testContextMenuAndGuideDismissalRetainOriginatingFocus() {
        let channel = TVLiveTVRootView.FocusTarget.channel("news")
        let category = TVLiveTVRootView.FocusTarget.category("Sports")
        XCTAssertEqual(TVLiveTVRootView.restorationTarget(channel, channelIDs: ["news"],
                                                          categories: ["Sports"], section: .channels), channel)
        XCTAssertEqual(TVLiveTVRootView.restorationTarget(category, channelIDs: [],
                                                          categories: ["Sports"], section: .categories), category)
        XCTAssertEqual(TVLiveTVRootView.restorationTarget(category, channelIDs: [],
                                                          categories: [], section: .categories), .section(.categories))
    }

    func testApprovalCountdownUsesReadableMinuteSecondBoundaries() {
        XCTAssertEqual(TVLiveTVPairingView.clock(300), "5:00")
        XCTAssertEqual(TVLiveTVPairingView.clock(59.1), "1:00")
        XCTAssertEqual(TVLiveTVPairingView.clock(0), "0:00")
        XCTAssertEqual(TVLiveTVPairingView.clock(-1), "0:00")
    }

    // MARK: Build 103: top bar contract

    func testTopBarStaysInTheFocusGraphWhileContentOwnsFocus() {
        // Up from any page's top row must be a native move, for clicks and
        // touch-surface swipes alike, so content focus never disables the bar.
        XCTAssertFalse(tvTopMenuIsInert(panelEntered: false))
        XCTAssertTrue(tvTopMenuIsInert(panelEntered: true), "only an entered panel makes the bar inert")
    }

    func testMenuOwnershipFollowsRealFocusNotAnOptimisticFlag() {
        XCTAssertFalse(tvMenuOwnsFocus(barFocused: false, panelEntered: false),
                       "a page may claim as soon as the bar does not hold focus")
        XCTAssertTrue(tvMenuOwnsFocus(barFocused: true, panelEntered: false))
        XCTAssertTrue(tvMenuOwnsFocus(barFocused: false, panelEntered: true))
    }

    func testVisibleRootsChangeRearmsTheOwnerThatReallyHadFocus() {
        XCTAssertEqual(tvVisibleRootsFocusRearm(menuOwnedFocus: true, isShowingRoot: true, selectedRootWasRemoved: false), .topMenu)
        XCTAssertEqual(tvVisibleRootsFocusRearm(menuOwnedFocus: false, isShowingRoot: true, selectedRootWasRemoved: true), .content)
        XCTAssertEqual(tvVisibleRootsFocusRearm(menuOwnedFocus: false, isShowingRoot: true, selectedRootWasRemoved: false), .none)
        XCTAssertEqual(tvVisibleRootsFocusRearm(menuOwnedFocus: true, isShowingRoot: false, selectedRootWasRemoved: true), .none)
    }

    // MARK: Build 103 review: bar focus loss and ownership (pure policy, not the view)

    func testNativeDownFromATabWithAnOpenPreviewEntersThePanelInsteadOfRepinning() {
        // The review's passive-preview trap: a user's Down was read as a
        // spurious loss and focus was pinned back to the tab.
        XCTAssertEqual(tvTopMenuFocusLoss(movedDown: true, lastElementHasPanel: true, explicitHandOff: false,
                                          previewOpen: true, refocusAfterSidewaysClose: false), .enterPanel)
        XCTAssertEqual(tvTopMenuFocusLoss(movedDown: true, lastElementHasPanel: true, explicitHandOff: false,
                                          previewOpen: false, refocusAfterSidewaysClose: false), .enterPanel,
                       "Down before the dwell still enters the panel, for clicks and swipes alike")
        XCTAssertEqual(tvTopMenuFocusLoss(movedDown: true, lastElementHasPanel: false, explicitHandOff: false,
                                          previewOpen: false, refocusAfterSidewaysClose: false), .handOffToContent)
    }

    func testOverlayPerturbationWithoutAUserMoveStillRepins() {
        XCTAssertEqual(tvTopMenuFocusLoss(movedDown: false, lastElementHasPanel: true, explicitHandOff: false,
                                          previewOpen: true, refocusAfterSidewaysClose: false), .repin)
        XCTAssertEqual(tvTopMenuFocusLoss(movedDown: false, lastElementHasPanel: false, explicitHandOff: false,
                                          previewOpen: false, refocusAfterSidewaysClose: true), .repin)
        XCTAssertEqual(tvTopMenuFocusLoss(movedDown: false, lastElementHasPanel: true, explicitHandOff: true,
                                          previewOpen: true, refocusAfterSidewaysClose: false), .handOffToContent,
                       "a page claim after tab selection is let go, never re-pinned")
    }

    func testSystemArrivalOnTheBarDoesNotTakeMenuOwnership() {
        // Launch, pop to root, panel teardown: the page's claim must still land.
        XCTAssertFalse(tvTopMenuArrivalTakesOwnership(userMoved: false, matchesBarRequest: false))
        XCTAssertTrue(tvTopMenuArrivalTakesOwnership(userMoved: true, matchesBarRequest: false))
        XCTAssertTrue(tvTopMenuArrivalTakesOwnership(userMoved: false, matchesBarRequest: true))
    }

    func testMatchingOrStaleBindingNeverFalselyClaimsOwnership() {
        XCTAssertEqual(tvTopMenuFocusClaim(bindingMatchesTarget: false, barOwnsFocus: false), .claim)
        XCTAssertEqual(tvTopMenuFocusClaim(bindingMatchesTarget: true, barOwnsFocus: true), .alreadyFocused)
        XCTAssertEqual(tvTopMenuFocusClaim(bindingMatchesTarget: true, barOwnsFocus: false), .reclaimStale,
                       "a stale binding is cleared and re-claimed, not reported as owned")
    }

    func testSettingsDetailRestoreIsAbandonedAfterBackToTheRail() {
        XCTAssertTrue(tvSettingsDetailRestoreIsCurrent(scheduled: 3, current: 3))
        XCTAssertFalse(tvSettingsDetailRestoreIsCurrent(scheduled: 3, current: 4))
    }

    // MARK: Build 103: one owner per press

    func testRowEntryRetryNeverPullsFocusBackAfterAMove() {
        func retry(focused: String?, last: String?, owner lost: Bool = false) -> Bool {
            tvMediaRowShouldRetryEntryClaim(generationMatches: true, rowLostOwnership: lost,
                                            targetStillPresent: true, focusedItemId: focused,
                                            lastFocusedItemId: last, targetId: "first")
        }
        XCTAssertTrue(retry(focused: nil, last: "first"), "the claim has not landed yet: retry")
        XCTAssertFalse(retry(focused: "first", last: "first"), "landed: stop")
        XCTAssertFalse(retry(focused: "third", last: "third"), "the user moved Right: never snap back")
        XCTAssertFalse(retry(focused: nil, last: "third"), "a move happened, then focus left: stop")
        XCTAssertFalse(retry(focused: nil, last: "first", owner: true), "focus left the row: stop")
        XCTAssertFalse(tvMediaRowShouldRetryEntryClaim(generationMatches: false, rowLostOwnership: false,
                                                       targetStillPresent: true, focusedItemId: nil,
                                                       lastFocusedItemId: "first", targetId: "first"))
    }

    // MARK: Build 103: Settings

    func testSettingsResetsToGeneralOnlyOnFirstAppearance() {
        XCTAssertTrue(tvSettingsShouldResetFocusOnAppear(hasEnteredBefore: false))
        XCTAssertFalse(tvSettingsShouldResetFocusOnAppear(hasEnteredBefore: true),
                       "Back from the inspector or Manage Servers keeps the user's place")
    }

    func testSettingsRailStaysFocusableWhileEnteringAPane() {
        XCTAssertFalse(tvSettingsRailIsInert(isModalPresented: false, isRestoringPickerRow: false),
                       "the focused category must not disable itself, and Left must work at once")
        XCTAssertTrue(tvSettingsRailIsInert(isModalPresented: true, isRestoringPickerRow: false))
        XCTAssertTrue(tvSettingsRailIsInert(isModalPresented: false, isRestoringPickerRow: true))
    }

    // MARK: Build 103: Guide entry never drops Down

    func testGuideEntryFallsBackToALaidOutRowWhileTheRememberedRowMounts() {
        let history = TVLiveTVGuideFocusHistory()
        let rows = ["news", "sports", "movies"]
        let remembered = TVLiveTVGuideFocus.channel("movies")
        XCTAssertEqual(history.entry(remembered, rowIDs: rows, laidOutRows: ["news", "sports"]), .channel("news"))
        XCTAssertTrue(history.allowsGridEntry(remembered, rowIDs: rows, laidOutRows: ["news", "sports"]),
                      "Down is accepted instead of dropped")
        XCTAssertEqual(history.entry(remembered, rowIDs: rows, laidOutRows: ["movies"]), remembered)
        XCTAssertFalse(history.allowsGridEntry(remembered, rowIDs: rows, laidOutRows: []),
                       "nothing is laid out yet: there is no target to land on")
    }

    func testGuideEntryKeepsTheRememberedChannelAfterBack() {
        var history = TVLiveTVGuideFocusHistory()
        history.observe(.program(channelID: "sports", programID: "now"))
        XCTAssertTrue(history.returnToHeader())
        history.observe(.category)
        XCTAssertEqual(history.entry(.channel("news"), rowIDs: ["news", "sports"], laidOutRows: ["news", "sports"]),
                       .channel("sports"))
    }

    // MARK: Focus treatment

    func testFocusLiftIsSmallAndRespectsReduceMotion() {
        XCTAssertEqual(TVKyroFocus.scale(for: .card, focused: true, reduceMotion: false), 1.04)
        XCTAssertEqual(TVKyroFocus.scale(for: .chip, focused: true, reduceMotion: false), 1.06)
        XCTAssertEqual(TVKyroFocus.scale(for: .card, focused: false, reduceMotion: false), 1)
        XCTAssertEqual(TVKyroFocus.scale(for: .card, focused: true, reduceMotion: true), 1)
        XCTAssertGreaterThanOrEqual(TVKyroFocus.ringWidth, 4, "the ring must read from across the room")
    }
}
#endif
