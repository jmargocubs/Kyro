#if os(tvOS)
import Foundation
import SwiftUI
import XCTest
@testable import Silo

/// Build 95: Movies and Series show one source at a time (a Silo library or one IPTV provider),
/// chosen in the tab's top-bar cascade. Build 92–94 stacked All / Silo / provider chips and an
/// IPTV rail over the full-screen Skyline feed (device video: the marquee title was covered and
/// the rail cards had no artwork) and gave the IPTV page no focus owner.
@MainActor
final class TVVideoSourceTests: XCTestCase {
    private func xtream(_ name: String, movies: Bool = true, series: Bool = true) -> LiveTVProvider {
        var provider = LiveTVProvider(id: UUID(), name: name, channelCount: 0, lastRefreshed: nil, kind: .xtream)
        provider.vodMoviesEnabled = movies
        provider.vodSeriesEnabled = series
        return provider
    }

    private func m3u(_ name: String) -> LiveTVProvider {
        var provider = LiveTVProvider(id: UUID(), name: name, channelCount: 10, lastRefreshed: nil, kind: .m3u)
        provider.vodMoviesEnabled = true // never valid for M3U, and must be ignored
        return provider
    }

    private let movieLibrary = Library(id: 1, name: "Movies", type: "movies", sortOrder: 0, posterUrl: nil)
    private let seriesLibrary = Library(id: 2, name: "TV", type: "series", sortOrder: 1, posterUrl: nil)

    // MARK: Source-filter behavior

    func testOnlyXtreamProvidersWithTheTabsCatalogAreSources() {
        let both = xtream("Both"), moviesOnly = xtream("Movies", series: false), off = xtream("Off", movies: false, series: false)
        let all = [both, moviesOnly, off, m3u("M3U")]
        XCTAssertEqual(TVVideoSourceResolver.providers(for: .movies, in: all).map(\.name), ["Both", "Movies"])
        XCTAssertEqual(TVVideoSourceResolver.providers(for: .series, in: all).map(\.name), ["Both"])
        XCTAssertTrue(TVVideoSourceResolver.providers(for: .music, in: all).isEmpty)
        XCTAssertEqual(TVVideoSourceResolver.vodTypes(in: all), [.movies, .series])
        XCTAssertEqual(TVVideoSourceResolver.vodTypes(in: [moviesOnly]), [.movies])
        XCTAssertEqual(TVVideoSourceResolver.vodTypes(in: [m3u("M3U"), off]), [])
    }

    func testSiloOnlyBrowsingAlwaysShowsSilo() {
        XCTAssertEqual(TVVideoSourceResolver.resolve(selected: nil, hasSiloLibrary: true, providers: []), .silo)
        XCTAssertEqual(TVVideoSourceResolver.resolve(selected: .provider(UUID()), hasSiloLibrary: true, providers: []), .silo,
                       "a removed provider falls back to Silo")
    }

    func testIPTVOnlyBrowsingShowsTheFirstProvider() {
        let first = xtream("First"), second = xtream("Second")
        XCTAssertEqual(TVVideoSourceResolver.resolve(selected: nil, hasSiloLibrary: false, providers: [first, second]),
                       .provider(first.id))
        XCTAssertEqual(TVVideoSourceResolver.resolve(selected: .silo, hasSiloLibrary: false, providers: [first, second]),
                       .provider(first.id), "Silo is not offered without a Silo library")
        XCTAssertEqual(TVVideoSourceResolver.resolve(selected: .provider(second.id), hasSiloLibrary: false,
                                                     providers: [first, second]), .provider(second.id))
    }

    func testMixedBrowsingDefaultsToSiloAndHonoursTheChosenSource() {
        let provider = xtream("Playlist")
        XCTAssertEqual(TVVideoSourceResolver.resolve(selected: nil, hasSiloLibrary: true, providers: [provider]), .silo,
                       "adding a provider never replaces the Silo page a user already had")
        XCTAssertEqual(TVVideoSourceResolver.resolve(selected: .provider(provider.id), hasSiloLibrary: true,
                                                     providers: [provider]), .provider(provider.id))
        XCTAssertEqual(TVVideoSourceResolver.resolve(selected: .silo, hasSiloLibrary: true, providers: [provider]), .silo)
        // The provider's Movies catalog is turned off: Movies falls back to Silo.
        XCTAssertEqual(TVVideoSourceResolver.resolve(selected: .provider(provider.id), hasSiloLibrary: true,
                                                     providers: []), .silo)
    }

    func testSourceChoicePersistsPerTabAndProfile() throws {
        let suite = "VideoSource.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var scope = "server.profileA"
        let store = TVVideoSourceStore(defaults: defaults, scopeKey: { scope })
        let id = UUID()
        XCTAssertNil(store.source(for: .movies))
        store.setSource(.provider(id), for: .movies)
        store.setSource(.silo, for: .series)
        XCTAssertEqual(store.source(for: .movies), .provider(id))
        XCTAssertEqual(store.source(for: .series), .silo, "Movies and Series are chosen independently")
        scope = "server.profileB"
        XCTAssertNil(store.source(for: .movies), "another profile keeps its own choice")
        XCTAssertEqual(TVVideoSource(storageValue: "silo"), .silo)
        XCTAssertNil(TVVideoSource(storageValue: "not-a-uuid"))
    }

    // MARK: Layout state

    func testTabPageIsEitherTheUntouchedSiloPageOrOneProviderPage() {
        let provider = xtream("Playlist")
        XCTAssertEqual(TVLibraryTypeTabView.page(for: .movies, vodProvider: nil, scopesMixedLibraries: true), .silo)
        XCTAssertEqual(TVLibraryTypeTabView.page(for: .movies, vodProvider: provider, scopesMixedLibraries: true),
                       .provider(provider.id, .movie))
        XCTAssertEqual(TVLibraryTypeTabView.page(for: .series, vodProvider: provider, scopesMixedLibraries: true),
                       .provider(provider.id, .series))
        XCTAssertEqual(TVLibraryTypeTabView.page(for: .movies, vodProvider: provider, scopesMixedLibraries: false), .silo,
                       "a pinned Silo library shortcut never shows IPTV")
        XCTAssertEqual(TVLibraryTypeTabView.page(for: .music, vodProvider: provider, scopesMixedLibraries: true), .silo)
    }

    func testImportStatusShowsOnlyWhereItApplies() {
        let id = UUID()
        var progress = XtreamVODImportProgress(providerID: id)
        progress.stage = .importing(.movie)
        XCTAssertTrue(TVXtreamVODView.showsImportStatus(progress, providerID: id, kind: .movie))
        XCTAssertTrue(TVXtreamVODView.showsImportStatus(progress, providerID: id, kind: .series))
        XCTAssertFalse(TVXtreamVODView.showsImportStatus(progress, providerID: UUID(), kind: .movie))
        progress.stage = .failed
        progress.movieResult = .failed
        progress.seriesResult = .ready
        XCTAssertTrue(TVXtreamVODView.showsImportStatus(progress, providerID: id, kind: .movie))
        XCTAssertFalse(TVXtreamVODView.showsImportStatus(progress, providerID: id, kind: .series),
                       "a Movies failure does not clutter a working Series page")
        progress.stage = .ready
        XCTAssertFalse(TVXtreamVODView.showsImportStatus(progress, providerID: id, kind: .movie))
    }

    // MARK: Navigation (top menu)

    func testIPTVOnlyTabsJoinTheMenuBesideTheMediaTabs() {
        XCTAssertEqual(TVPrimaryMenuProjection.roots(for: [.builtin(.home), .builtin(.movies), .builtin(.series)],
                                                     libraries: [], vodTypes: [.movies, .series]),
                       [.home, .libraryType(.movies), .libraryType(.series), .liveTV, .sports])
        XCTAssertEqual(TVPrimaryMenuProjection.roots(for: [.builtin(.series), .builtin(.movies)],
                                                     libraries: [], vodTypes: [.movies]),
                       [.home, .libraryType(.movies), .liveTV, .sports], "Series stays hidden without a source")
        // A tab missing from the stored menu is added before Live TV, not after Sports.
        XCTAssertEqual(TVPrimaryMenuProjection.roots(for: [.builtin(.home)], libraries: [movieLibrary],
                                                     vodTypes: [.series]),
                       [.home, .libraryType(.series), .liveTV, .sports])
    }

    func testSiloMenuIsUnchangedWithoutProviders() {
        let stored: [PrimaryMenuItem] = [.builtin(.home), .builtin(.series), .builtin(.movies)]
        XCTAssertEqual(TVPrimaryMenuProjection.roots(for: stored, libraries: [movieLibrary, seriesLibrary]),
                       TVPrimaryMenuProjection.roots(for: stored, libraries: [movieLibrary, seriesLibrary], vodTypes: []))
        XCTAssertEqual(TVPrimaryMenuProjection.roots(for: stored, libraries: [movieLibrary, seriesLibrary], vodTypes: [.movies]),
                       [.home, .libraryType(.series), .libraryType(.movies), .liveTV, .sports],
                       "a provider keeps the user's stored order")
    }

    // MARK: Focus (cascade)

    func testCascadeProviderRowsUseNegativeIDsThatNeverCollideWithLibraries() {
        let rows = TVCascadeProviderRow.rows(for: [xtream("A"), xtream("B")])
        XCTAssertEqual(rows.map(\.rowID), [-1, -2])
        XCTAssertEqual(rows.map(\.name), ["A", "B"])
    }

    func testCascadeMovesThroughLibrariesThenProviders() {
        let pills = TVLibraryPill.allCases
        let ids = [7, -1, -2]
        let providers: Set<Int> = [-1, -2]
        func move(_ from: TVCascadeSelection, _ direction: MoveCommandDirection) -> TVCascadeMove {
            TVCascadeFocusPlanner.move(from: from, direction: direction, libraryIDs: ids, pills: pills,
                                       singleLibrary: false, sectionlessIDs: providers)
        }
        XCTAssertEqual(move(.library(7), .down), .select(.library(-1)))
        XCTAssertEqual(move(.library(-1), .down), .select(.library(-2)))
        XCTAssertEqual(move(.library(-2), .down), .content, "Down past the last row hands focus to the page")
        XCTAssertEqual(move(.library(-1), .up), .select(.library(7)))
        XCTAssertEqual(move(.library(7), .up), .close)
        XCTAssertEqual(move(.library(-1), .right), .stay, "a provider has no section flyout")
        XCTAssertEqual(move(.library(7), .right), .select(.section(7, .recommended)), "Silo sections are unchanged")
        XCTAssertEqual(move(.section(7, .browse), .down), .content)
    }

    func testSingleSiloLibraryCascadeIsUnchangedWithoutProviders() {
        let pills = TVLibraryPill.allCases
        XCTAssertEqual(TVCascadeFocusPlanner.move(from: .section(1, .recommended), direction: .down, libraryIDs: [1],
                                                  pills: pills, singleLibrary: true),
                       .select(.section(1, .collections)))
        XCTAssertEqual(TVCascadeFocusPlanner.move(from: .library(1), direction: .right, libraryIDs: [1],
                                                  pills: pills, singleLibrary: false),
                       .select(.section(1, .recommended)))
    }

    // MARK: Focus (IPTV page)

    func testIPTVPageEntryLandsOnTheFirstTitle() {
        XCTAssertEqual(TVXtreamVODFocusPlanner.entryTarget(itemIDs: ["a", "b"], isLoading: false, mode: .catalog),
                       .firstCard("a"))
        XCTAssertEqual(TVXtreamVODFocusPlanner.entryTarget(itemIDs: ["a"], isLoading: true, mode: .catalog),
                       .firstCard("a"), "cached titles are focusable while a refresh runs")
        XCTAssertEqual(TVXtreamVODFocusPlanner.entryTarget(itemIDs: [], isLoading: true, mode: .catalog), .wait,
                       "the claim waits for titles instead of leaving the page without focus")
        XCTAssertEqual(TVXtreamVODFocusPlanner.entryTarget(itemIDs: [], isLoading: false, mode: .favorites),
                       .mode(.favorites), "an empty page still has a focus owner")
    }

    func testIPTVPagePagesAheadOfFocus() {
        let distance = TVXtreamVODFocusPlanner.pagePrefetchDistance
        XCTAssertFalse(TVXtreamVODFocusPlanner.shouldLoadMore(focusedIndex: 100 - distance - 1, loadedCount: 100,
                                                              hasMore: true, isLoading: false))
        XCTAssertTrue(TVXtreamVODFocusPlanner.shouldLoadMore(focusedIndex: 100 - distance, loadedCount: 100,
                                                             hasMore: true, isLoading: false))
        XCTAssertFalse(TVXtreamVODFocusPlanner.shouldLoadMore(focusedIndex: 99, loadedCount: 100,
                                                              hasMore: false, isLoading: false))
        XCTAssertFalse(TVXtreamVODFocusPlanner.shouldLoadMore(focusedIndex: 99, loadedCount: 100,
                                                              hasMore: true, isLoading: true))
        XCTAssertEqual(XtreamVODBrowseMode.allCases.map(\.title), ["All Titles", "Continue Watching", "Favorites"])
    }

    // MARK: Watch-history separation

    func testIPTVWatchHistoryStaysLocalAndScopedToItsProvider() async throws {
        let suite = "VideoSourceHistory.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VideoSource-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try XtreamVODCatalogStore(directory: directory)
        let vod = XtreamVODService(store: store, defaults: defaults)
        let first = UUID(), second = UUID()
        func item(_ provider: UUID, _ id: Int) -> XtreamVODItem {
            .init(providerID: provider, kind: .movie, remoteID: id, title: "Title \(id)", category: "Other",
                  poster: nil, fileExtension: "mp4", summary: nil, genre: nil, rating: nil)
        }
        for provider in [first, second] {
            try await store.stage([item(provider, 1), item(provider, 2)], generation: "g")
            try await store.promote(providerID: provider, kind: .movie, generation: "g")
        }
        let before = Set(defaults.dictionaryRepresentation().keys)
        vod.saveProgress(position: 30, duration: 100, item: item(first, 1))
        vod.setFavorite(true, for: item(second, 2))
        let added = Set(defaults.dictionaryRepresentation().keys).subtracting(before)
        XCTAssertFalse(added.isEmpty)
        XCTAssertTrue(added.allSatisfy { $0.hasPrefix("kyro.iptvvod.") }, "IPTV history never writes Silo keys: \(added)")
        let firstInProgress = await vod.personalItems(providerID: first, kind: .movie, favorites: false)
        let secondInProgress = await vod.personalItems(providerID: second, kind: .movie, favorites: false)
        let secondFavorites = await vod.personalItems(providerID: second, kind: .movie, favorites: true)
        XCTAssertEqual(firstInProgress.map(\.remoteID), [1])
        XCTAssertTrue(secondInProgress.isEmpty)
        XCTAssertEqual(secondFavorites.map(\.remoteID), [2])
        await store.close()
    }
}
#endif
