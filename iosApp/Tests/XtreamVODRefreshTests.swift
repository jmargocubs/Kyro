#if os(tvOS)
import Foundation
import XCTest
@testable import Silo

/// Build 94: VOD storage root cause, failure categories, provider response variations, and the
/// manual-refresh coordinator. No real provider or credentials are used.
@MainActor
final class XtreamVODRefreshTests: XCTestCase {
    private final class Secrets: LiveTVSecretStore {
        var values: [String: String] = [:]
        func read(account: String) -> String? { values[account] }
        func save(_ value: String, account: String) -> Bool { values[account] = value; return true }
        func remove(account: String) -> Bool { values[account] = nil; return true }
    }

    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var session: URLSession!
    private var live: LiveTVService!
    private var secrets: Secrets!
    private var stores: [XtreamVODCatalogStore] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("VODRefresh-\(UUID().uuidString)")
        suite = "VODRefresh.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProvider.self]
        session = URLSession(configuration: config)
        secrets = Secrets()
        live = LiveTVService(defaults: defaults, secretStore: secrets, session: session,
                             channelSnapshotStore: LiveTVChannelSnapshotStore(directory: directory.appendingPathComponent("live")))
        StubProvider.reset()
    }

    override func tearDown() async throws {
        live = nil
        for store in stores { await store.close() }
        stores.removeAll()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore(_ name: String = "vod") throws -> XtreamVODCatalogStore {
        let store = try XtreamVODCatalogStore(directory: directory.appendingPathComponent(name))
        stores.append(store)
        return store
    }

    private func service(store: XtreamVODCatalogStore? = nil,
                         factory: (() throws -> XtreamVODCatalogStore)? = nil) throws -> XtreamVODService {
        let initial = factory == nil ? try (store ?? makeStore()) : nil
        return XtreamVODService(store: initial, session: session, defaults: defaults,
                                makeStore: factory ?? { throw XtreamVODError.storage })
    }

    private func provider(live liveTV: Bool = false, movies: Bool = true, series: Bool = true) throws -> UUID {
        try live.saveXtreamConfiguration(name: "Stub", serverURL: "https://vodrefresh.test",
                                         username: "viewer", password: "fake-secret",
                                         selection: .init(liveTV: liveTV, movies: movies, series: series))
    }

    // MARK: Root cause: on-device storage

    func testDefaultStoresLiveUnderCachesBecauseAppleTVRejectsApplicationSupport() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].standardizedFileURL.path
        XCTAssertTrue(XtreamVODCatalogStore.defaultDirectory().standardizedFileURL.path.hasPrefix(caches))
        XCTAssertTrue(LiveTVChannelSnapshotStore.defaultDirectory().standardizedFileURL.path.hasPrefix(caches))
        XCTAssertFalse(XtreamVODCatalogStore.defaultDirectory().path.contains("Application Support"))
    }

    func testStorageFailureIsReportedAsStorageAndRetryReopensTheStore() async throws {
        let id = try provider()
        var attempts = 0
        let healthy = try makeStore("recovered")
        let vod = try service(factory: {
            attempts += 1
            if attempts == 1 { throw XtreamVODError.storage }
            return healthy
        })
        let first = await vod.refresh(providerID: id, liveTV: live)
        XCTAssertEqual(first, .started)
        XCTAssertEqual(vod.progress?.stage, .failed)
        XCTAssertEqual(vod.progress?.failure, .storage)
        XCTAssertEqual(vod.progress?.failedStage, .storage)
        XCTAssertEqual(vod.progress?.movieResult, .failed)
        XCTAssertTrue(StubProvider.actions().isEmpty, "a storage failure stops before any network request")

        // Build 93 kept a nil store for the whole session; a retry must reopen it.
        await vod.refresh(providerID: id, liveTV: live)
        XCTAssertEqual(vod.progress?.stage, .ready)
        let movies = await vod.count(providerID: id, kind: .movie)
        let series = await vod.count(providerID: id, kind: .series)
        XCTAssertEqual(movies, 2)
        XCTAssertEqual(series, 1)
    }

    func testUnwritableDirectoryThrowsStorage() throws {
        let file = directory.appendingPathComponent("not-a-directory")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: file)
        XCTAssertThrowsError(try XtreamVODCatalogStore(directory: file.appendingPathComponent("child"))) {
            XCTAssertEqual($0 as? XtreamVODError, .storage)
        }
    }

    // MARK: Failure categories

    func testMissingCredentialsAreConfigurationWithoutRequests() async throws {
        let id = try provider()
        let vod = try service()
        // A provider whose keychain entry is gone.
        secrets.values.removeAll()
        await vod.refresh(providerID: id, liveTV: live)
        XCTAssertEqual(vod.progress?.failure, .configuration)
        XCTAssertEqual(vod.progress?.failedStage, .configuration)
        XCTAssertTrue(StubProvider.actions().isEmpty)
    }

    func testHTTPServerErrorAndNetworkFailureAreDistinct() async throws {
        let id = try provider(series: false)
        let vod = try service()
        StubProvider.status["get_vod_streams"] = 503
        await vod.refresh(providerID: id, liveTV: live)
        XCTAssertEqual(vod.progress?.failure, .httpStatus(503))
        XCTAssertEqual(vod.progress?.failedStage, .download)
        XCTAssertEqual(XtreamVODError.httpStatus(503).category, "http_status")

        StubProvider.reset()
        StubProvider.networkFailure = ["get_vod_streams"]
        await vod.refresh(providerID: id, liveTV: live)
        XCTAssertEqual(vod.progress?.failure, .network)
    }

    func testAccountHandshakeRejectionIsAuthentication() async throws {
        let id = try provider()
        let vod = try service()
        StubProvider.body["auth"] = #"{"user_info":{"auth":0}}"#
        await vod.refresh(providerID: id, liveTV: live)
        XCTAssertEqual(vod.progress?.failure, .authentication)
        XCTAssertEqual(vod.progress?.failedStage, .authentication)
        XCTAssertEqual(vod.progress?.movieResult, .authentication)
        XCTAssertEqual(vod.progress?.seriesResult, .authentication)
        XCTAssertEqual(StubProvider.actions(), ["auth"])
    }

    func testHTMLCatalogIsInvalidResponseAtParsingStage() async throws {
        let id = try provider(series: false)
        let vod = try service()
        StubProvider.body["get_vod_streams"] = "<html><body>Bad gateway</body></html>"
        await vod.refresh(providerID: id, liveTV: live)
        XCTAssertEqual(vod.progress?.failure, .invalidResponse)
        XCTAssertEqual(vod.progress?.failedStage, .parsing)
    }

    // MARK: Provider response variations

    func testParserAcceptsLegitimateProviderShapes() throws {
        XCTAssertEqual(try XtreamVODParser.records(Data()).count, 0)
        XCTAssertEqual(try XtreamVODParser.records(Data("null".utf8)).count, 0)
        XCTAssertEqual(try XtreamVODParser.records(Data("{}".utf8)).count, 0)
        XCTAssertEqual(try XtreamVODParser.records(Data("  \n[]".utf8)).count, 0)
        let bom = Data([0xEF, 0xBB, 0xBF]) + Data(#"[{"stream_id":1,"name":"A"}]"#.utf8)
        XCTAssertEqual(try XtreamVODParser.records(bom).first?.remoteID, 1)
        let mixed = try XtreamVODParser.records(Data(#"[null,{"stream_id":"7","name":"Seven","category_id":3},5,{"series_id":8,"name":"Eight"}]"#.utf8))
        XCTAssertEqual(mixed.compactMap(\.remoteID), [7, 8])
        XCTAssertEqual(mixed.first?.categoryID, "3")
        let keyed = try XtreamVODParser.records(Data(#"{"2":{"stream_id":2,"name":"Two"},"10":{"stream_id":10,"name":"Ten"}}"#.utf8))
        XCTAssertEqual(keyed.compactMap(\.remoteID), [2, 10])
        XCTAssertThrowsError(try XtreamVODParser.records(Data(#"{"user_info":{"auth":0}}"#.utf8))) {
            XCTAssertEqual($0 as? XtreamVODError, .authentication)
        }
        XCTAssertThrowsError(try XtreamVODParser.records(Data("<html>".utf8))) {
            XCTAssertEqual($0 as? XtreamVODError, .invalidResponse)
        }
    }

    // MARK: Independent catalogs and atomic updates

    func testMoviesFailureKeepsSeriesAndPreviousMovies() async throws {
        let id = try provider()
        let vod = try service()
        await vod.refresh(providerID: id, liveTV: live)
        let before = await vod.count(providerID: id, kind: .movie)
        XCTAssertEqual(before, 2)
        StubProvider.status["get_vod_streams"] = 500
        StubProvider.body["get_series"] = #"[{"series_id":9,"name":"Show"},{"series_id":10,"name":"Other"}]"#
        await vod.refresh(providerID: id, liveTV: live)
        XCTAssertEqual(vod.progress?.movieResult, .failed)
        XCTAssertEqual(vod.progress?.seriesResult, .ready)
        let movies = await vod.count(providerID: id, kind: .movie)
        let series = await vod.count(providerID: id, kind: .series)
        XCTAssertEqual(movies, 2, "a failed movie import leaves the previous movie catalog")
        XCTAssertEqual(series, 2, "series promotes independently")
        XCTAssertTrue(vod.progress?.message?.contains("Successful catalogs are available") == true)
    }

    func testEmptyAnswerNeverReplacesPreviousCatalog() async throws {
        let id = try provider(series: false)
        let vod = try service()
        await vod.refresh(providerID: id, liveTV: live)
        StubProvider.body["get_vod_streams"] = "[]"
        await vod.refresh(providerID: id, liveTV: live)
        XCTAssertEqual(vod.progress?.movieResult, .empty)
        let movies = await vod.count(providerID: id, kind: .movie)
        XCTAssertEqual(movies, 2)
    }

    // MARK: Refresh entry points

    func testVODRefreshWithNothingSelectedExplainsInsteadOfDoingNothing() async throws {
        let id = try provider(live: true, movies: false, series: false)
        let vod = try service()
        let start = await vod.refresh(providerID: id, liveTV: live)
        XCTAssertEqual(start, .noCatalogsSelected)
        XCTAssertEqual(vod.progress?.stage, .failed)
        XCTAssertTrue(vod.progress?.message?.contains("Enable Movies or Series") == true)
        XCTAssertEqual(vod.startedRefreshCount, 0)
        XCTAssertTrue(StubProvider.actions().isEmpty)
    }

    func testRefreshButtonStartsRealWorkAndRefusesADuplicate() async throws {
        let id = try provider()
        let vod = try service()
        let coordinator = TVProviderRefreshCoordinator()
        StubProvider.delayNanoseconds = 200_000_000
        XCTAssertEqual(coordinator.refresh(providerID: id, scope: .vodOnly, liveTV: live, vod: vod), .started)
        XCTAssertTrue(coordinator.isRunning(providerID: id), "feedback is immediate")
        XCTAssertEqual(coordinator.refresh(providerID: id, scope: .vodOnly, liveTV: live, vod: vod), .alreadyRunning)
        await coordinator.waitForCompletion()
        XCTAssertEqual(vod.startedRefreshCount, 1)
        XCTAssertEqual(Set(StubProvider.actions()),
                       Set(["auth", "get_vod_categories", "get_vod_streams", "get_series_categories", "get_series"]))
        guard case .finished(let finishedID, let succeeded, let message) = coordinator.phase else {
            return XCTFail("refresh must end with a visible result")
        }
        XCTAssertEqual(finishedID, id)
        XCTAssertTrue(succeeded)
        XCTAssertTrue(message.contains("2 movies"), message)
        coordinator.dismissResult()
        XCTAssertEqual(coordinator.phase, .idle)
    }

    func testDirectVODDuplicateIsRefused() async throws {
        let id = try provider()
        let vod = try service()
        StubProvider.delayNanoseconds = 200_000_000
        let first = Task { await vod.refresh(providerID: id, liveTV: live) }
        for _ in 0..<1_000 where !vod.isRefreshing { await Task.yield() }
        XCTAssertTrue(vod.isRefreshing)
        let second = await vod.refresh(providerID: id, liveTV: live)
        let firstResult = await first.value
        XCTAssertEqual(firstResult, .started)
        XCTAssertEqual(second, .alreadyRunning)
        XCTAssertEqual(vod.startedRefreshCount, 1)
    }

    func testCoordinatorReportsFailureAndNothingSelected() async throws {
        let id = try provider()
        let vod = try service()
        let coordinator = TVProviderRefreshCoordinator()
        StubProvider.status["auth"] = 401
        coordinator.refresh(providerID: id, scope: .vodOnly, liveTV: live, vod: vod)
        await coordinator.waitForCompletion()
        guard case .finished(_, let succeeded, let message) = coordinator.phase else { return XCTFail() }
        XCTAssertFalse(succeeded)
        XCTAssertTrue(message.contains("authentication"), message)

        let liveOnly = try provider(live: true, movies: false, series: false)
        let result = coordinator.refresh(providerID: liveOnly, scope: .vodOnly, liveTV: live, vod: vod)
        guard case .nothingToRefresh(let reason) = result else { return XCTFail("\(result)") }
        XCTAssertTrue(reason.contains("Enable Movies"), reason)
    }

    // MARK: Presentation

    func testOnlyFirstTimeSetupUsesFullScreenPresentation() async throws {
        let vodOnly = try provider(live: false)
        await live.startSetup(providerID: vodOnly)
        XCTAssertEqual(live.importProgress?.presentation, .onboarding)
        live.clearFinishedImport()

        let liveProvider = try live.saveConfiguration(name: "M3U", playlistURL: "https://vodrefresh.test/list.m3u",
                                                      xmltvURL: "", selection: .legacyLiveOnly)
        await live.refresh(providerID: liveProvider)
        XCTAssertEqual(live.importProgress?.presentation, .compact, "manual refresh never goes full screen")
        XCTAssertEqual(live.importProgress?.isOnboarding, false)
        live.clearFinishedImport()
        await live.startSetup(providerID: liveProvider)
        XCTAssertEqual(live.importProgress?.presentation, .onboarding)
    }

    func testAddProviderFocusReturnsPredictably() {
        let id = UUID()
        XCTAssertEqual(TVLiveTVProviderFocusPlanner.afterAddProvider(savedProviderID: id), .provider(id))
        XCTAssertEqual(TVLiveTVProviderFocusPlanner.afterAddProvider(savedProviderID: nil), .addProvider)
        XCTAssertFalse(TVLiveTVProviderFocusPlanner.escapesToBack(.addProvider, providerIDs: [id]))
    }

    func testProviderSummaryShowsAvailableContent() throws {
        let id = try provider(live: true, movies: true, series: false)
        let summary = TVProviderSummary.line(for: try XCTUnwrap(live.providers.first { $0.id == id }))
        XCTAssertTrue(summary.hasPrefix("Xtream Codes · 0 channels"), summary)
        XCTAssertTrue(summary.hasSuffix("Movies"), summary)
    }
}

/// Configurable Xtream stub. Bodies and statuses are keyed by `action` ("auth" for the handshake).
private final class StubProvider: URLProtocol {
    private static let lock = NSLock()
    static var body: [String: String] = [:]
    static var status: [String: Int] = [:]
    static var networkFailure: Set<String> = []
    static var delayNanoseconds: UInt64 = 0
    private static var recorded: [String] = []

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        body = [:]; status = [:]; networkFailure = []; delayNanoseconds = 0; recorded = []
    }

    static func actions() -> [String] { lock.lock(); defer { lock.unlock() }; return recorded }

    private static let defaults: [String: String] = [
        "auth": #"{"user_info":{"auth":1,"status":"Active"}}"#,
        "get_vod_categories": #"[{"category_id":"1","category_name":"Drama"}]"#,
        "get_series_categories": "[]",
        "get_vod_streams": #"[{"stream_id":1,"name":"Alpha","category_id":"1","container_extension":"mp4"},{"stream_id":2,"name":"Beta","container_extension":"mp4"}]"#,
        "get_series": #"[{"series_id":"9","name":"Show"}]"#,
    ]

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "vodrefresh.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let action = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "action" })?.value ?? (url.path.hasSuffix(".m3u") ? "playlist" : "auth")
        Self.lock.lock()
        Self.recorded.append(action)
        let failure = Self.networkFailure.contains(action)
        let code = Self.status[action] ?? 200
        let text = Self.body[action] ?? Self.defaults[action] ?? "#EXTM3U\n#EXTINF:-1,One\nhttps://vodrefresh.test/1.m3u8\n"
        let delay = Self.delayNanoseconds
        Self.lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(delay))) {
            if failure {
                self.client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
                return
            }
            guard let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil) else { return }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data(text.utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
#endif
