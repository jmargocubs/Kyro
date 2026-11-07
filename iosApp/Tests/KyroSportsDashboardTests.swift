import Foundation
import XCTest
@testable import Silo

/// Dashboard policy: featured event, default and visible modes, empty states,
/// ordering, and mode stability across refreshes. Pure value logic; no network.
@MainActor
final class KyroSportsDashboardTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_791_396_000)

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func game(
        _ id: String,
        _ status: KyroGameStatus,
        hoursFromNow: Double,
        away: String = "DEN",
        home: String = "KC"
    ) -> KyroSportsGame {
        KyroSportsGame(
            id: KyroGameID(provider: "espn", league: .nfl, rawID: id),
            league: .nfl,
            season: 2026,
            seasonType: .regular,
            week: 9,
            startTime: now.addingTimeInterval(hoursFromNow * 3600),
            status: status,
            home: KyroGameTeam(team: .placeholder(abbreviation: home, league: .nfl), score: status.isScheduled ? nil : 10),
            away: KyroGameTeam(team: .placeholder(abbreviation: away, league: .nfl), score: status.isScheduled ? nil : 7)
        )
    }

    private func sections(_ games: [KyroSportsGame], at date: Date? = nil) -> [KyroSportsGameSection] {
        KyroSportsSectioning.sections(from: games, now: date ?? now, calendar: calendar)
    }

    // MARK: Featured event

    func testFeaturedEventPrefersLiveOverUpcomingAndFinal() {
        let result = sections([
            game("final", .final, hoursFromNow: -30),
            game("soon", .scheduled, hoursFromNow: 3),
            game("live", .live, hoursFromNow: -1)
        ])
        XCTAssertEqual(KyroSportsDashboard.featuredEvent(from: result, now: now)?.id.rawID, "live")
    }

    func testFeaturedEventIsNextUpcomingWhenNothingIsLive() {
        let result = sections([
            game("final", .final, hoursFromNow: -30),
            game("later", .scheduled, hoursFromNow: 60),
            game("next", .scheduled, hoursFromNow: 30)
        ])
        XCTAssertEqual(KyroSportsDashboard.featuredEvent(from: result, now: now)?.id.rawID, "next")
    }

    func testFeaturedEventFallsBackToMostRecentFinalOnlyWhenNoLiveOrUpcoming() {
        let result = sections([
            game("older", .final, hoursFromNow: -72),
            game("recent", .final, hoursFromNow: -30)
        ])
        XCTAssertEqual(KyroSportsDashboard.featuredEvent(from: result, now: now)?.id.rawID, "recent")
    }

    func testFeaturedEventIsNilWithoutGames() {
        XCTAssertNil(KyroSportsDashboard.featuredEvent(from: [], now: now))
    }

    // MARK: Default mode and visibility

    func testDefaultModeIsLiveOnlyWhenGamesAreLive() {
        let live = sections([game("a", .live, hoursFromNow: -1), game("b", .scheduled, hoursFromNow: 30)])
        let quiet = sections([game("b", .scheduled, hoursFromNow: 30), game("c", .final, hoursFromNow: -30)])
        XCTAssertEqual(KyroSportsDashboard.defaultMode(for: live), .live)
        XCTAssertEqual(KyroSportsDashboard.defaultMode(for: quiet), .upcoming)
    }

    func testResultsAreHiddenUnlessResultsModeIsSelected() {
        let result = sections([
            game("final", .final, hoursFromNow: -30),
            game("next", .scheduled, hoursFromNow: 30)
        ])
        let upcoming = KyroSportsDashboard.visibleSections(from: result, mode: .upcoming)
        XCTAssertFalse(upcoming.contains { $0.bucket == .recent })
        let results = KyroSportsDashboard.visibleSections(from: result, mode: .results)
        XCTAssertEqual(results.map(\.bucket), [.recent])
    }

    func testNoGameAppearsInMoreThanOneVisibleSection() {
        let result = sections([
            game("live", .live, hoursFromNow: -1),
            game("today", .scheduled, hoursFromNow: 2),
            game("final", .final, hoursFromNow: -30),
            game("next", .scheduled, hoursFromNow: 30),
            game("far", .scheduled, hoursFromNow: 24 * 30)
        ])
        let all = result.flatMap(\.games).map(\.id)
        XCTAssertEqual(all.count, Set(all).count, "a game must live in exactly one bucket")

        var seen = Set<KyroGameID>()
        for mode in KyroSportsDashboardMode.allCases {
            for section in KyroSportsDashboard.visibleSections(from: result, mode: mode, includesFuture: true) {
                for game in section.games {
                    XCTAssertTrue(seen.insert(game.id).inserted, "\(game.id) shown under two modes")
                }
            }
        }
    }

    func testGamesBeyondInitialHorizonAreKeptBehindFutureExpansion() {
        let result = sections([
            game("next", .scheduled, hoursFromNow: 30),
            game("far", .scheduled, hoursFromNow: 24 * 30)
        ])
        XCTAssertTrue(KyroSportsDashboard.hasFutureGames(in: result))
        let collapsed = KyroSportsDashboard.visibleSections(from: result, mode: .upcoming)
        XCTAssertFalse(collapsed.flatMap(\.games).contains { $0.id.rawID == "far" })
        let expanded = KyroSportsDashboard.visibleSections(from: result, mode: .upcoming, includesFuture: true)
        XCTAssertTrue(expanded.flatMap(\.games).contains { $0.id.rawID == "far" })
    }

    // MARK: Empty states

    func testEmptyStatesAppearOnlyForEmptyModes() {
        let result = sections([game("next", .scheduled, hoursFromNow: 30)])
        XCTAssertNil(KyroSportsDashboard.emptyState(for: .upcoming, in: result))
        XCTAssertNotNil(KyroSportsDashboard.emptyState(for: .live, in: result))
        XCTAssertNotNil(KyroSportsDashboard.emptyState(for: .results, in: result))
        XCTAssertNotNil(KyroSportsDashboard.emptyState(for: .upcoming, in: []))
    }

    // MARK: Ordering and transitions

    func testUpcomingSectionsAreInDateOrder() {
        let result = sections([
            game("c", .scheduled, hoursFromNow: 100),
            game("a", .scheduled, hoursFromNow: 30),
            game("b", .scheduled, hoursFromNow: 55)
        ])
        let days = result.filter { $0.bucket == .upcoming }.compactMap(\.localDay)
        XCTAssertEqual(days, days.sorted())
        XCTAssertEqual(
            result.filter { $0.bucket == .upcoming }.flatMap(\.games).map(\.id.rawID),
            ["a", "b", "c"]
        )
    }

    func testGameMovesBetweenBucketsAsStatusChanges() {
        func bucket(_ status: KyroGameStatus, hours: Double) -> KyroSportsGameBucket? {
            sections([game("g", status, hoursFromNow: hours)]).first?.bucket
        }
        XCTAssertEqual(bucket(.scheduled, hours: 30), .upcoming)
        XCTAssertEqual(bucket(.live, hours: -0.5), .liveNow)
        XCTAssertEqual(bucket(.final, hours: -4), .recent)
    }

    // MARK: Selection across refreshes

    private struct StubProvider: KyroSportsProviding {
        let providerID = "stub"
        let games: [KyroSportsGame]
        func fetchNFLWindow(now: Date, force: Bool) async throws -> KyroSportsProviderOutput {
            KyroSportsProviderOutput(provider: providerID, games: games, season: 2026, week: 9, refreshError: nil)
        }
    }

    func testSelectedModeSurvivesRefreshAndInitialModeResolvesOnce() async {
        let liveGames = [game("live", .live, hoursFromNow: -1), game("next", .scheduled, hoursFromNow: 30)]
        let store = KyroSportsHubStore(
            providers: [StubProvider(games: liveGames)],
            calendar: calendar,
            now: { [now] in now }
        )
        await store.load()
        XCTAssertEqual(store.selectedDashboardMode, .live, "live games choose Live first")

        store.selectDashboardMode(.results)
        await store.load(force: true)
        XCTAssertEqual(store.selectedDashboardMode, .results, "a refresh must not reset the user's choice")
    }
}
