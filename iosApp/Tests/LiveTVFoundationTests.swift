import Foundation
import AVFoundation
import UIKit
import XCTest
@testable import Silo

@MainActor
final class LiveTVFoundationTests: XCTestCase {
    func testM3UParsesMetadataAndDeduplicatesStableChannelIDs() throws {
        let providerID = UUID(uuidString: "A1F4C8A0-CB4C-4B3D-9F73-9AA2BDA7C6B0")!
        let source = #"""
        #EXTM3U
        #EXTINF:-1 tvg-id="news.one" tvg-logo="https://logos.example.test/news.png" group-title="News, Local",News One
        https://streams.example.test/news/index.m3u8?token=private
        #EXTINF:-1 tvg-id="news.one" group-title="Duplicate",Different duplicate label
        https://streams.example.test/news-copy/index.m3u8
        #EXTINF:-1 group-title="Sports",Sports One
        https://streams.example.test/sports/index.m3u8
        """#

        let channels = try LiveTVM3UParser.parse(data: Data(source.utf8), providerID: providerID)
        XCTAssertEqual(channels.count, 2)
        XCTAssertEqual(channels[0].name, "News One")
        XCTAssertEqual(channels[0].guideID, "news.one")
        XCTAssertEqual(channels[0].category, "News, Local")
        XCTAssertEqual(channels[0].logoURL?.host, "logos.example.test")
        XCTAssertEqual(channels[1].category, "Sports")
        XCTAssertEqual(channels[0].id, try XCTUnwrap(
            LiveTVM3UParser.parse(data: Data(source.utf8), providerID: providerID).first?.id
        ))
    }

    func testM3URejectsMalformedAndNonHTTPStreamsWithoutInventingChannels() throws {
        let providerID = UUID()
        let source = #"""
        #EXTM3U
        #EXTINF:-1,Missing URL
        #EXTINF:-1,Relative URL
        /relative/path.m3u8
        #EXTINF:-1,Unsupported Scheme
        rtmp://stream.example.test/live
        #EXTINF:-1,Valid
        https://stream.example.test/live/index.m3u8
        """#
        let channels = try LiveTVM3UParser.parse(data: Data(source.utf8), providerID: providerID)
        XCTAssertEqual(channels.map(\.name), ["Valid"])
    }

    func testProviderURLAndGuideTokensStayOutOfUserDefaultsAndErrorsAreGeneric() throws {
        let suiteName = "LiveTVFoundationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let secrets = MemoryLiveTVSecretStore()
        let service = LiveTVService(defaults: defaults, secretStore: secrets)
        let token = "playlist-token-should-not-leak"
        let guideToken = "guide-token-should-not-leak"

        let providerID = try service.saveConfiguration(
            name: "Test provider",
            playlistURL: "https://example.test/playlist.m3u?token=\(token)",
            xmltvURL: "https://example.test/guide.xml?auth=\(guideToken)"
        )
        let metadata = try XCTUnwrap(defaults.data(forKey: "liveTV.providers.v1"))
        let serializedMetadata = try XCTUnwrap(String(data: metadata, encoding: .utf8))
        XCTAssertFalse(serializedMetadata.contains(token))
        XCTAssertFalse(serializedMetadata.contains(guideToken))
        XCTAssertTrue(secrets.values["provider.\(providerID.uuidString)"]?.contains(token) == true)
        XCTAssertTrue(secrets.values["provider.\(providerID.uuidString)"]?.contains(guideToken) == true)
        XCTAssertFalse(LiveTVError.providerRejected.localizedDescription.contains(token))
    }

    func testChannelSearchAndFavoritesFiltering() throws {
        let providerID = UUID()
        let source = #"""
        #EXTM3U
        #EXTINF:-1 group-title="Local News",North News
        https://example.test/north.m3u8
        #EXTINF:-1 group-title="Sports",North Sports
        https://example.test/sports.m3u8
        #EXTINF:-1 group-title="News",World News
        https://example.test/world.m3u8
        """#
        let channels = try LiveTVM3UParser.parse(data: Data(source.utf8), providerID: providerID)
        let favorites: Set<String> = [try XCTUnwrap(channels.first?.id)]

        XCTAssertEqual(LiveTVChannelFiltering.filter(
            channels, query: "north", category: nil, favoritesOnly: false, favoriteIDs: favorites
        ).map(\.name), ["North News", "North Sports"])
        XCTAssertEqual(LiveTVChannelFiltering.filter(
            channels, query: "news", category: "News", favoritesOnly: false, favoriteIDs: favorites
        ).map(\.name), ["World News"])
        XCTAssertEqual(LiveTVChannelFiltering.filter(
            channels, query: "", category: nil, favoritesOnly: true, favoriteIDs: favorites
        ).map(\.name), ["North News"])
    }

    func testLargeCatalogSearchRunsCancellableAndReturnsStableMatchingChannels() async throws {
        let channels = (0..<20_000).map { index in
            LiveTVChannel(id: "provider:\(index)", guideID: nil, name: "Channel \(index)",
                          streamURL: URL(string: "https://fixture.invalid/\(index).m3u8")!, logoURL: nil,
                          category: index.isMultiple(of: 2) ? "Sports" : "News")
        }
        let search = LiveTVChannelSearchModel()
        search.update(channels: channels, query: "Channel 19999", category: "News", favoritesOnly: false,
                      favoriteIDs: [], debounce: .zero)
        await search.waitForCurrentSearch()
        XCTAssertEqual(search.resultCount, 1)
        XCTAssertEqual(search.groups["News"]?.first?.id, "provider:19999")

        search.update(channels: channels, query: "Channel 2", category: "Sports", favoritesOnly: false,
                      favoriteIDs: [], debounce: .seconds(1))
        search.update(channels: channels, query: "Channel 18000", category: "Sports", favoritesOnly: false,
                      favoriteIDs: [], debounce: .zero)
        await search.waitForCurrentSearch()
        XCTAssertEqual(search.groups.values.flatMap { $0 }.map(\.id), ["provider:18000"])
        search.cancel()
        XCTAssertEqual(search.resultCount, 0)
    }

    func testFavoriteAndCategoryFilteringKeepsStableChannelIdentity() throws {
        let providerID = UUID()
        let channels = try LiveTVM3UParser.parse(data: Data(#"""
        #EXTM3U
        #EXTINF:-1 group-title="Sports",Match One
        https://fixture.invalid/match-one.m3u8
        #EXTINF:-1 group-title="News",Daily News
        https://fixture.invalid/news.m3u8
        """#.utf8), providerID: providerID)
        let favorite = try XCTUnwrap(channels.first)
        let sports = LiveTVChannelFiltering.filter(channels, query: "", category: "Sports",
                                                   favoritesOnly: true, favoriteIDs: [favorite.id])
        XCTAssertEqual(sports.map(\.id), [favorite.id])
        XCTAssertTrue(LiveTVChannelFiltering.filter(channels, query: "", category: "News",
                                                    favoritesOnly: true, favoriteIDs: [favorite.id]).isEmpty)
    }

    func testXMLTVUsesChannelIDsForCurrentAndNextProgramme() throws {
        let xml = #"""
        <tv>
          <programme channel="news.one" start="20260101110000 +0000" stop="20260101120000 +0000">
            <title>Current bulletin</title>
          </programme>
          <programme channel="news.one" start="20260101120000 +0000" stop="20260101130000 +0000">
            <title>Next bulletin</title>
          </programme>
          <programme channel="other" start="20260101110000 +0000" stop="20260101120000 +0000">
            <title>Other service</title>
          </programme>
        </tv>
        """#
        let now = ISO8601DateFormatter().date(from: "2026-01-01T11:30:00Z")!
        let index = try EPGIndex(document: XMLTVParser.parse(Data(xml.utf8)), fetchedAt: now, now: now, limits: EPGLimits())
        let pair = index.nowNext(guideID: "news.one", name: nil, at: now)
        XCTAssertEqual(pair.current?.title, "Current bulletin")
        XCTAssertEqual(pair.next?.title, "Next bulletin")
        XCTAssertNil(index.nowNext(guideID: nil, name: nil, at: now).current)
    }

    private func makeSession(_ engine: LiveTVTestEngine) -> LiveTVPlayerSession {
        LiveTVPlayerSession(scheduler: LiveTVTestScheduler(), makeEngine: { engine }, isOtherVideoActive: { false })
    }

    private func settle() async { for _ in 0..<8 { await Task.yield() } }

    func testLivePlayerRejectsUnsupportedLocalSourceAndRemainsIsolated() async {
        let engine = LiveTVTestEngine()
        let session = makeSession(engine)
        let channel = LiveTVChannel(
            id: "test", guideID: nil, name: "Local unsupported",
            streamURL: URL(fileURLWithPath: "/tmp/not-a-channel.ts"), logoURL: nil, category: "Other"
        )
        session.play(channel)
        await settle()
        XCTAssertEqual(session.state, .failed)
        XCTAssertTrue(engine.loads.isEmpty)
        session.stop()
        XCTAssertEqual(session.state, .stopped)
    }

    func testLivePlaybackSwitchAndStopClearPreviousSessionState() async {
        let engine = LiveTVTestEngine()
        let session = makeSession(engine)
        let first = LiveTVChannel(id: "first", guideID: nil, name: "First",
            streamURL: URL(string: "rtmp://fixture.invalid/first")!, logoURL: nil, category: "Sports")
        let next = LiveTVChannel(id: "next", guideID: nil, name: "Next",
            streamURL: URL(string: "https://fixture.invalid/live/next.ts")!, logoURL: nil, category: "Sports")
        session.play(first)
        XCTAssertEqual(session.state, .failed)
        XCTAssertNotNil(session.errorMessage)

        session.play(next)
        await settle()
        XCTAssertEqual(session.activeChannelID, next.id)
        XCTAssertEqual(session.state, .connecting)
        XCTAssertNil(session.errorMessage)
        XCTAssertEqual(engine.loads.last, next.streamURL)
        session.stop()
        XCTAssertNil(session.activeChannelID)
        XCTAssertEqual(session.state, .stopped)
        XCTAssertEqual(engine.finalStops, 1)
    }

    func testStableSessionDoesNotReplaceSameChannelAndSwitchRejectsStaleEvents() async {
        let engine = LiveTVTestEngine()
        let session = makeSession(engine)
        let first = LiveTVChannel(id: "first", guideID: nil, name: "First",
            streamURL: URL(string: "https://fixture.invalid/first.ts")!, logoURL: nil, category: "News")
        let next = LiveTVChannel(id: "next", guideID: nil, name: "Next",
            streamURL: URL(string: "https://fixture.invalid/next.ts")!, logoURL: nil, category: "News")
        session.play(first)
        let firstGeneration = session.controller.generation
        session.play(first)
        XCTAssertEqual(session.controller.generation, firstGeneration)

        session.play(next)
        session.controller.phaseChanged(.playing, generation: firstGeneration)
        session.controller.phaseChanged(.failed(.network, detail: nil), generation: firstGeneration)
        XCTAssertEqual(session.activeChannelID, next.id)
        XCTAssertEqual(session.state, .connecting)
        XCTAssertFalse(session.controller.isStallTimerArmed)
        session.stop()
    }

    func testLiveAudioClaimTracksActiveSessionWithoutChangingAudioPolicy() {
        var liveTVIsActive = true
        let liveTVClaim = AetherAudioSessionOwnership.Claim(isHoldingAudio: { liveTVIsActive })
        XCTAssertFalse(AetherAudioSessionOwnership.mayDeactivateSharedSession(otherOwnersHoldingAudio: [liveTVIsActive]))
        liveTVIsActive = false
        XCTAssertTrue(AetherAudioSessionOwnership.mayDeactivateSharedSession(otherOwnersHoldingAudio: [liveTVIsActive]))
        withExtendedLifetime(liveTVClaim) {}
    }

    func testLivePlaybackFailuresClassifyEngineKindsWithoutCodecClaims() {
        XCTAssertEqual(LiveTVPlaybackFailure.classify(domain: "AVFoundationErrorDomain", code: -11828), .itemFailure)
        XCTAssertEqual(LiveTVPlaybackFailure.classify(domain: "PrivateProvider", code: -1), .unknown)
        XCTAssertEqual(LiveTVPlaybackFailure.classifyEngine(kind: "sourceRefused", code: 403), .refused)
        XCTAssertEqual(LiveTVPlaybackFailure.classifyEngine(kind: "sourceRateLimited", code: 509), .rateLimited)
        XCTAssertEqual(LiveTVPlaybackFailure.classifyEngine(kind: "unheardOf", code: nil), .unknown)
        XCTAssertNil(LiveTVPlaybackFailure.diagnosticDetail(kind: "https://user:pass@host/live", code: 1))
        XCTAssertFalse(LiveTVPlaybackFailure.itemFailure.message.localizedCaseInsensitiveContains("codec"))
        XCTAssertEqual(LiveTVPlaybackController.stallTimeoutSeconds, 30)
        XCTAssertEqual(LiveTVPlaybackController.startupTimeoutSeconds, 30)
    }

    func testControlsHideOnlyWhilePlayingWithoutOverlayAndCancelOnClose() {
        let controls = LiveTVControlsVisibility(scheduler: LiveTVTestScheduler())
        XCTAssertTrue(controls.isVisible)
        for state in [LiveTVPlaybackState.connecting, .buffering, .paused, .failed] {
            controls.update(state: state, isOverlayPresented: false)
            XCTAssertTrue(controls.isVisible)
            XCTAssertFalse(controls.isHideTimerArmed)
        }
        controls.update(state: .playing, isOverlayPresented: true)
        XCTAssertFalse(controls.isHideTimerArmed)
        controls.update(state: .playing, isOverlayPresented: false)
        XCTAssertTrue(controls.isHideTimerArmed)
        controls.toggle()
        XCTAssertFalse(controls.isVisible)
        controls.toggle()
        XCTAssertTrue(controls.isVisible)
        controls.cancel()
        XCTAssertFalse(controls.isHideTimerArmed)
        controls.interact()
        XCTAssertFalse(controls.isHideTimerArmed)
    }

    func testLiveTVOrientationPolicyAllowsBothLandscapeSidesAndRestoresPortraitBrowsing() {
        var state = PlayerRotationState()
        state.activate()
        XCTAssertTrue(state.isPlayerActive)
        XCTAssertEqual(PlayerOrientationCoordinator.geometryMask(
            isPlayerActive: state.isPlayerActive, preferredOrientation: UIInterfaceOrientationMask.landscape
        ), .landscape)
        XCTAssertEqual(PlayerScreenOrientation.portrait.toggled, .landscape)
        XCTAssertEqual(PlayerScreenOrientation.landscape.toggled, .portrait)
        state.deactivate()
        XCTAssertFalse(state.isPlayerActive)
        XCTAssertEqual(PlayerOrientationCoordinator.orientationMask(
            isPlayerActive: state.isPlayerActive, browsingOrientations: .portrait
        ), .portrait)
    }

    func testXtreamAccountValidationCategoriesAndStreams() throws {
        try XtreamResponseParser.account(from: Data(#"{"user_info":{"auth":1,"status":"Active","exp_date":"0"}}"#.utf8))
        XCTAssertThrowsError(try XtreamResponseParser.account(from: Data(#"{"user_info":{"auth":0,"status":"Disabled"}}"#.utf8))) { error in
            XCTAssertEqual(error as? LiveTVError, .authenticationFailed)
        }
        let expired = Data(#"{"user_info":{"auth":1,"status":"Expired","exp_date":"1"}}"#.utf8)
        XCTAssertThrowsError(try XtreamResponseParser.account(from: expired)) { error in
            XCTAssertEqual(error as? LiveTVError, .accountExpired)
        }
        let categories = try XtreamResponseParser.categories(from: Data(#"[{"category_id":"3","category_name":"News"}]"#.utf8))
        XCTAssertEqual(categories.first?.categoryID, "3")
        XCTAssertEqual(categories.first?.categoryName, "News")
        let streams = try XtreamResponseParser.streams(from: Data(#"[{"stream_id":42,"name":"World News","stream_icon":"https://logo.example.test/a.png","category_id":"3","epg_channel_id":"world.news","container_extension":"m3u8"}]"#.utf8))
        XCTAssertEqual(streams.first?.streamID, 42)
        XCTAssertEqual(streams.first?.epgChannelID, "world.news")
        XCTAssertThrowsError(try XtreamResponseParser.streams(from: Data("not json".utf8)))
    }

    func testXtreamAdvertisedFormatsAreParsedPersistedAndMalformedValuesIgnored() throws {
        let hls = try XtreamResponseParser.account(from: Data(#"{"user_info":{"auth":1,"allowed_output_formats":["TS","m3u8","unsupported"]}}"#.utf8))
        XCTAssertEqual(hls, ["m3u8", "ts"])
        let missing = try XtreamResponseParser.account(from: Data(#"{"user_info":{"auth":1}}"#.utf8))
        XCTAssertEqual(missing, [])
        let malformed = try XtreamResponseParser.account(from: Data(#"{"user_info":{"auth":1,"allowed_output_formats":"m3u8"}}"#.utf8))
        XCTAssertEqual(malformed, [])
        let provider = LiveTVProvider(id: UUID(), name: "Xtream", channelCount: 0, lastRefreshed: nil,
                                      kind: .xtream, allowedOutputFormats: hls)
        let encoded = try JSONEncoder().encode(provider)
        let decoded = try JSONDecoder().decode(LiveTVProvider.self, from: encoded)
        XCTAssertEqual(decoded.allowedOutputFormats, ["m3u8", "ts"])
    }

    func testXtreamUsesHLSOnlyWhenProviderAdvertisesIt() throws {
        let hls = try XtreamURLBuilder.streamURL(server: "https://example.test:9443/base", username: "u", password: "p",
                                                  streamID: 9, extension: "ts", allowedOutputFormats: ["m3u8"])
        XCTAssertEqual(hls.path, "/base/live/u/p/9.m3u8")
        let ts = try XtreamURLBuilder.streamURL(server: "https://example.test/base", username: "u", password: "p",
                                                 streamID: 9, extension: "ts", allowedOutputFormats: [])
        XCTAssertEqual(ts.path, "/base/live/u/p/9.ts")
        let malformed = try XtreamURLBuilder.streamURL(server: "https://example.test/base", username: "u", password: "p",
                                                        streamID: 9, extension: "ts", allowedOutputFormats: ["m3u8;bad"])
        XCTAssertEqual(malformed.path, "/base/live/u/p/9.ts")
        let both = try XtreamURLBuilder.streamURL(server: "https://example.test", username: "u", password: "p",
                                                   streamID: 9, extension: nil, allowedOutputFormats: ["m3u8", "ts"])
        XCTAssertEqual(both.path, "/live/u/p/9.ts")
        let tsOnly = try XtreamURLBuilder.streamURL(server: "https://example.test", username: "u", password: "p",
                                                     streamID: 9, extension: "m3u8", allowedOutputFormats: ["ts"])
        XCTAssertEqual(tsOnly.path, "/live/u/p/9.ts")
        let unspecified = try XtreamURLBuilder.streamURL(server: "https://example.test", username: "u", password: "p",
                                                          streamID: 9, extension: "m3u8", allowedOutputFormats: [])
        XCTAssertEqual(unspecified.path, "/live/u/p/9.ts")
    }

    func testPlaybackFailureClassificationDoesNotExposeUnderlyingText() {
        XCTAssertEqual(LiveTVPlaybackFailure.classify(domain: NSURLErrorDomain, code: URLError.timedOut.rawValue), .timeout)
        XCTAssertEqual(LiveTVPlaybackFailure.classify(domain: NSURLErrorDomain, code: URLError.notConnectedToInternet.rawValue), .network)
        XCTAssertEqual(LiveTVPlaybackFailure.classify(domain: NSURLErrorDomain, code: URLError.userAuthenticationRequired.rawValue), .authentication)
        XCTAssertEqual(LiveTVPlaybackFailure.classify(domain: "AVFoundationErrorDomain", code: -11828), .itemFailure)
        XCTAssertEqual(LiveTVPlaybackFailure.classify(domain: "PrivateProvider", code: -1), .unknown)
        XCTAssertFalse(LiveTVPlaybackFailure.unknown.message.contains("http"))
    }

    func testXtreamURLsPreserveSchemePortAndBasePathAndEncodeCredentials() throws {
        let api = try XtreamURLBuilder.apiURL(server: "http://provider.example.test:8088/edge/", username: "user name",
                                              password: "p@ss/word", action: "get_live_streams")
        XCTAssertEqual(api.scheme, "http")
        XCTAssertEqual(api.host, "provider.example.test")
        XCTAssertEqual(api.port, 8088)
        XCTAssertEqual(api.path, "/edge/player_api.php")
        let apiComponents = try XCTUnwrap(URLComponents(url: api, resolvingAgainstBaseURL: false))
        XCTAssertTrue(apiComponents.queryItems?.contains(URLQueryItem(name: "action", value: "get_live_streams")) == true)
        XCTAssertTrue(api.absoluteString.contains("user%20name"))
        let stream = try XtreamURLBuilder.streamURL(server: "https://provider.example.test:9443/base",
                                                    username: "a/b", password: "c?d", streamID: 17, extension: "m3u8")
        XCTAssertEqual(stream.scheme, "https")
        XCTAssertEqual(stream.port, 9443)
        XCTAssertTrue(stream.absoluteString.contains("/base/live/a%2Fb/c%3Fd/17.m3u8"))
        XCTAssertFalse(stream.absoluteString.contains("?"))
    }

    func testXtreamCredentialsAreKeychainOnlyAndProviderTypesHaveSeparateIdentities() throws {
        let suiteName = "LiveTVXtreamTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let secrets = MemoryLiveTVSecretStore()
        let service = LiveTVService(defaults: defaults, secretStore: secrets)
        let m3uID = try service.saveConfiguration(name: "M3U", playlistURL: "https://example.test/list.m3u", xmltvURL: nil)
        let password = "private-Xtream-pass"
        let xtreamID = try service.saveXtreamConfiguration(name: "Xtream", serverURL: "http://example.test:8080/base",
                                                           username: "private-user", password: password)
        XCTAssertNotEqual(m3uID, xtreamID)
        XCTAssertEqual(service.providers.map(\.kind), [.m3u, .xtream])
        let metadata = try XCTUnwrap(String(data: XCTUnwrap(defaults.data(forKey: "liveTV.providers.v1")), encoding: .utf8))
        XCTAssertFalse(metadata.contains(password))
        XCTAssertFalse(metadata.contains("private-user"))
        let stored = try XCTUnwrap(secrets.values["provider.\(xtreamID.uuidString)"])
        XCTAssertTrue(stored.contains(password))
        XCTAssertTrue(stored.contains("private-user"))
        service.selectProvider(m3uID)
        XCTAssertEqual(service.selectedProvider?.kind, .m3u)
        service.selectProvider(xtreamID)
        XCTAssertEqual(service.selectedProvider?.kind, .xtream)
    }

    func testExistingProviderMetadataWithoutKindMigratesAsM3U() throws {
        let id = UUID()
        let legacy = Data("{\"id\":\"\(id.uuidString)\",\"name\":\"Legacy Playlist\",\"channelCount\":12,\"lastRefreshed\":null}".utf8)
        let provider = try JSONDecoder().decode(LiveTVProvider.self, from: legacy)
        XCTAssertEqual(provider.id, id)
        XCTAssertEqual(provider.name, "Legacy Playlist")
        XCTAssertEqual(provider.channelCount, 12)
        XCTAssertEqual(provider.kind, .m3u)
    }
}

@MainActor
private final class MemoryLiveTVSecretStore: LiveTVSecretStore {
    var values: [String: String] = [:]
    func read(account: String) -> String? { values[account] }
    func save(_ value: String, account: String) -> Bool { values[account] = value; return true }
    func remove(account: String) -> Bool { values.removeValue(forKey: account) != nil }
}

@MainActor
private final class LiveTVTestEngine: LiveTVEngineDriving {
    var onPhase: ((LiveTVEnginePhase) -> Void)?
    var onLiveSourceReset: (() -> Void)?
    var onSystemInterruption: (() -> Void)?
    private(set) var loads: [URL] = []
    private(set) var finalStops = 0
    func load(_ url: URL, route: LiveTVStreamRoute) async throws { loads.append(url) }
    func recoverLiveSource() -> Bool { true }
    func play() {}
    func pause() {}
    func stop(final: Bool, releaseAudioSession: Bool) { if final { finalStops += 1 } }
}

@MainActor
private final class LiveTVTestScheduler: LiveTVScheduling {
    var now: Double { 0 }
    func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) -> LiveTVTimerHandle {
        LiveTVTimerHandle {}
    }
}
