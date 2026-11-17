#if os(tvOS)
import XCTest
@testable import Silo

/// Apple TV Sports Hub: navigation, feed rules, data mapping, playback banner, focus restoration
/// and refresh policy. Stream matching and one-session playback coordination are covered by the
/// shared `KyroSportsStreamMatcherTests` and `KyroSportsPlaybackCoordinatorTests`, which this
/// target now compiles against the same Sports data layer the iPhone uses.
@MainActor
final class KyroTVSportsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func game(_ rawID: String, status: KyroGameStatus, league: KyroSportLeague = .nba,
                      home: Int? = 100, away: Int? = 98, tbd: Bool = false) -> KyroSportsGame {
        let awayTeam = KyroSportsTeam(id: "a\(rawID)", league: league, abbreviation: "NYK", nickname: "Knicks", location: "New York")
        let homeTeam = KyroSportsTeam(id: "h\(rawID)", league: league, abbreviation: "BOS", nickname: "Celtics", location: "Boston")
        return KyroSportsGame(id: KyroGameID(provider: "espn", league: league, rawID: rawID), league: league,
                              startTime: now, status: status,
                              home: KyroGameTeam(team: homeTeam, score: home),
                              away: KyroGameTeam(team: awayTeam, score: away),
                              isStartTimeTBD: tbd)
    }

    // MARK: Navigation

    func testSportsIsATopLevelRootAfterLiveTV() {
        XCTAssertEqual(TVPrimaryMenuProjection.roots(for: [], libraries: []), [.home, .liveTV, .sports])
        XCTAssertEqual(TVRootDestination.sports.title, "Sports")
        XCTAssertNotEqual(TVRootDestination.sports, TVRootDestination.liveTV)
        XCTAssertNotEqual(TVRootDestination.sports.hashValue, TVRootDestination.liveTV.hashValue)
    }

    // MARK: Feeds and data mapping

    func testFeedsSplitTheScheduleIntoLiveUpcomingAndRecent() {
        let live = game("1", status: .live)
        let scheduled = game("2", status: .scheduled, home: nil, away: nil)
        let postponed = game("3", status: .postponed, home: nil, away: nil)
        let final = game("4", status: .final)
        let canceled = game("5", status: .canceled, home: nil, away: nil)
        let schedule = [live, scheduled, postponed, final, canceled]

        XCTAssertEqual(TVSportsFeed.games(mode: .live, live: [live], schedule: schedule).map(\.id), [live.id])
        XCTAssertEqual(TVSportsFeed.games(mode: .upcoming, live: [live], schedule: schedule).map(\.id), [scheduled.id, postponed.id])
        XCTAssertEqual(TVSportsFeed.games(mode: .recent, live: [live], schedule: schedule).map(\.id), [final.id])
    }

    func testUpcomingLooksForwardAndRecentLooksBack() {
        let today = calendar.startOfDay(for: now)
        let days = (-3...3).map { calendar.date(byAdding: .day, value: $0, to: today)! }
        let upcoming = TVSportsFeed.days(mode: .upcoming, browseDays: days, now: now, calendar: calendar)
        let recent = TVSportsFeed.days(mode: .recent, browseDays: days, now: now, calendar: calendar)
        XCTAssertEqual(upcoming, Array(days[3...]))
        XCTAssertEqual(recent, Array(days[...3]).reversed())
        XCTAssertTrue(TVSportsFeed.days(mode: .live, browseDays: days, now: now, calendar: calendar).isEmpty)
        XCTAssertFalse(TVSportsMode.live.usesDayStrip)
        XCTAssertEqual(TVSportsFeed.defaultDay(now: now, calendar: calendar), today)
    }

    func testOnlyLiveEventsStartPlaybackOnSelect() {
        XCTAssertEqual(TVSportsFeed.selectionAction(for: game("1", status: .live)), .play)
        for status in [KyroGameStatus.scheduled, .final, .postponed, .canceled, .suspended] {
            XCTAssertEqual(TVSportsFeed.selectionAction(for: game("2", status: status)), .openDetails, "\(status)")
        }
    }

    func testStartTextNeverInventsAClockTime() {
        let timed = TVSportsFormat.startText(game("1", status: .scheduled))
        let tbd = TVSportsFormat.startText(game("2", status: .scheduled, tbd: true))
        XCTAssertFalse(timed.contains("TBD"))
        XCTAssertTrue(tbd.contains("Time TBD"))
        XCTAssertEqual(TVSportsFormat.statusText(game("3", status: .final)), "Final")
    }

    // MARK: Playback banner

    func testBannerShowsProgressAndOffersCancelWhileTuning() {
        let searching = TVSportsPlaybackBanner.make(for: .searching(game("1", status: .live).id))
        XCTAssertEqual(searching?.showsCancel, true)
        XCTAssertEqual(searching?.isError, false)
        let connecting = TVSportsPlaybackBanner.make(for: .connecting(channelName: "Arena 1", attempt: 2, total: 3))
        XCTAssertEqual(connecting?.message, "Connecting to Arena 1 (2 of 3)…")
        XCTAssertEqual(TVSportsPlaybackBanner.make(for: .connecting(channelName: "Arena 1", attempt: 1, total: 1))?.message,
                       "Connecting to Arena 1…")
    }

    func testBannerHidesWhenIdleOrPresentedAndOffersRetryWhenUnavailable() {
        XCTAssertNil(TVSportsPlaybackBanner.make(for: .idle))
        XCTAssertNil(TVSportsPlaybackBanner.make(for: .presented))
        let g = game("1", status: .live)
        let result = KyroSportsStreamMatchResult(confidence: .low, matches: [], manualSearchQuery: "", guideWasStale: false,
                                                 indexWasCancelled: false)
        let unavailable = TVSportsPlaybackBanner.make(for: .unavailable(g, result, message: ""))
        XCTAssertEqual(unavailable?.showsRetry, true)
        XCTAssertEqual(unavailable?.isError, true)
        XCTAssertEqual(unavailable?.message, "No matching stream is available for this event.")
        XCTAssertEqual(TVSportsPlaybackBanner.make(for: .exhausted(g, result))?.showsRetry, true)
    }

    // MARK: Focus restoration

    func testFocusReturnsToTheSameCardOrFallsBackToTheFirst() {
        let ids = (1...4).map { game("\($0)", status: .live).id }
        var memory = TVSportsFocusMemory()
        XCTAssertEqual(memory.restoreTarget(visible: ids), ids.first)
        memory.remember(ids[2])
        XCTAssertEqual(memory.restoreTarget(visible: ids), ids[2])
        // The remembered event left the list (for example it finished), so focus lands on the first card.
        XCTAssertEqual(memory.restoreTarget(visible: [ids[0], ids[1]]), ids[0])
        XCTAssertNil(memory.restoreTarget(visible: []))
    }

    // MARK: Refresh policy

    func testPollingNeverRunsFromFocusAndPausesWhilePlayerIsUp() {
        XCTAssertFalse(TVSportsPolling.shouldRefresh(playerIsPresented: true, isRefreshing: false))
        XCTAssertFalse(TVSportsPolling.shouldRefresh(playerIsPresented: false, isRefreshing: true))
        XCTAssertTrue(TVSportsPolling.shouldRefresh(playerIsPresented: false, isRefreshing: false))
        XCTAssertEqual(TVSportsPolling.delay(storeInterval: nil), TVSportsPolling.idleCheckSeconds)
        XCTAssertEqual(TVSportsPolling.delay(storeInterval: 1), 10, "never polls faster than every 10 seconds")
        XCTAssertEqual(TVSportsPolling.delay(storeInterval: 45), 45)
    }

    // MARK: Shared data layer on tvOS

    func testSharedStoreIsOneInstanceSoReentryReusesItsCache() {
        XCTAssertTrue(TVSportsStores.hub === TVSportsStores.hub)
        XCTAssertTrue(TVSportsStores.details === TVSportsStores.details)
    }

    func testAllLeaguesTheIPhoneOffersAreSelectableOnTV() {
        let ids = Set(KyroSportsCategory.filterOrder.map(\.rawValue))
        for league in ["nfl", "nba", "nhl", "mlb", "collegeFootball", "atp", "wta", "soccer"] {
            XCTAssertTrue(ids.contains(league), league)
        }
    }
}
#endif
