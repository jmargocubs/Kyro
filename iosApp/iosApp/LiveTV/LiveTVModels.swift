import Foundation
import CryptoKit
import Observation

struct LiveTVProvider: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var channelCount: Int
    var lastRefreshed: Date?
    var kind: LiveTVProviderKind = .m3u
    var allowedOutputFormats: [String] = []

    private enum CodingKeys: String, CodingKey { case id, name, channelCount, lastRefreshed, kind, allowedOutputFormats }

    init(id: UUID, name: String, channelCount: Int, lastRefreshed: Date?, kind: LiveTVProviderKind = .m3u, allowedOutputFormats: [String] = []) {
        self.id = id
        self.name = name
        self.channelCount = channelCount
        self.lastRefreshed = lastRefreshed
        self.kind = kind
        self.allowedOutputFormats = Self.normalizedOutputFormats(allowedOutputFormats)
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        channelCount = try values.decodeIfPresent(Int.self, forKey: .channelCount) ?? 0
        lastRefreshed = try values.decodeIfPresent(Date.self, forKey: .lastRefreshed)
        kind = try values.decodeIfPresent(LiveTVProviderKind.self, forKey: .kind) ?? .m3u
        allowedOutputFormats = Self.normalizedOutputFormats((try? values.decode([String].self, forKey: .allowedOutputFormats)) ?? [])
    }

    static func normalizedOutputFormats(_ formats: [String]) -> [String] {
        Array(Set(formats.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { ["m3u8", "ts"].contains($0) })).sorted()
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum LiveTVProviderKind: String, Codable, Sendable {
    case m3u
    case xtream
}

struct LiveTVSourceConfiguration: Codable, Equatable, Sendable {
    var playlistURL: String?
    var xmltvURL: String?
    var kind: LiveTVProviderKind = .m3u
    var serverURL: String?
    var username: String?
    var password: String?

    private enum CodingKeys: String, CodingKey { case playlistURL, xmltvURL, kind, serverURL, username, password }

    init(playlistURL: String?, xmltvURL: String?, kind: LiveTVProviderKind = .m3u,
         serverURL: String? = nil, username: String? = nil, password: String? = nil) {
        self.playlistURL = playlistURL
        self.xmltvURL = xmltvURL
        self.kind = kind
        self.serverURL = serverURL
        self.username = username
        self.password = password
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        playlistURL = try values.decodeIfPresent(String.self, forKey: .playlistURL)
        xmltvURL = try values.decodeIfPresent(String.self, forKey: .xmltvURL)
        kind = try values.decodeIfPresent(LiveTVProviderKind.self, forKey: .kind) ?? .m3u
        serverURL = try values.decodeIfPresent(String.self, forKey: .serverURL)
        username = try values.decodeIfPresent(String.self, forKey: .username)
        password = try values.decodeIfPresent(String.self, forKey: .password)
    }
}

struct LiveTVChannel: Hashable, Identifiable, Sendable {
    let id: String
    let guideID: String?
    let name: String
    let streamURL: URL
    let logoURL: URL?
    let category: String
    var streamID: Int? = nil
}

/// The list blocks only when there are no channels to browse; refresh failures become banners
/// whenever a usable cached or live catalog is present.
enum LiveTVChannelListContentState: Equatable, Sendable {
    case setup
    case loading
    case failed(String)
    case noChannels
    case ready

    static func resolve(hasProviders: Bool, isLoading: Bool, errorMessage: String?, channelCount: Int) -> Self {
        guard hasProviders else { return .setup }
        if channelCount > 0 { return .ready }
        if isLoading { return .loading }
        if let errorMessage { return .failed(errorMessage) }
        return .noChannels
    }
}

struct LiveTVProgram: Hashable, Identifiable, Sendable {
    let id: String
    let channelID: String
    let title: String
    let startsAt: Date
    let endsAt: Date

    func isCurrent(at date: Date = .now) -> Bool { startsAt <= date && date < endsAt }
}

extension LiveTVProgram {
    init(_ program: EPGProgram) {
        self.init(id: program.id, channelID: program.channelID, title: program.title,
                  startsAt: program.start, endsAt: program.end)
    }
}

struct LiveTVProgramPair: Equatable {
    let current: LiveTVProgram?
    let next: LiveTVProgram?
}

enum LiveTVChannelFiltering {
    static func filter(
        _ channels: [LiveTVChannel],
        query: String,
        category: String?,
        favoritesOnly: Bool,
        favoriteIDs: Set<String>
    ) -> [LiveTVChannel] {
        channels.filter { channel in
            (!favoritesOnly || favoriteIDs.contains(channel.id))
                && (category == nil || category == channel.category)
                && (query.isEmpty || channel.name.localizedStandardContains(query)
                    || channel.category.localizedStandardContains(query))
        }
    }

    static func grouped(
        _ channels: [LiveTVChannel], query: String, category: String?, favoritesOnly: Bool,
        favoriteIDs: Set<String>
    ) -> [String: [LiveTVChannel]] {
        var groups: [String: [LiveTVChannel]] = [:]
        for (index, channel) in channels.enumerated() {
            if index.isMultiple(of: 256), Task.isCancelled { return [:] }
            guard (!favoritesOnly || favoriteIDs.contains(channel.id)),
                  (category == nil || category == channel.category),
                  (query.isEmpty || channel.name.localizedStandardContains(query)
                    || channel.category.localizedStandardContains(query)) else { continue }
            groups[channel.category, default: []].append(channel)
        }
        return groups
    }
}

@MainActor
@Observable
final class LiveTVChannelSearchModel {
    private(set) var groups: [String: [LiveTVChannel]] = [:]
    private(set) var orderedCategories: [String] = []
    private(set) var resultCount = 0
    private var generation = 0
    private var debounceTask: Task<Void, Never>?
    private var worker: Task<[String: [LiveTVChannel]], Never>?

    func update(channels: [LiveTVChannel], query: String, category: String?, favoritesOnly: Bool,
                favoriteIDs: Set<String>, debounce: Duration = .milliseconds(180)) {
        generation += 1
        let current = generation
        debounceTask?.cancel()
        worker?.cancel()
        let snapshots = (channels, query.trimmingCharacters(in: .whitespacesAndNewlines), category, favoritesOnly, favoriteIDs)
        debounceTask = Task {
            do { try await Task.sleep(for: debounce) } catch { return }
            guard !Task.isCancelled, current == generation else { return }
            let work = Task.detached(priority: .userInitiated) {
                LiveTVChannelFiltering.grouped(snapshots.0, query: snapshots.1, category: snapshots.2,
                                               favoritesOnly: snapshots.3, favoriteIDs: snapshots.4)
            }
            worker = work
            let grouped = await work.value
            guard !Task.isCancelled, current == generation else { return }
            groups = grouped
            orderedCategories = grouped.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            resultCount = grouped.values.reduce(0) { $0 + $1.count }
            worker = nil
        }
    }

    func cancel() {
        generation += 1
        debounceTask?.cancel()
        worker?.cancel()
        debounceTask = nil
        worker = nil
        groups = [:]
        orderedCategories = []
        resultCount = 0
    }

    func waitForCurrentSearch() async { await debounceTask?.value }
}

enum LiveTVError: LocalizedError, Equatable {
    case invalidConfiguration
    case keychainUnavailable
    case responseTooLarge
    case providerRejected
    case noChannels
    case invalidPlaylist
    case invalidXtreamResponse
    case authenticationFailed
    case accountExpired

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "Enter a valid HTTP or HTTPS playlist URL."
        case .keychainUnavailable: "The provider configuration could not be saved securely."
        case .responseTooLarge: "The playlist or guide is larger than the supported import limit."
        case .providerRejected: "The provider could not be reached. Check the playlist address and try again."
        case .noChannels: "No valid channels were found in this playlist."
        case .invalidPlaylist: "The playlist format could not be read."
        case .invalidXtreamResponse: "The provider returned an unsupported response. Check the account settings and try again."
        case .authenticationFailed: "The provider rejected these account credentials. Check them and try again."
        case .accountExpired: "This provider account is inactive or expired."
        }
    }
}

struct XtreamAccountResponse: Decodable, Sendable {
    struct UserInfo: Decodable, Sendable {
        let auth: Int?
        let status: String?
        let expDate: String?
        let allowedOutputFormats: [String]?
        enum CodingKeys: String, CodingKey { case auth, status; case expDate = "exp_date"; case allowedOutputFormats = "allowed_output_formats" }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            auth = try? c.decode(Int.self, forKey: .auth)
            status = try? c.decode(String.self, forKey: .status)
            expDate = try? c.decode(String.self, forKey: .expDate)
            allowedOutputFormats = try? c.decode([String].self, forKey: .allowedOutputFormats)
        }
    }
    let userInfo: UserInfo?
    enum CodingKeys: String, CodingKey { case userInfo = "user_info" }
}

struct XtreamCategoryResponse: Decodable, Sendable {
    let categoryID: String?
    let categoryName: String?
    enum CodingKeys: String, CodingKey { case categoryID = "category_id", categoryName = "category_name" }
}

struct XtreamLiveStreamResponse: Decodable, Sendable {
    let streamID: Int?
    let name: String?
    let streamIcon: String?
    let categoryID: String?
    let epgChannelID: String?
    let containerExtension: String?
    enum CodingKeys: String, CodingKey {
        case streamID = "stream_id", name
        case streamIcon = "stream_icon", categoryID = "category_id"
        case epgChannelID = "epg_channel_id", containerExtension = "container_extension"
    }
}

enum XtreamURLBuilder {
    static func apiURL(server: String, username: String, password: String, action: String? = nil,
                       streamID: Int? = nil, limit: Int? = nil) throws -> URL {
        guard var components = URLComponents(string: server.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.host != nil else { throw LiveTVError.invalidConfiguration }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + ([basePath, "player_api.php"].filter { !$0.isEmpty }.joined(separator: "/"))
        components.queryItems = [URLQueryItem(name: "username", value: username),
                                 URLQueryItem(name: "password", value: password)]
        if let action { components.queryItems?.append(URLQueryItem(name: "action", value: action)) }
        if let streamID { components.queryItems?.append(URLQueryItem(name: "stream_id", value: String(streamID))) }
        if let limit { components.queryItems?.append(URLQueryItem(name: "limit", value: String(limit))) }
        guard let url = components.url else { throw LiveTVError.invalidConfiguration }
        return url
    }

    static func streamURL(server: String, username: String, password: String,
                          streamID: Int, extension rawExtension: String?, allowedOutputFormats: [String] = []) throws -> URL {
        guard var components = URLComponents(string: server.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.host != nil else { throw LiveTVError.invalidConfiguration }
        let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let advertised = LiveTVProvider.normalizedOutputFormats(allowedOutputFormats)
        // Raw MPEG-TS is Xtream's native live output: one long-lived request that AetherEngine reads
        // itself. HLS is used only when the account offers nothing else.
        let ext: String
        if advertised.contains("ts") { ext = "ts" }
        else if advertised.contains("m3u8") { ext = "m3u8" }
        else { ext = "ts" }  // Nothing advertised: Xtream always serves live TS.
        let allowed = ext.range(of: #"^[a-z0-9]{1,8}$"#, options: .regularExpression) != nil ? ext : "ts"
        let pathSegmentCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let escapedUsername = username.addingPercentEncoding(withAllowedCharacters: pathSegmentCharacters) ?? ""
        let escapedPassword = password.addingPercentEncoding(withAllowedCharacters: pathSegmentCharacters) ?? ""
        let segments = [basePath, "live", escapedUsername, escapedPassword, "\(streamID).\(allowed)"].filter { !$0.isEmpty }
        components.percentEncodedPath = "/" + segments.joined(separator: "/")
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw LiveTVError.invalidConfiguration }
        return url
    }
}

enum XtreamResponseParser {
    @discardableResult static func account(from data: Data, now: Date = .now) throws -> [String] {
        guard let response = try? JSONDecoder().decode(XtreamAccountResponse.self, from: data),
              let info = response.userInfo, let auth = info.auth else { throw LiveTVError.invalidXtreamResponse }
        guard auth == 1 else { throw LiveTVError.authenticationFailed }
        if let status = info.status?.lowercased(), status != "active" { throw LiveTVError.accountExpired }
        if let rawDate = info.expDate, let timestamp = TimeInterval(rawDate), timestamp > 0,
           Date(timeIntervalSince1970: timestamp) <= now { throw LiveTVError.accountExpired }
        return LiveTVProvider.normalizedOutputFormats(info.allowedOutputFormats ?? [])
    }

    static func categories(from data: Data) throws -> [XtreamCategoryResponse] {
        guard let items = try? JSONDecoder().decode([XtreamCategoryResponse].self, from: data) else {
            throw LiveTVError.invalidXtreamResponse
        }
        return items
    }

    static func streams(from data: Data) throws -> [XtreamLiveStreamResponse] {
        guard let items = try? JSONDecoder().decode([XtreamLiveStreamResponse].self, from: data) else {
            throw LiveTVError.invalidXtreamResponse
        }
        return items
    }
}

enum LiveTVPlaybackFailure: Equatable {
    case itemFailure, stalled, startupTimeout, authentication, network, timeout, unknown
    case refused, rateLimited, unsupportedStream, audioUnavailable, streamEnded, sourceLost
    case otherVideoActive, engineUnavailable

    static func classify(domain: String, code: Int) -> Self {
        if domain == NSURLErrorDomain {
            if code == URLError.timedOut.rawValue { return .timeout }
            if [URLError.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
                .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff].map(\.rawValue).contains(code) { return .network }
            if code == URLError.userAuthenticationRequired.rawValue || code == URLError.userCancelledAuthentication.rawValue { return .authentication }
        }
        if domain == "AVFoundationErrorDomain" {
            if [-1013, -1008].contains(code) { return .authentication }
            if code == -1001 { return .timeout }
            return .itemFailure
        }
        if domain == "NSOSStatusErrorDomain" { return .itemFailure }
        return .unknown
    }

    var message: String {
        switch self {
        case .itemFailure: "The player reported a channel failure. Try another channel or check the provider."
        case .stalled: "Playback stopped receiving media. Check the connection or try another channel."
        case .startupTimeout: "The channel did not start playing in time. Try again or choose another channel."
        case .refused: "The provider refused this stream. Another device may be using the account, or access may have expired."
        case .rateLimited: "The provider is limiting connections right now. Wait a moment, then try again."
        case .unsupportedStream: "This channel's stream could not be played on this device. Try another channel."
        case .audioUnavailable: "Audio could not start for this channel. Try again."
        case .streamEnded: "The channel stopped streaming. Try again or choose another channel."
        case .sourceLost: "The live stream keeps dropping. Try the channel again."
        case .otherVideoActive: "A video is still playing in Picture in Picture. Close it, then try again."
        case .engineUnavailable: "The Live TV player could not start. Try again."
        case .authentication: "The provider rejected this stream request. Check the account or channel access."
        case .network: "The channel could not be reached. Check your connection or provider availability."
        case .timeout: "The channel request timed out. The provider may be slow or unavailable."
        case .unknown: "Playback failed for an unknown reason. Check the channel and provider."
        }
    }
}

extension LiveTVPlaybackFailure {
    /// Maps an AetherEngine `PlaybackErrorKind` raw value to a viewer-facing failure. Classifies on
    /// the stable token, never on the engine's message, which can carry localized or URL text.
    static func classifyEngine(kind: String?, code: Int?) -> Self {
        switch kind {
        case "sourceRefused": return code == 404 ? .network : .refused
        case "sourceRateLimited": return .rateLimited
        case "sourceOpenFailed", "liveSourceUnavailable", "sourceCertificateRejected": return .network
        case "noPlayableTrackWithinBudget", "nativeItemFailed", "masterPlaylistRejected",
             "softwarePipelineFailed", "hlsPlaylistOnRawLivePath", "demuxedAudioLiveUnsupported",
             "dolbyVisionRequiresHardware", "customSourceProbeFailed": return .unsupportedStream
        case "audioSessionFailed", "audioBridgeProducedNoOutput": return .audioUnavailable
        case "liveReloadNeverReady", "reloadFailed": return .sourceLost
        default: return .unknown
        }
    }

    /// A privacy-safe diagnostic token: the engine's error kind plus a status or error code.
    /// Never a URL, a credential or the engine's free-text message.
    static func diagnosticDetail(kind: String?, code: Int?) -> String? {
        guard let kind, kind.range(of: #"^[A-Za-z0-9]{1,64}$"#, options: .regularExpression) != nil else { return nil }
        return code.map { "\(kind) \($0)" } ?? kind
    }
}

// MARK: - Live playback control

/// What the Live TV player shows.
enum LiveTVPlaybackState: Equatable, Sendable {
    case stopped, connecting, playing, buffering, paused, failed
}

/// The AetherEngine route a stream URL takes.
enum LiveTVStreamRoute: Equatable, Sendable {
    /// MPEG-TS or another container over one long-lived HTTP request, read by the engine itself.
    case transportStream
    /// An HLS playlist: the engine's live HLS route, with its live-ingest fallback.
    case hls

    init(url: URL) {
        self = url.pathExtension.lowercased() == "m3u8" ? .hls : .transportStream
    }
}

/// AetherEngine's `PlaybackPhase`, mirrored so the playback policy has no engine dependency.
enum LiveTVEnginePhase: Equatable, Sendable {
    case idle, loading, playing, paused, rebuffering
    case stalled(reconnecting: Bool)
    case ended
    case failed(LiveTVPlaybackFailure, detail: String?)
}

/// A load that failed for a reason other than being superseded.
struct LiveTVEngineLoadError: Error, Equatable {
    let failure: LiveTVPlaybackFailure
    let detail: String?
}

/// The engine a Live TV session drives. Callbacks run synchronously when the engine publishes.
@MainActor
protocol LiveTVEngineDriving: AnyObject {
    var onPhase: ((LiveTVEnginePhase) -> Void)? { get set }
    var onLiveSourceReset: (() -> Void)? { get set }
    var onSystemInterruption: (() -> Void)? { get set }
    /// Throws `CancellationError` when superseded and `LiveTVEngineLoadError` for a real failure.
    func load(_ url: URL, route: LiveTVStreamRoute) async throws
    /// The engine's in-place live source renewal. False means a full load is needed.
    func recoverLiveSource() -> Bool
    func play()
    func pause()
    /// Ends the session. Only a final stop, Live TV closing, may release the audio session.
    func stop(final: Bool, releaseAudioSession: Bool)
}

/// What the playback controller asks of the session.
@MainActor
protocol LiveTVPlaybackOutput: AnyObject {
    func load(_ url: URL, generation: Int)
    /// True when the engine renewed the source in place; false when a full load was started.
    func recoverLiveSource(_ url: URL, generation: Int) -> Bool
    func resume()
    func pause()
    func clear(final: Bool)
}

@MainActor
final class LiveTVTimerHandle {
    private var onCancel: (() -> Void)?
    init(onCancel: @escaping () -> Void) { self.onCancel = onCancel }
    func cancel() {
        onCancel?()
        onCancel = nil
    }
}

@MainActor
protocol LiveTVScheduling: AnyObject {
    /// Monotonic seconds, used to space live retunes.
    var now: Double { get }
    func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) -> LiveTVTimerHandle
}

@MainActor
final class LiveTVTaskScheduler: LiveTVScheduling {
    var now: Double { ProcessInfo.processInfo.systemUptime }

    func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) -> LiveTVTimerHandle {
        let task = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard !Task.isCancelled else { return }
            action()
        }
        return LiveTVTimerHandle { task.cancel() }
    }
}

/// Live TV playback policy over AetherEngine's playback phase: startup and buffering bounds,
/// bounded live retunes, stale-event rejection, system pauses and failure with Retry.
///
/// The startup timer runs only while `connecting`, which ends when the engine reports motion.
/// The buffering timer runs only while `buffering`, which needs playback to have started.
@MainActor
@Observable
final class LiveTVPlaybackController {
    /// A fast-zap join can hold the first frame for several seconds on a strict-realtime origin.
    static let startupTimeoutSeconds: Double = 30
    static let stallTimeoutSeconds: Double = 30
    /// The reference live host's policy: one retune in flight, 20 s apart, three per tune.
    static let retuneBudget = 3
    static let retuneSpacingSeconds: Double = 20

    private(set) var state: LiveTVPlaybackState = .stopped
    private(set) var errorMessage: String?
    /// Privacy-safe failure token for diagnostics: an engine error kind and code, never a URL.
    private(set) var failureDetail: String?
    private(set) var activeChannelID: String?
    var isPaused: Bool { state == .paused }
    var canRetry: Bool { state == .failed && activeURL != nil }
    /// Whether Live TV holds the shared audio session, for Silo's ownership registry.
    var holdsAudio: Bool {
        switch state {
        case .connecting, .playing, .buffering, .paused: true
        case .stopped, .failed: false
        }
    }

    @ObservationIgnored weak var output: (any LiveTVPlaybackOutput)?
    @ObservationIgnored private(set) var generation = 0
    @ObservationIgnored private(set) var activeURL: URL?
    @ObservationIgnored private(set) var hasStartedPlayback = false
    @ObservationIgnored private(set) var retuneCount = 0
    @ObservationIgnored private(set) var isRetuneInFlight = false
    var isStartupTimerArmed: Bool { startupTimer != nil }
    var isStallTimerArmed: Bool { stallTimer != nil }
    var isRetuneScheduled: Bool { deferredRetune != nil }

    @ObservationIgnored private let scheduler: any LiveTVScheduling
    @ObservationIgnored private var startupTimer: LiveTVTimerHandle?
    @ObservationIgnored private var stallTimer: LiveTVTimerHandle?
    @ObservationIgnored private var lastRetuneAt: Double?
    @ObservationIgnored private var deferredRetune: LiveTVTimerHandle?
    @ObservationIgnored private var sourceLostWhilePaused = false

    init(scheduler: any LiveTVScheduling) {
        self.scheduler = scheduler
    }

    /// Replaying the channel that is already active is a no-op, so a restarted SwiftUI task
    /// cannot throw away a healthy stream.
    func play(channelID: String, url: URL) {
        guard activeChannelID != channelID || !holdsAudio else { return }
        start(channelID: channelID, url: url)
    }

    func retry() {
        guard state == .failed, let channelID = activeChannelID, let url = activeURL else { return }
        start(channelID: channelID, url: url)
    }

    /// Shows a failure for a channel without loading it, keeping Retry available.
    func refuse(channelID: String, url: URL, failure: LiveTVPlaybackFailure) {
        invalidateCurrentStream()
        output?.clear(final: false)
        activeChannelID = channelID
        activeURL = url
        hasStartedPlayback = false
        state = .failed
        errorMessage = failure.message
        failureDetail = nil
    }

    func togglePlayback() {
        switch state {
        case .playing, .buffering:
            cancelStallTimer()
            state = .paused
            output?.pause()
        case .paused:
            if hasStartedPlayback && !sourceLostWhilePaused {
                state = .playing
                output?.resume()
            } else if let channelID = activeChannelID, let url = activeURL {
                // Paused before the first frame, or the source died meanwhile: reconnect.
                start(channelID: channelID, url: url)
            }
        case .failed:
            retry()
        case .stopped, .connecting:
            break
        }
    }

    func stop() {
        invalidateCurrentStream()
        output?.clear(final: true)
        activeChannelID = nil
        activeURL = nil
        hasStartedPlayback = false
        state = .stopped
        errorMessage = nil
        failureDetail = nil
    }

    /// An audio interruption began or the output route disappeared. Live TV stays paused until
    /// the viewer resumes it, the same explicit-resume rule Silo applies to its transports.
    func pauseForSystemInterruption() {
        switch state {
        case .connecting, .playing, .buffering: pauseForSystem()
        case .stopped, .paused, .failed: break
        }
    }

    // MARK: Engine events, tagged with the generation current when the engine published them

    func phaseChanged(_ phase: LiveTVEnginePhase, generation: Int) {
        guard generation == self.generation, state != .stopped, state != .failed else { return }
        switch phase {
        case .playing:
            if state == .paused {
                // The viewer's pause stands, including over an engine's automatic resume.
                output?.pause()
                return
            }
            hasStartedPlayback = true
            isRetuneInFlight = false
            cancelStartupTimer()
            cancelStallTimer()
            state = .playing
        case .loading, .rebuffering, .stalled:
            // Connecting: the startup timer decides. Paused: the viewer's choice stands.
            if state == .playing {
                state = .buffering
                armStallTimer()
            }
        case .paused:
            // Nothing in Live TV paused it: an interruption, a lost route, or the system.
            if state == .playing || state == .buffering { pauseForSystem() }
        case .ended:
            fail(.streamEnded, detail: nil)
        case .failed(let failure, let detail):
            fail(failure, detail: detail)
        case .idle:
            // The echo of a stop or of the teardown that starts the next load.
            break
        }
    }

    /// The engine asks for a fresh acquisition after its own bounded recovery ran out.
    ///
    /// The request alone changes no state: in-place renewal can keep buffered video moving,
    /// and only the engine's own rebuffering or stalled phase means playback stopped. Retunes
    /// are spaced at least 20 s apart; an early request waits for the spacing instead of failing
    /// the channel. One recovery at a time, three per tune, then the channel fails with Retry.
    func liveSourceReset(generation: Int) {
        guard generation == self.generation, activeURL != nil else { return }
        switch state {
        case .paused:
            sourceLostWhilePaused = true
            return
        case .connecting, .playing, .buffering:
            break
        case .stopped, .failed:
            return
        }
        guard !isRetuneInFlight, deferredRetune == nil else { return }
        guard retuneCount < Self.retuneBudget else {
            fail(.sourceLost, detail: "retunes \(retuneCount)")
            return
        }
        let wait = lastRetuneAt.map { max(0, Self.retuneSpacingSeconds - (scheduler.now - $0)) } ?? 0
        guard wait > 0 else {
            performRetune()
            return
        }
        let current = self.generation
        deferredRetune = scheduler.schedule(after: wait) { [weak self] in
            self?.deferredRetuneFired(generation: current)
        }
    }

    func loadReturned(generation: Int) {
        guard generation == self.generation else { return }
        isRetuneInFlight = false
    }

    /// The engine also publishes the same failure as a phase; the generation bump in `fail`
    /// makes whichever arrives second stale, so one failure is handled once.
    func loadFailed(_ error: LiveTVEngineLoadError, generation: Int) {
        guard generation == self.generation, state != .stopped, state != .failed else { return }
        fail(error.failure, detail: error.detail)
    }

    // MARK: Private

    private func start(channelID: String, url: URL) {
        invalidateCurrentStream()
        activeChannelID = channelID
        activeURL = url
        errorMessage = nil
        failureDetail = nil
        hasStartedPlayback = false
        sourceLostWhilePaused = false
        retuneCount = 0
        lastRetuneAt = nil
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            output?.clear(final: false)
            state = .failed
            errorMessage = "This channel uses an unsupported stream address."
            return
        }
        state = .connecting
        let current = generation
        startupTimer = scheduler.schedule(after: Self.startupTimeoutSeconds) { [weak self] in
            self?.startupTimerFired(generation: current)
        }
        output?.load(url, generation: current)
    }

    private func pauseForSystem() {
        cancelStartupTimer()
        cancelStallTimer()
        state = .paused
        output?.pause()
    }

    private func deferredRetuneFired(generation: Int) {
        guard generation == self.generation else { return }
        deferredRetune = nil
        switch state {
        case .connecting, .playing, .buffering: performRetune()
        case .paused: sourceLostWhilePaused = true
        case .stopped, .failed: break
        }
    }

    private func performRetune() {
        guard let url = activeURL, let output else { return }
        retuneCount += 1
        lastRetuneAt = scheduler.now
        isRetuneInFlight = true
        // A full reload clears the latch when its load returns or playback resumes.
        if output.recoverLiveSource(url, generation: generation) { isRetuneInFlight = false }
    }

    private func startupTimerFired(generation: Int) {
        guard generation == self.generation else { return }
        startupTimer = nil
        guard state == .connecting else { return }
        fail(.startupTimeout, detail: nil)
    }

    private func armStallTimer() {
        guard state == .buffering, stallTimer == nil else { return }
        let current = generation
        stallTimer = scheduler.schedule(after: Self.stallTimeoutSeconds) { [weak self] in
            self?.stallTimerFired(generation: current)
        }
    }

    private func stallTimerFired(generation: Int) {
        guard generation == self.generation else { return }
        stallTimer = nil
        guard state == .buffering else { return }
        fail(.stalled, detail: nil)
    }

    private func fail(_ failure: LiveTVPlaybackFailure, detail: String?) {
        invalidateCurrentStream()
        output?.clear(final: false)
        state = .failed
        errorMessage = failure.message
        failureDetail = detail
    }

    private func invalidateCurrentStream() {
        generation &+= 1
        cancelStartupTimer()
        cancelStallTimer()
        deferredRetune?.cancel()
        deferredRetune = nil
        isRetuneInFlight = false
    }

    private func cancelStartupTimer() {
        startupTimer?.cancel()
        startupTimer = nil
    }

    private func cancelStallTimer() {
        stallTimer?.cancel()
        stallTimer = nil
    }
}

/// The Live TV player session: one AetherEngine, created on first playback and kept for the
/// session's lifetime, so rotation, channel switches and reopening Live TV reuse one engine.
/// `LiveTVService` owns the only production instance. This type is AetherEngine-free; the
/// engine is reached through `LiveTVEngineDriving`.
@MainActor
@Observable
final class LiveTVPlayerSession: LiveTVPlaybackOutput {
    let controller: LiveTVPlaybackController
    private(set) var engine: (any LiveTVEngineDriving)?
    @ObservationIgnored private(set) var enginesCreated = 0

    var state: LiveTVPlaybackState { controller.state }
    var errorMessage: String? { controller.errorMessage }
    var failureDetail: String? { controller.failureDetail }
    var isPaused: Bool { controller.isPaused }
    var canRetry: Bool { controller.canRetry }
    var activeChannelID: String? { controller.activeChannelID }

    @ObservationIgnored private let makeEngine: @MainActor () throws -> any LiveTVEngineDriving
    @ObservationIgnored private let isOtherVideoActive: @MainActor () -> Bool
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var audioSessionClaim: AetherAudioSessionOwnership.Claim?

    init(scheduler: any LiveTVScheduling,
         makeEngine: @escaping @MainActor () throws -> any LiveTVEngineDriving,
         isOtherVideoActive: @escaping @MainActor () -> Bool) {
        let controller = LiveTVPlaybackController(scheduler: scheduler)
        self.controller = controller
        self.makeEngine = makeEngine
        self.isOtherVideoActive = isOtherVideoActive
        controller.output = self
        audioSessionClaim = AetherAudioSessionOwnership.Claim(isHoldingAudio: { [weak controller] in
            controller?.holdsAudio ?? false
        })
    }

    func play(_ channel: LiveTVChannel) {
        if controller.activeChannelID == channel.id, controller.holdsAudio { return }
        // Only one video engine plays at a time: a Silo movie in Picture in Picture keeps its own.
        guard !isOtherVideoActive() else {
            controller.refuse(channelID: channel.id, url: channel.streamURL, failure: .otherVideoActive)
            return
        }
        controller.play(channelID: channel.id, url: channel.streamURL)
    }

    func retry() {
        guard controller.canRetry, let channelID = controller.activeChannelID, let url = controller.activeURL else { return }
        guard !isOtherVideoActive() else {
            controller.refuse(channelID: channelID, url: url, failure: .otherVideoActive)
            return
        }
        controller.retry()
    }

    func togglePlayback() {
        if controller.state == .failed { retry() } else { controller.togglePlayback() }
    }

    func stop() { controller.stop() }

    // MARK: LiveTVPlaybackOutput

    func load(_ url: URL, generation: Int) {
        guard let engine = resolveEngine() else {
            controller.loadFailed(LiveTVEngineLoadError(failure: .engineUnavailable, detail: nil), generation: generation)
            return
        }
        loadTask?.cancel()
        // Stop the outgoing stream first so nothing it publishes while the load task is being
        // scheduled is tagged with the new generation.
        engine.stop(final: false, releaseAudioSession: false)
        let route = LiveTVStreamRoute(url: url)
        loadTask = Task { @MainActor [weak self] in
            do {
                try await engine.load(url, route: route)
                self?.controller.loadReturned(generation: generation)
            } catch is CancellationError {
                // A newer load or a stop superseded this one; the successor owns the session.
            } catch let error as LiveTVEngineLoadError {
                self?.controller.loadFailed(error, generation: generation)
            } catch {
                self?.controller.loadFailed(LiveTVEngineLoadError(failure: .unknown, detail: nil), generation: generation)
            }
        }
    }

    func recoverLiveSource(_ url: URL, generation: Int) -> Bool {
        if engine?.recoverLiveSource() == true { return true }
        load(url, generation: generation)
        return false
    }

    func resume() { engine?.play() }

    func pause() { engine?.pause() }

    func clear(final: Bool) {
        loadTask?.cancel()
        loadTask = nil
        guard let engine else { return }
        let release = final && (audioSessionClaim.map { AetherAudioSessionOwnership.canReleaseSharedSession(excluding: $0) } ?? false)
        engine.stop(final: final, releaseAudioSession: release)
    }

    // MARK: Private

    private func resolveEngine() -> (any LiveTVEngineDriving)? {
        if let engine { return engine }
        guard let created = try? makeEngine() else { return nil }
        created.onPhase = { [weak self] phase in
            self?.deliver { controller, generation in controller.phaseChanged(phase, generation: generation) }
        }
        created.onLiveSourceReset = { [weak self] in
            self?.deliver { controller, generation in controller.liveSourceReset(generation: generation) }
        }
        created.onSystemInterruption = { [weak self] in
            self?.deliver { controller, _ in controller.pauseForSystemInterruption() }
        }
        engine = created
        enginesCreated += 1
        return created
    }

    /// Tags an engine event with the generation current when the engine published it, then
    /// handles it once the engine has finished its own state change, never re-entrantly.
    private func deliver(_ event: @escaping @MainActor (LiveTVPlaybackController, Int) -> Void) {
        let generation = controller.generation
        Task { @MainActor [weak self] in
            guard let self else { return }
            event(controller, generation)
        }
    }
}

/// Auto-hiding player controls. Controls hide after a short idle period, and only while video is
/// playing with no overlay open. Connecting, buffering, paused and failed always show them.
/// The model owns one cancellable, generation-tagged timer and never touches playback.
@MainActor
@Observable
final class LiveTVControlsVisibility {
    static let hideDelaySeconds: Double = 3

    private(set) var isVisible = true
    var isHideTimerArmed: Bool { hideTimer != nil }

    @ObservationIgnored private let scheduler: any LiveTVScheduling
    @ObservationIgnored private var hideTimer: LiveTVTimerHandle?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var state: LiveTVPlaybackState = .stopped
    @ObservationIgnored private var isOverlayPresented = false

    init(scheduler: any LiveTVScheduling) {
        self.scheduler = scheduler
    }

    private var mayAutoHide: Bool { state == .playing && !isOverlayPresented }

    /// Call when the playback state or the presence of a sheet changes.
    func update(state: LiveTVPlaybackState, isOverlayPresented: Bool) {
        self.state = state
        self.isOverlayPresented = isOverlayPresented
        if mayAutoHide {
            if isVisible, hideTimer == nil { armHideTimer() }
        } else {
            cancelHideTimer()
            isVisible = true
        }
    }

    /// A tap on the video: hide when shown, show when hidden. Ignored while the controls must stay up.
    func toggle() {
        guard mayAutoHide else { return }
        if isVisible {
            cancelHideTimer()
            isVisible = false
        } else {
            isVisible = true
            armHideTimer()
        }
    }

    /// Any use of a control restarts the idle period.
    func interact() {
        isVisible = true
        if mayAutoHide { armHideTimer() }
    }

    /// A channel change shows the controls again.
    func channelChanged() { interact() }

    /// The player is closing: no timer may outlive it.
    func cancel() {
        // A stopped state means a late interaction cannot re-arm anything until the next update.
        state = .stopped
        cancelHideTimer()
        isVisible = true
    }

    private func armHideTimer() {
        cancelHideTimer()
        let current = generation
        hideTimer = scheduler.schedule(after: Self.hideDelaySeconds) { [weak self] in
            self?.hideTimerFired(generation: current)
        }
    }

    private func hideTimerFired(generation: Int) {
        guard generation == self.generation else { return }
        hideTimer = nil
        guard mayAutoHide else { return }
        isVisible = false
    }

    private func cancelHideTimer() {
        generation &+= 1
        hideTimer?.cancel()
        hideTimer = nil
    }
}

enum LiveTVM3UParser {
    static func parse(data: Data, providerID: UUID, limit: Int = 20_000) throws -> [LiveTVChannel] {
        guard limit > 0, let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw LiveTVError.invalidPlaylist
        }

        var channels: [LiveTVChannel] = []
        var seenIDs = Set<String>()
        var pending: (name: String, attributes: [String: String])?
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXTINF:") {
                let attributes = parseAttributes(line)
                let name = displayName(in: line)?.trimmingCharacters(in: .whitespacesAndNewlines)
                pending = name.flatMap { $0.isEmpty ? nil : ($0, attributes) }
                continue
            }
            guard !line.isEmpty, !line.hasPrefix("#"), let item = pending else { continue }
            pending = nil
            guard let url = webURL(line) else { continue }

            let guideID = item.attributes["tvg-id"]?.nilIfBlank
            let stableSource = guideID?.lowercased() ?? item.name.folding(
                options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")
            ).lowercased()
            let digest = SHA256.hash(data: Data("\(providerID.uuidString)|\(stableSource)".utf8))
                .map { String(format: "%02x", $0) }.joined()
            let stableID = "\(providerID.uuidString):\(digest)"
            guard seenIDs.insert(stableID).inserted else { continue }

            let logo = item.attributes["tvg-logo"].flatMap(webURL)
            let category = item.attributes["group-title"]?.nilIfBlank ?? "Other"
            channels.append(LiveTVChannel(
                id: stableID,
                guideID: guideID,
                name: item.name,
                streamURL: url,
                logoURL: logo,
                category: category
            ))
            if channels.count >= limit { break }
        }
        return channels
    }

    private static func webURL(_ value: String) -> URL? {
        guard let components = URLComponents(string: value),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.host != nil,
              let url = components.url else { return nil }
        return url
    }

    private static func displayName(in line: String) -> String? {
        var isQuoted = false
        for index in line.indices {
            if line[index] == "\"" { isQuoted.toggle() }
            if line[index] == ",", !isQuoted {
                return String(line[line.index(after: index)...])
            }
        }
        return nil
    }

    private static func parseAttributes(_ line: String) -> [String: String] {
        let pattern = #"([A-Za-z0-9_-]+)="([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        var result: [String: String] = [:]
        for match in regex.matches(in: line, range: range) {
            guard let keyRange = Range(match.range(at: 1), in: line),
                  let valueRange = Range(match.range(at: 2), in: line) else { continue }
            result[String(line[keyRange]).lowercased()] = String(line[valueRange])
        }
        return result
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
