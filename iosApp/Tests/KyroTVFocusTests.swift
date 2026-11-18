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

    func testDownFromFiltersEntersTheCurrentProgramOfTheRememberedChannel() {
        let target = TVLiveTVGuideFocusPlanner.entryTarget(rowIDs: rows, remembered: "sports") { channel in
            channel == "sports" ? "sports-now" : "other-now"
        }
        XCTAssertEqual(target, .program(channelID: "sports", programID: "sports-now"))
    }

    func testDownFromFiltersFallsBackToTheFirstChannelWhenNothingIsRemembered() {
        let target = TVLiveTVGuideFocusPlanner.entryTarget(rowIDs: rows, remembered: nil) { "\($0)-now" }
        XCTAssertEqual(target, .program(channelID: "news", programID: "news-now"))
    }

    func testRememberedChannelRemovedByAFilterFallsBackToTheFirstRow() {
        let target = TVLiveTVGuideFocusPlanner.entryTarget(rowIDs: ["movies"], remembered: "sports") { "\($0)-now" }
        XCTAssertEqual(target, .program(channelID: "movies", programID: "movies-now"))
    }

    func testChannelWithoutCurrentListingsLandsOnItsNameTile() {
        let target = TVLiveTVGuideFocusPlanner.entryTarget(rowIDs: rows, remembered: "news") { _ in nil }
        XCTAssertEqual(target, .channel("news"), "predictable fallback, never a future cell")
    }

    func testEmptyGuideHasNoEntryTarget() {
        XCTAssertNil(TVLiveTVGuideFocusPlanner.entryTarget(rowIDs: [], remembered: "news") { _ in "x" })
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
            XCTAssertEqual(history.gridDefault(entry: target), target)
            history.observe(target)
            history.observe(nil)
            XCTAssertEqual(history.gridDefault(entry: .channel("other")), target)
            history.observe(.category)
            XCTAssertEqual(history.gridDefault(entry: .channel("other")), .channel("other"))
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
        let target = TVLiveTVGuideFocusPlanner.entryTarget(rowIDs: rows, remembered: TVLiveTVGuideMemory.lastChannelID) { "\($0)-now" }
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

    // MARK: Providers screen escape paths

    func testEveryControlInTheTopProviderRowEscapesUpToBack() {
        let first = UUID(), second = UUID()
        let ids = [first, second]
        for focus in [TVLiveTVProviderFocus.provider(first), .refresh(first), .remove(first)] {
            XCTAssertTrue(TVLiveTVProviderFocusPlanner.escapesToBack(focus, providerIDs: ids), "\(focus)")
        }
        for focus in [TVLiveTVProviderFocus.provider(second), .refresh(second), .remove(second), .save, .back] {
            XCTAssertFalse(TVLiveTVProviderFocusPlanner.escapesToBack(focus, providerIDs: ids), "\(focus)")
        }
        XCTAssertFalse(TVLiveTVProviderFocusPlanner.escapesToBack(.phoneSetup, providerIDs: ids))
    }

    func testWithNoProvidersSetUpWithPhoneIsTheTopControlAndTheEntryPoint() {
        XCTAssertTrue(TVLiveTVProviderFocusPlanner.escapesToBack(.phoneSetup, providerIDs: []))
        XCTAssertEqual(TVLiveTVProviderFocusPlanner.initialFocus(providerIDs: []), .phoneSetup)
    }

    func testFocusAfterRemovingAProviderLandsOnTheNextOneOrPhoneSetup() {
        let next = UUID()
        XCTAssertEqual(TVLiveTVProviderFocusPlanner.afterRemoval(remainingProviderIDs: [next]), .provider(next))
        XCTAssertEqual(TVLiveTVProviderFocusPlanner.afterRemoval(remainingProviderIDs: []), .phoneSetup)
        XCTAssertEqual(TVLiveTVProviderFocusPlanner.initialFocus(providerIDs: [next]), .provider(next))
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
