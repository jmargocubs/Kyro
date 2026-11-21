#if os(tvOS)
import Foundation
import XCTest
@testable import Silo

@MainActor
final class XtreamVODTests: XCTestCase {
    private final class Secrets: LiveTVSecretStore {
        var values: [String: String] = [:]
        func read(account: String) -> String? { values[account] }
        func save(_ value: String, account: String) -> Bool { values[account] = value; return true }
        func remove(account: String) -> Bool { values[account] = nil; return true }
    }

    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var live: LiveTVService!
    private var vod: XtreamVODService!
    private var catalogStores: [XtreamVODCatalogStore] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("VODTests-\(UUID().uuidString)")
        suite = "VODTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [VODURLProtocol.self]
        let session = URLSession(configuration: config)
        live = LiveTVService(defaults: defaults, secretStore: Secrets(), session: session,
                             channelSnapshotStore: LiveTVChannelSnapshotStore(directory: directory.appendingPathComponent("live")))
        let store = try XtreamVODCatalogStore(directory: directory)
        catalogStores.append(store)
        vod = XtreamVODService(store: store, session: session, defaults: defaults)
        VODURLProtocol.mode = .normal
        VODURLProtocol.resetActions()
    }

    override func tearDown() async throws {
        vod = nil
        live = nil
        for store in catalogStores { await store.close() }
        catalogStores.removeAll()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    private func add(_ name: String) throws -> UUID {
        let id = try live.saveXtreamConfiguration(name: name, serverURL: "https://vod.test",
                                                  username: "viewer", password: "fake-secret")
        live.setVODEnabled(true, for: id)
        return id
    }

    /// The detail view's Favorite label refreshes from `revision`; the watch state itself lives in
    /// UserDefaults, which SwiftUI cannot observe. A save that did not bump it left "Add Favorite"
    /// on screen after Select.
    func testSettingAFavoriteSavesItAndBumpsTheObservedRevision() throws {
        let item = XtreamVODItem(providerID: UUID(), kind: .movie, remoteID: 7, title: "Fixture",
                                 category: "Fixtures", poster: nil, fileExtension: "mp4",
                                 summary: nil, genre: nil, rating: nil)
        let before = vod.revision
        XCTAssertFalse(vod.watchState(for: item).favorite)
        vod.setFavorite(true, for: item)
        XCTAssertTrue(vod.watchState(for: item).favorite)
        XCTAssertGreaterThan(vod.revision, before)
        let afterOn = vod.revision
        vod.setFavorite(false, for: item)
        XCTAssertFalse(vod.watchState(for: item).favorite)
        XCTAssertGreaterThan(vod.revision, afterOn)
    }

    func testVODIsOptInAndKindsCanBeEnabledIndependently() async throws {
        let id = try live.saveXtreamConfiguration(name: "Opt in", serverURL: "https://vod.test",
                                                   username: "viewer", password: "fake-secret")
        let initial = try XCTUnwrap(live.providers.first { $0.id == id })
        XCTAssertFalse(initial.vodEnabled)
        XCTAssertFalse(initial.vodMoviesEnabled)
        XCTAssertFalse(initial.vodSeriesEnabled)
        XCTAssertNil(live.xtreamVODConfiguration(for: id))
        live.setVODEnabled(true, kind: "movie", for: id)
        XCTAssertNotNil(live.xtreamVODConfiguration(for: id))
        XCTAssertTrue(live.providers.first { $0.id == id }?.vodMoviesEnabled == true)
        XCTAssertFalse(live.providers.first { $0.id == id }?.vodSeriesEnabled == true)
        await vod.refresh(providerID: id, liveTV: live)
        XCTAssertEqual(vod.progress?.stage, .ready)
        let movieCount = await vod.count(providerID: id, kind: .movie)
        let seriesCount = await vod.count(providerID: id, kind: .series)
        XCTAssertEqual(movieCount, 2)
        XCTAssertEqual(seriesCount, 0)
        XCTAssertNotNil(vod.refreshedAt(providerID: id))
        await vod.clearCache(providerID: id)
        let clearedCount = await vod.count(providerID: id, kind: .movie)
        XCTAssertEqual(clearedCount, 0)
        XCTAssertNil(vod.refreshedAt(providerID: id))
        XCTAssertNotNil(live.xtreamVODConfiguration(for: id), "cache clearing must retain credentials")
    }

    func testSetupDoesNotCompleteBeforeEnabledVODFinishes() {
        XCTAssertFalse(TVProviderSetupState.isComplete(live: .guide, vodEnabled: false, vod: nil))
        XCTAssertTrue(TVProviderSetupState.isComplete(live: .ready, vodEnabled: false, vod: nil))
        XCTAssertFalse(TVProviderSetupState.isComplete(live: .ready, vodEnabled: true, vod: nil))
        XCTAssertFalse(TVProviderSetupState.isComplete(live: .ready, vodEnabled: true, vod: .downloading(.movie)))
        XCTAssertFalse(TVProviderSetupState.isComplete(live: .ready, vodEnabled: true, vod: .importing(.series)))
        XCTAssertTrue(TVProviderSetupState.isComplete(live: .ready, vodEnabled: true, vod: .ready))
        XCTAssertTrue(TVProviderSetupState.isComplete(live: .ready, vodEnabled: true, vod: .failed))
        XCTAssertFalse(TVProviderSetupState.isComplete(live: .ready, liveSelected: false, vodEnabled: true, vod: nil))
        XCTAssertTrue(TVProviderSetupState.isComplete(live: .ready, liveSelected: false, vodEnabled: true, vod: .ready))
    }

    func testAllContentSelectionsAndNewProviderDefaults() throws {
        XCTAssertEqual(IPTVContentSelection.newProvider(for: .xtream),
                       .init(liveTV: true, movies: true, series: true))
        XCTAssertEqual(IPTVContentSelection.newProvider(for: .m3u), .legacyLiveOnly)
        for bits in 0..<8 {
            let selection = IPTVContentSelection(liveTV: bits & 1 != 0, movies: bits & 2 != 0,
                                                 series: bits & 4 != 0)
            XCTAssertEqual(selection.isValid(for: .xtream), bits != 0)
            XCTAssertEqual(selection.isValid(for: .m3u), bits == 1)
            if bits == 0 { continue }
            let id = try live.saveXtreamConfiguration(name: "Choice \(bits)", serverURL: "https://vod.test",
                                                       username: "viewer", password: "fake-secret", selection: selection)
            XCTAssertEqual(live.providers.first(where: { $0.id == id })?.contentSelection, selection)
        }
    }

    func testMovieOnlyProviderSkipsLiveAndSeriesRequests() async throws {
        let selection = IPTVContentSelection(liveTV: false, movies: true, series: false)
        let id = try live.saveXtreamConfiguration(name: "Movies only", serverURL: "https://vod.test",
                                                   username: "viewer", password: "fake-secret", selection: selection)
        await live.startSetup(providerID: id)
        XCTAssertEqual(live.importProgress?.stage, .ready)
        XCTAssertEqual(live.importProgress?.count.accepted, 0)
        XCTAssertTrue(VODURLProtocol.actions().isEmpty)
        await vod.refresh(providerID: id, liveTV: live)
        XCTAssertEqual(vod.progress?.movieResult, .ready)
        XCTAssertEqual(vod.progress?.seriesResult, .notSelected)
        let movies = await vod.count(providerID: id, kind: .movie)
        let series = await vod.count(providerID: id, kind: .series)
        XCTAssertEqual(movies, 2)
        XCTAssertEqual(series, 0)
        XCTAssertEqual(Set(VODURLProtocol.actions()), Set(["auth", "get_vod_categories", "get_vod_streams"]))
    }

    func testLegacyProviderKeepsLiveOnlyAfterDecode() throws {
        let old = "{\"id\":\"\(UUID().uuidString)\",\"name\":\"Old\",\"channelCount\":4,\"kind\":\"xtream\"}"
        let provider = try JSONDecoder().decode(LiveTVProvider.self, from: Data(old.utf8))
        XCTAssertEqual(provider.contentSelection, .legacyLiveOnly)
    }

    func testSeriesOnlySkipsMovieEndpoints() async throws {
        let selection = IPTVContentSelection(liveTV: false, movies: false, series: true)
        let id = try live.saveXtreamConfiguration(name: "Series only", serverURL: "https://vod.test",
                                                   username: "viewer", password: "fake-secret", selection: selection)
        await live.startSetup(providerID: id)
        await vod.refresh(providerID: id, liveTV: live)
        XCTAssertEqual(vod.progress?.movieResult, .notSelected)
        XCTAssertEqual(vod.progress?.seriesResult, .ready)
        XCTAssertEqual(Set(VODURLProtocol.actions()), Set(["auth", "get_series_categories", "get_series"]))
    }

    func testUnsupportedAndAuthenticationFailuresAreDistinct() async throws {
        let id = try add("Provider")
        VODURLProtocol.mode = .unsupported
        await vod.refresh(providerID: id, liveTV: live)
        XCTAssertEqual(vod.progress?.failure, .unsupported)
        XCTAssertEqual(vod.progress?.movieResult, .unsupported)
        XCTAssertEqual(vod.progress?.seriesResult, .ready)
        VODURLProtocol.mode = .authentication
        await vod.refresh(providerID: id, liveTV: live)
        XCTAssertEqual(vod.progress?.failure, .authentication)
        XCTAssertEqual(vod.progress?.movieResult, .authentication)
        XCTAssertEqual(vod.progress?.seriesResult, .authentication)
    }

    func testEmptySelectedCatalogIsNotReportedReady() async throws {
        let id = try add("Empty catalog")
        VODURLProtocol.mode = .emptyMovies
        await vod.refresh(providerID: id, liveTV: live)
        XCTAssertEqual(vod.progress?.stage, .ready)
        XCTAssertEqual(vod.progress?.movieResult, .empty)
        XCTAssertEqual(vod.progress?.seriesResult, .ready)
        XCTAssertEqual(vod.progress?.movies.accepted, 0)
    }

    func testBuild92ProviderMigrationPreservesOptIn() throws {
        let id = UUID()
        let oldEnabled = "{\"id\":\"\(id.uuidString)\",\"name\":\"Previous\",\"channelCount\":4,\"kind\":\"xtream\",\"vodEnabled\":true}"
        let provider = try JSONDecoder().decode(LiveTVProvider.self, from: Data(oldEnabled.utf8))
        XCTAssertTrue(provider.vodMoviesEnabled)
        XCTAssertTrue(provider.vodSeriesEnabled)
    }

    func testProviderScopedImportCountsLazyEpisodesAndPlaybackURL() async throws {
        let first = try add("One")
        await vod.refresh(providerID: first, liveTV: live)
        XCTAssertEqual(vod.progress?.stage, .ready)
        XCTAssertEqual(vod.progress?.movies, .init(processed: 4, total: 4, accepted: 2, malformed: 1, duplicate: 1))
        XCTAssertEqual(vod.progress?.series, .init(processed: 1, total: 1, accepted: 1, malformed: 0, duplicate: 0))
        let movies = await vod.page(providerID: first, kind: .movie)
        XCTAssertEqual(movies.map(\.title), ["Alpha", "Beta"])
        XCTAssertEqual(movies.first?.category, "Drama")
        XCTAssertNil(movies.first?.poster, "query-bearing artwork is never persisted")
        let seriesPage = await vod.page(providerID: first, kind: .series)
        let series = try XCTUnwrap(seriesPage.first)
        let detail = try await vod.detail(for: series, liveTV: live)
        XCTAssertEqual(detail.episodes.map(\.remoteID), [1001, 1002])
        let playback = try vod.playbackURL(for: series, episode: detail.episodes.first, liveTV: live)
        XCTAssertEqual(playback.path, "/series/viewer/fake-secret/1001.mp4")
        XCTAssertNil(playback.query)
        XCTAssertThrowsError(try vod.playbackURL(for: movies[1], liveTV: live), "mkv must not be offered as native playback")
        vod.setFavorite(true, for: movies[0])
        vod.saveProgress(position: 42, duration: 100, item: movies[0])
        XCTAssertTrue(vod.watchState(for: movies[0]).favorite)
        XCTAssertEqual(vod.watchState(for: movies[0]).position, 42)
        let favorites = await vod.personalItems(providerID: first, kind: .movie, favorites: true)
        let inProgress = await vod.personalItems(providerID: first, kind: .movie, favorites: false)
        XCTAssertEqual(favorites.map(\.remoteID), [1])
        XCTAssertEqual(inProgress.map(\.remoteID), [1])

        let second = try add("Two")
        let secondPage = await vod.page(providerID: second, kind: .movie)
        XCTAssertTrue(secondPage.isEmpty)
    }

    func testFailedRefreshRetainsEarlierMovieAndSeriesGenerations() async throws {
        let id = try add("Provider")
        await vod.refresh(providerID: id, liveTV: live)
        let firstCount = await vod.count(providerID: id, kind: .movie)
        XCTAssertEqual(firstCount, 2)
        VODURLProtocol.mode = .badSeries
        await vod.refresh(providerID: id, liveTV: live)
        XCTAssertEqual(vod.progress?.stage, .failed)
        XCTAssertEqual(vod.progress?.movieResult, .ready)
        XCTAssertEqual(vod.progress?.seriesResult, .failed)
        let retainedMovies = await vod.count(providerID: id, kind: .movie)
        let retainedSeries = await vod.count(providerID: id, kind: .series)
        XCTAssertEqual(retainedMovies, 2)
        XCTAssertEqual(retainedSeries, 1)
        VODURLProtocol.mode = .normal
        await vod.refresh(providerID: id, liveTV: live)
        XCTAssertEqual(vod.progress?.stage, .ready)
    }

    func testStagedCatalogIsInvisibleUntilPromotionAndRemovalIsScoped() async throws {
        let store = try XtreamVODCatalogStore(directory: directory.appendingPathComponent("direct"))
        catalogStores.append(store)
        let first = UUID(), second = UUID()
        func item(_ provider: UUID, _ title: String) -> XtreamVODItem {
            .init(providerID: provider, kind: .movie, remoteID: 7, title: title, category: "Other",
                  poster: nil, fileExtension: "mp4", summary: nil, genre: nil, rating: nil)
        }
        try await store.stage([item(first, "Old")], generation: "old")
        try await store.promote(providerID: first, kind: .movie, generation: "old")
        try await store.stage([item(first, "New")], generation: "new")
        try await store.stage([item(second, "Other Provider")], generation: "other")
        try await store.promote(providerID: second, kind: .movie, generation: "other")
        let before = await store.page(providerID: first, kind: .movie)
        XCTAssertEqual(before.map(\.title), ["Old"])
        await store.discard(providerID: first, kind: .movie, generation: "new")
        let after = await store.page(providerID: first, kind: .movie)
        XCTAssertEqual(after.map(\.title), ["Old"])
        await store.remove(providerID: first)
        let remaining = await store.page(providerID: second, kind: .movie)
        XCTAssertEqual(remaining.map(\.title), ["Other Provider"])
    }

    func testFiftyThousandMoviesAndTwentyThousandSeriesStayPaged() async throws {
        let store = try XtreamVODCatalogStore(directory: directory.appendingPathComponent("large"))
        catalogStores.append(store)
        let provider = UUID()
        let start = DispatchTime.now().uptimeNanoseconds
        for (kind, amount) in [(XtreamVODKind.movie, 50_000), (.series, 20_000)] {
            for base in stride(from: 0, to: amount, by: 500) {
                let batch = (base..<min(base + 500, amount)).map { index in
                    XtreamVODItem(providerID: provider, kind: kind, remoteID: index + 1,
                                   title: "Title \(index)", category: "Category", poster: nil,
                                   fileExtension: kind == .movie ? "mp4" : nil,
                                   summary: nil, genre: nil, rating: nil)
                }
                try await store.stage(batch, generation: kind.rawValue)
            }
        }
        try await store.promoteAll(providerID: provider, generations: [(.movie, "movie"), (.series, "series")])
        let movies = await store.count(providerID: provider, kind: .movie)
        let series = await store.count(providerID: provider, kind: .series)
        let moviePage = await store.page(providerID: provider, kind: .movie, offset: 49_900)
        let seriesPage = await store.page(providerID: provider, kind: .series)
        XCTAssertEqual(movies, 50_000)
        XCTAssertEqual(series, 20_000)
        XCTAssertEqual(moviePage.count, 100)
        XCTAssertEqual(seriesPage.count, 100)
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        print("VOD-BENCH movies=50000 series=20000 elapsed_s=\(String(format: "%.2f", seconds)) footprint_mb=\(KyroSyntheticCatalog.footprintMB())")
    }
}

private final class VODURLProtocol: URLProtocol {
    enum Mode: Equatable { case normal, badSeries, unsupported, authentication, emptyMovies }
    static var mode: Mode = .normal
    private static let actionsLock = NSLock()
    private static var recordedActions: [String] = []
    static func resetActions() { actionsLock.lock(); defer { actionsLock.unlock() }; recordedActions = [] }
    static func actions() -> [String] { actionsLock.lock(); defer { actionsLock.unlock() }; return recordedActions }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "vod.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let action = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "action" })?.value
        Self.actionsLock.lock()
        Self.recordedActions.append(action ?? "auth")
        Self.actionsLock.unlock()
        let body: String
        switch action {
        case nil: body = #"{"user_info":{"auth":1,"status":"Active"}}"#
        case "get_vod_categories": body = #"[{"category_id":"1","category_name":"Drama"}]"#
        case "get_series_categories": body = "[]"
        case "get_vod_streams": body = Self.mode == .emptyMovies ? "[]" : #"[{"stream_id":1,"name":"Alpha","category_id":"1","stream_icon":"https://art.test/a.jpg?token=sensitive","container_extension":"mp4"},{"stream_id":2,"name":"Beta","container_extension":"mkv"},{"stream_id":2,"name":"Duplicate"},{"stream_id":3,"name":""}]"#
        case "get_series": body = Self.mode == .badSeries ? "not-json" : #"[{"series_id":"9","name":"Show","cover":"https://art.test/show.jpg"}]"#
        case "get_series_info": body = #"{"info":{"plot":"A show"},"episodes":{"2":[{"id":"1002","episode_num":1,"title":"Second","container_extension":"mp4"}],"1":[{"id":1001,"episode_num":1,"title":"First","container_extension":"mp4"}]}}"#
        case "get_vod_info": body = #"{"info":{"plot":"A movie","duration_secs":3600}}"#
        default: body = "{}"
        }
        let statusCode = Self.mode == .authentication ? 401 : (Self.mode == .unsupported && action == "get_vod_streams" ? 404 : 200)
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif
