import Foundation
import XCTest
@testable import Silo

/// Kyro's unified navigation prototype: where the Live TV tab goes, when it
/// can be shown, and how Picture in Picture returns without a Live TV screen.
@MainActor
final class KyroUnifiedNavigationTests: XCTestCase {
    private var presentation: LiveTVPresentation!
    private var navigations = 0
    private var stops = 0

    override func setUp() async throws {
        presentation = LiveTVPresentation(scheduler: IdleScheduler())
        navigations = 0
        stops = 0
        presentation.navigateToLiveTV = { [unowned self] in navigations += 1 }
        presentation.stopPlayback = { [unowned self] in stops += 1 }
        presentation.stopPictureInPicture = {}
    }

    private let news = LiveTVChannel(id: "news", guideID: "news", name: "News",
                                     streamURL: URL(string: "https://tv.example/news.ts")!, logoURL: nil,
                                     category: "News")

    // MARK: Global selection and secondary routes

    func testNativeShellAdapterMapsTheFiveRequiredDestinationsOneToOne() {
        XCTAssertEqual(KyroGlobalDestination.requiredDestinations,
                       [.home, .movies, .series, .forYou, .liveTV])
        for destination in KyroGlobalDestination.requiredDestinations {
            let root = MainTabDestination.global(destination)
            XCTAssertEqual(kyroGlobalDestination(for: root.id), destination)
        }
        XCTAssertEqual(MainTabDestination.global(.home).id, .app(.home),
                       "Global Home remains the Kyro Home screen")
        XCTAssertEqual(MainTabDestination.global(.movies).id, .libraryCategory(.movies))
        XCTAssertEqual(MainTabDestination.global(.series).id, .libraryCategory(.series))
        XCTAssertEqual(MainTabDestination.global(.forYou).id, .app(.recommendations))
    }

    func testMoviesAndSeriesRemainPrimaryWhenNoMatchingLibrariesAreAvailable() {
        let globalRoots = KyroGlobalDestination.requiredDestinations.map(MainTabDestination.global)
        XCTAssertEqual(globalRoots.count, 5)
        XCTAssertTrue(globalRoots.contains { $0.id == .libraryCategory(.movies) })
        XCTAssertTrue(globalRoots.contains { $0.id == .libraryCategory(.series) })
        XCTAssertFalse(mainTabSupportsDestination(.builtin(.movies), availableLibraries: []))
        XCTAssertFalse(mainTabSupportsDestination(.builtin(.series), availableLibraries: []))
    }

    func testMoreProjectionKeepsSecondarySiloRootsOutOfGlobalTabs() {
        let projected = KyroGlobalDestination.requiredDestinations.map(MainTabDestination.global)
            + [.app(.downloads), .app(.calendar), .library(id: 42, label: "Kids")]
        let secondary = kyroSecondaryDestinations(from: projected)
        XCTAssertEqual(secondary.map(\.id), [.app(.downloads), .app(.calendar), .library(42)])
        XCTAssertFalse(secondary.contains { kyroGlobalDestination(for: $0.id) != nil })
    }

    func testMoreAddsCalendarIndependentOfPrimaryMenuAndDownloadsOnlyWhenEnabled() {
        let onlyGlobalTabs = KyroGlobalDestination.requiredDestinations.map(MainTabDestination.global)

        let withoutDownloads = kyroMoreDestinations(from: onlyGlobalTabs, downloadsEnabled: false)
        XCTAssertEqual(withoutDownloads.map(\.id), [.app(.calendar)])

        let withDownloads = kyroMoreDestinations(from: onlyGlobalTabs, downloadsEnabled: true)
        XCTAssertEqual(withDownloads.map(\.id), [.app(.calendar), .app(.downloads)])
        XCTAssertFalse(withDownloads.contains { $0.title == "Collections" })
        XCTAssertEqual(KyroGlobalDestination.requiredDestinations.count, 5)
    }

    func testMorePreservesEligibleSecondaryRootsWithoutDuplicatingCalendarOrDownloads() {
        let projected = KyroGlobalDestination.requiredDestinations.map(MainTabDestination.global)
            + [.app(.calendar), .app(.downloads), .library(id: 42, label: "Kids")]
        XCTAssertEqual(kyroMoreDestinations(from: projected, downloadsEnabled: true).map(\.id),
                       [.app(.calendar), .app(.downloads), .library(42)])
    }

    func testDownloadsDeepLinkAndCalendarTabRequestsResolveToSecondaryRoutes() {
        let projected = KyroGlobalDestination.requiredDestinations.map(MainTabDestination.global)
            + [.app(.downloads), .app(.calendar)]

        XCTAssertEqual(
            kyroSecondaryRouteID(for: .downloads, visibleDestinations: projected),
            .app(.downloads),
            "The existing downloads deep-link's requestedTab path must still open Downloads"
        )
        XCTAssertEqual(
            kyroSecondaryRouteID(for: .calendar, visibleDestinations: projected),
            .app(.calendar)
        )
        XCTAssertNil(kyroSecondaryRouteID(for: .home, visibleDestinations: projected))
    }

    func testIneligibleSecondaryRequestFailsClosed() {
        let projected = KyroGlobalDestination.requiredDestinations.map(MainTabDestination.global)
        XCTAssertNil(kyroSecondaryRouteID(for: .downloads, visibleDestinations: projected))
    }

    func testLiveTVInternalGuideAndBrowserHaveContextualHomeReturnWithoutChangingGlobalHome() {
        XCTAssertTrue(LiveTVNavigationPolicy.showsGuideBack(isUnifiedShell: true))
        XCTAssertFalse(LiveTVNavigationPolicy.showsGuideBack(isUnifiedShell: false))
        XCTAssertEqual(LiveTVNavigationPolicy.backDestination(showingBrowser: true), .home)
        XCTAssertEqual(LiveTVNavigationPolicy.backLabel(showingBrowser: true), "Back to Live TV Home")
        XCTAssertEqual(MainTabDestination.global(.home).id, .app(.home),
                       "The app-wide Home tab remains Kyro Home")
    }

    func testSecondaryRouteIdentityDoesNotOverlapGlobalSelection() {
        let downloads = Route.secondaryDestination(.app(.downloads))
        let calendar = Route.secondaryDestination(.app(.calendar))
        let kidsLibrary = Route.secondaryDestination(.library(42))
        XCTAssertNotEqual(downloads, calendar)
        XCTAssertNotEqual(calendar, kidsLibrary)
        XCTAssertEqual(MainTabDestinationID(SecondaryDestinationID.app(.downloads)), .app(.downloads))
        XCTAssertEqual(MainTabDestinationID(SecondaryDestinationID.library(42)), .library(42))
    }

    func testLiveTVCanBeATabOnlyFromTheShellRoot() {
        XCTAssertTrue(KyroUnifiedNavigation.canSelectLiveTVTab(pathIsEmpty: true, isPresentingOverShell: false))
        XCTAssertFalse(KyroUnifiedNavigation.canSelectLiveTVTab(pathIsEmpty: false, isPresentingOverShell: false))
        XCTAssertFalse(KyroUnifiedNavigation.canSelectLiveTVTab(pathIsEmpty: true, isPresentingOverShell: true))
    }

    // MARK: Picture in Picture over a pushed Media Server screen

    private func enterPictureInPictureThenLeaveLiveTV() {
        presentation.surfaceAppeared(.list)
        XCTAssertEqual(presentation.select(news, from: .list), .present)
        presentation.pictureInPictureStartedFromControl()
        presentation.surfaceDisappeared(.list)
    }

    func testRestoreOverAPushedScreenOpensThePlayerOverItAndClosingLeavesItThere() {
        enterPictureInPictureThenLeaveLiveTV()
        var answers: [Bool] = []
        presentation.restoreRequested { answers.append($0) }
        XCTAssertEqual(navigations, 1, "Asked for a Live TV screen first")

        // The shell found a pushed Media Server screen and left it in place.
        presentation.presentOverCurrentScreen()
        XCTAssertEqual(presentation.phase, .restoring(news, .shell))
        XCTAssertEqual(presentation.channel(for: .shell), news)
        XCTAssertNil(presentation.channel(for: .list), "Exactly one cover")

        presentation.playerDidAppear(news)
        XCTAssertEqual(answers, [true])
        XCTAssertEqual(presentation.phase, .presented(news, .shell))

        presentation.coverDismissed(from: .shell)
        XCTAssertEqual(presentation.phase, .idle)
    }

    func testReturningToThePlayerAfterAWindowSwitchAlsoUsesTheShell() {
        enterPictureInPictureThenLeaveLiveTV()
        let other = LiveTVChannel(id: "sport", guideID: "sport", name: "Sport",
                                  streamURL: URL(string: "https://tv.example/sport.m3u8")!, logoURL: nil,
                                  category: "Sports")
        _ = presentation.select(other, from: .list)
        XCTAssertEqual(presentation.engagementEnded(), .continuePlayback)
        XCTAssertEqual(navigations, 1)

        presentation.presentOverCurrentScreen()
        XCTAssertEqual(presentation.channel(for: .shell), other)
        XCTAssertNil(presentation.channel(for: .list))
    }

    func testTheShellNeverTakesThePlayerFromAVisibleLiveTVScreen() {
        presentation.surfaceAppeared(.list)
        XCTAssertEqual(presentation.select(news, from: .list), .present)
        presentation.presentOverCurrentScreen()
        XCTAssertEqual(presentation.phase, .presented(news, .list))

        presentation.coverDismissed(from: .list)
        presentation.presentOverCurrentScreen()
        XCTAssertEqual(presentation.phase, .idle)
    }

    func testAfterTheShellPlayerTheListPresentsAgain() {
        enterPictureInPictureThenLeaveLiveTV()
        presentation.restoreRequested { _ in }
        presentation.presentOverCurrentScreen()
        presentation.playerDidAppear(news)
        presentation.coverDismissed(from: .shell)

        presentation.surfaceAppeared(.list)
        XCTAssertEqual(presentation.select(news, from: .list), .present)
        XCTAssertEqual(presentation.channel(for: .list), news)
        XCTAssertNil(presentation.channel(for: .shell))
    }
}

/// Timers that never fire: these tests finish every restore themselves.
@MainActor
private final class IdleScheduler: LiveTVScheduling {
    var now: Double { 0 }

    func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) -> LiveTVTimerHandle {
        LiveTVTimerHandle {}
    }
}
