import Foundation
import Observation
import CryptoKit

@MainActor
@Observable
final class LiveTVService {
    static let shared = LiveTVService()

    private(set) var providers: [LiveTVProvider] = []
    private(set) var selectedProviderID: UUID?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var guideMessage: String?
    private(set) var isGuideStale = false
    /// True while a guide download for the selected playlist is in progress.
    private(set) var isGuideLoading = false
    /// Changes whenever any provider's guide listings change, so views can drop derived layout.
    private(set) var guideRevision = 0
    private(set) var favoriteChannelIDs = Set<String>()
    private(set) var channelCatalogRevision = 0

    private var channelCatalogs: [UUID: [LiveTVChannel]] = [:]
    private var guideIndexes: [UUID: EPGIndex] = [:]
    private var categoryCatalogs: [UUID: [String]] = [:]
    private var shortEPGLoaded = Set<String>()
    private let defaults: UserDefaults
    private let secretStore: LiveTVSecretStore
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let epg: EPGService
    /// The one Live TV player session for the process, created on first playback. Views read it
    /// from here so a SwiftUI redraw never allocates a player or registers an audio claim.
    @ObservationIgnored private(set) lazy var playerSession = LiveTVPlayerSession.makeDefault()
    /// One full-screen player presentation and Picture in Picture hand-off, shared by the channel
    /// list and the guide.
    @ObservationIgnored let presentation = LiveTVPresentation(scheduler: LiveTVTaskScheduler())
    #if os(iOS)
    @ObservationIgnored private var pictureInPictureMonitor: LiveTVPictureInPictureMonitor?
    #endif

    private static let providersKey = "liveTV.providers.v1"
    private static let favoritesKey = "liveTV.favorites.v1"
    private static let maximumPlaylistBytes = 16 * 1024 * 1024
    private static let maximumChannels = 20_000

    init(
        defaults: UserDefaults = .standard,
        secretStore: LiveTVSecretStore? = nil,
        session: URLSession? = nil,
        epg: EPGService? = nil
    ) {
        self.defaults = defaults
        self.secretStore = secretStore ?? KeychainLiveTVSecretStore()
        self.epg = epg ?? EPGService(
            cache: .makeDefault(),
            loader: session.map { URLSessionEPGFeedLoader(session: $0) } ?? URLSessionEPGFeedLoader.makeDefault())
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 20
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration)
        }
        presentation.stopPlayback = { [weak self] in self?.endPlayback() }
        #if os(iOS)
        presentation.stopPictureInPicture = { PictureInPictureCoordinator.shared.stopPictureInPicture() }
        #endif
        favoriteChannelIDs = Set(defaults.stringArray(forKey: Self.favoritesKey) ?? [])
        if let data = defaults.data(forKey: Self.providersKey),
           let saved = try? JSONDecoder().decode([LiveTVProvider].self, from: data) {
            providers = saved
            selectedProviderID = saved.first?.id
        }
    }

    var channels: [LiveTVChannel] {
        guard let selectedProviderID else { return [] }
        return channelCatalogs[selectedProviderID] ?? []
    }

    var favoriteChannels: [LiveTVChannel] {
        channels.filter { favoriteChannelIDs.contains($0.id) }
    }

    var selectedProvider: LiveTVProvider? {
        providers.first { $0.id == selectedProviderID }
    }

    func selectProvider(_ id: UUID) {
        guard providers.contains(where: { $0.id == id }) else { return }
        selectedProviderID = id
        errorMessage = nil
        updateGuideFreshness(for: id)
    }

    @discardableResult
    func saveConfiguration(name: String, playlistURL: String, xmltvURL: String?) throws -> UUID {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPlaylistURL = playlistURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanXMLTVURL = xmltvURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty,
              Self.isWebURL(cleanPlaylistURL),
              cleanXMLTVURL?.isEmpty != false || cleanXMLTVURL.map(Self.isWebURL) == true else {
            throw LiveTVError.invalidConfiguration
        }
        let configuration = LiveTVSourceConfiguration(
            playlistURL: cleanPlaylistURL,
            xmltvURL: cleanXMLTVURL?.nilIfEmpty
        )
        return try store(configuration, name: cleanName, kind: .m3u)
    }

    @discardableResult
    func saveXtreamConfiguration(name: String, serverURL: String, username: String, password: String) throws -> UUID {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanServer = serverURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let cleanUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, !cleanUsername.isEmpty, !password.isEmpty else { throw LiveTVError.invalidConfiguration }
        _ = try XtreamURLBuilder.apiURL(server: cleanServer, username: cleanUsername, password: password)
        let configuration = LiveTVSourceConfiguration(
            playlistURL: nil, xmltvURL: nil, kind: .xtream,
            serverURL: cleanServer, username: cleanUsername, password: password
        )
        return try store(configuration, name: cleanName, kind: .xtream)
    }

    private func store(_ configuration: LiveTVSourceConfiguration, name: String, kind: LiveTVProviderKind) throws -> UUID {
        let id = UUID()
        let encoded = try JSONEncoder().encode(configuration)
        guard let serialized = String(data: encoded, encoding: .utf8),
              secretStore.save(serialized, account: Self.secretAccount(id)) else {
            throw LiveTVError.keychainUnavailable
        }
        providers.append(LiveTVProvider(id: id, name: name, channelCount: 0, lastRefreshed: nil, kind: kind))
        selectedProviderID = id
        persistProviders()
        return id
    }

    func removeProvider(_ id: UUID) {
        presentation.providerRemoved(id, activeChannelID: playerSession.activeChannelID)
        providers.removeAll { $0.id == id }
        channelCatalogs[id] = nil
        guideIndexes[id] = nil
        guideRevision &+= 1
        categoryCatalogs[id] = nil
        shortEPGLoaded = shortEPGLoaded.filter { !$0.hasPrefix("\(id.uuidString):") }
        Task { [epg] in await epg.remove(providerID: id) }
        _ = secretStore.remove(account: Self.secretAccount(id))
        if selectedProviderID == id { selectedProviderID = providers.first?.id }
        persistProviders()
        if let selectedProviderID { updateGuideFreshness(for: selectedProviderID) }
    }

    func refreshSelectedProvider() async {
        guard let selectedProviderID else { return }
        await refresh(providerID: selectedProviderID)
    }

    func refresh(providerID: UUID) async {
        guard !isLoading,
              let providerIndex = providers.firstIndex(where: { $0.id == providerID }),
              let serialized = secretStore.read(account: Self.secretAccount(providerID)),
              let data = serialized.data(using: .utf8),
              let source = try? JSONDecoder().decode(LiveTVSourceConfiguration.self, from: data),
              (source.kind == .m3u ? source.playlistURL.map(Self.isWebURL) == true : source.serverURL.map(Self.isWebURL) == true) else {
            errorMessage = "Add a valid playlist in Live TV settings to load channels."
            return
        }

        isLoading = true
        errorMessage = nil
        guideMessage = nil

        do {
            let loadedChannels: [LiveTVChannel]
            if source.kind == .m3u, let playlistURL = source.playlistURL {
                let playlistData = try await fetch(playlistURL, maximumBytes: Self.maximumPlaylistBytes)
                let channelLimit = Self.maximumChannels
                loadedChannels = try await Task.detached(priority: .utility) {
                    try LiveTVM3UParser.parse(data: playlistData, providerID: providerID, limit: channelLimit)
                }.value
            } else {
                loadedChannels = try await loadXtream(source, providerID: providerID)
            }
            guard !loadedChannels.isEmpty else { throw LiveTVError.noChannels }
            channelCatalogs[providerID] = loadedChannels
            categoryCatalogs[providerID] = await Task.detached(priority: .utility) {
                Array(Set(loadedChannels.map(\.category))).sorted {
                    $0.localizedStandardCompare($1) == .orderedAscending
                }
            }.value
            channelCatalogRevision &+= 1
            providers[providerIndex].channelCount = loadedChannels.count
            providers[providerIndex].lastRefreshed = .now
            persistProviders()

        } catch let error as LiveTVError {
            errorMessage = error.localizedDescription
            isLoading = false
            return
        } catch {
            errorMessage = "The playlist could not be loaded. Check the provider settings and try again."
            isLoading = false
            return
        }
        // Channels are usable now; the guide fills in behind them.
        isLoading = false
        await refreshGuide(providerID: providerID, source: source)
    }

    /// Shows the cached guide immediately, then refreshes it when the policy says it is due.
    private func refreshGuide(providerID: UUID, source: LiveTVSourceConfiguration) async {
        let feed: EPGFeedSource?
        switch source.kind {
        case .m3u:
            feed = source.xmltvURL.flatMap(Self.webURL).map(EPGFeedSource.xmltv)
        case .xtream:
            if let server = source.serverURL, let username = source.username, let password = source.password {
                feed = .xtream(server: server, username: username, password: password)
            } else {
                feed = nil
            }
        }
        guard let feed else {
            guideIndexes[providerID] = nil
            guideRevision &+= 1
            await epg.remove(providerID: providerID)
            updateGuideFreshness(for: providerID)
            return
        }
        isGuideLoading = true
        defer { isGuideLoading = false }
        let channels = channelCatalogs[providerID] ?? []
        let filter = EPGChannelFilter(guideIDs: channels.map(\.guideID), names: channels.map(\.name))
        if guideIndexes[providerID] == nil, let cached = await epg.index(for: providerID) {
            guideIndexes[providerID] = cached
            guideRevision &+= 1
            updateGuideFreshness(for: providerID)
        }
        do {
            let index = try await epg.refresh(providerID: providerID, source: feed, channels: filter)
            guard providers.contains(where: { $0.id == providerID }) else { return }
            guideIndexes[providerID] = index
            guideRevision &+= 1
            guideMessage = index.programCount == 0 ? "No guide listings are available yet." : nil
        } catch is CancellationError {
            return
        } catch {
            // Keep a previously loaded guide; never print or surface a provider URL or transport error.
            guideMessage = "Guide data could not be refreshed."
        }
        updateGuideFreshness(for: providerID)
    }

    var categories: [String] {
        guard let selectedProviderID else { return [] }
        return categoryCatalogs[selectedProviderID] ?? []
    }

    private func loadXtream(_ source: LiveTVSourceConfiguration, providerID: UUID) async throws -> [LiveTVChannel] {
        guard let server = source.serverURL, let username = source.username, let password = source.password else {
            throw LiveTVError.invalidConfiguration
        }
        let authURL = try XtreamURLBuilder.apiURL(server: server, username: username, password: password)
        let authData = try await fetch(authURL, maximumBytes: 1024 * 1024)
        let outputFormats = try XtreamResponseParser.account(from: authData)
        if let providerIndex = providers.firstIndex(where: { $0.id == providerID }) {
            providers[providerIndex].allowedOutputFormats = outputFormats
            persistProviders()
        }

        var categoryNames: [String: String] = [:]
        if let categoryURL = try? XtreamURLBuilder.apiURL(server: server, username: username, password: password,
                                                           action: "get_live_categories"),
           let categoryData = try? await fetch(categoryURL, maximumBytes: 4 * 1024 * 1024) {
            categoryNames = await Task.detached(priority: .utility) {
                guard let records = try? XtreamResponseParser.categories(from: categoryData) else { return [:] }
                return Dictionary(records.compactMap { record in
                    guard let id = record.categoryID, let name = record.categoryName, !id.isEmpty, !name.isEmpty else { return nil }
                    return (id, name)
                }, uniquingKeysWith: { first, _ in first })
            }.value
        }

        let streamsURL = try XtreamURLBuilder.apiURL(server: server, username: username, password: password, action: "get_live_streams")
        let streamsData = try await fetch(streamsURL, maximumBytes: Self.maximumPlaylistBytes)
        let maxChannels = Self.maximumChannels
        let channels = try await Task.detached(priority: .utility) {
            let records = try XtreamResponseParser.streams(from: streamsData)
            var channels: [LiveTVChannel] = []
            channels.reserveCapacity(min(records.count, maxChannels))
            var seen = Set<Int>()
            for record in records.prefix(maxChannels) {
                guard let streamID = record.streamID, streamID > 0, seen.insert(streamID).inserted,
                      let name = record.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { continue }
                let streamURL = try XtreamURLBuilder.streamURL(server: server, username: username, password: password,
                    streamID: streamID, extension: record.containerExtension, allowedOutputFormats: outputFormats)
                let digest = SHA256.hash(data: Data("\(providerID.uuidString)|xtream|\(streamID)".utf8))
                    .map { String(format: "%02x", $0) }.joined()
                channels.append(LiveTVChannel(id: "\(providerID.uuidString):\(digest)",
                    guideID: record.epgChannelID?.nilIfEmpty ?? String(streamID), name: name, streamURL: streamURL,
                    logoURL: record.streamIcon.flatMap(Self.webURL),
                    category: record.categoryID.flatMap { categoryNames[$0] } ?? "Other", streamID: streamID))
            }
            return channels
        }.value
        guard !channels.isEmpty else { throw LiveTVError.noChannels }
        return channels
    }

    func refreshShortEPG(for channel: LiveTVChannel) async {
        guard let streamID = channel.streamID,
              let providerID = UUID(uuidString: String(channel.id.prefix(36))),
              !shortEPGLoaded.contains(channel.id),
              let serialized = secretStore.read(account: Self.secretAccount(providerID)),
              let data = serialized.data(using: .utf8),
              let source = try? JSONDecoder().decode(LiveTVSourceConfiguration.self, from: data),
              source.kind == .xtream, let server = source.serverURL,
              let username = source.username, let password = source.password else { return }
        shortEPGLoaded.insert(channel.id)
        do {
            let url = try XtreamURLBuilder.apiURL(server: server, username: username, password: password,
                                                 action: "get_short_epg", streamID: streamID, limit: 10)
            let data = try await fetch(url, maximumBytes: 512 * 1024)
            let guideID = channel.guideID ?? String(streamID)
            let programs = try XtreamEPG.programs(from: data, guideID: guideID, limits: epg.limits)
            let index = await epg.replacePrograms(programs, guideID: guideID, providerID: providerID)
            guard providers.contains(where: { $0.id == providerID }) else { return }
            guideIndexes[providerID] = index
            guideRevision &+= 1
            guideMessage = programs.isEmpty ? "No guide listings are available yet." : nil
            updateGuideFreshness(for: providerID)
        } catch {
            shortEPGLoaded.remove(channel.id)
            guideMessage = "Guide data could not be refreshed."
        }
    }

    /// Stops the live stream and releases its Picture in Picture binding. Nothing keeps playing.
    func endPlayback() {
        playerSession.stop()
        #if os(iOS)
        PictureInPictureCoordinator.shared.endSession(owner: playerSession)
        #endif
    }

    /// Binds Picture in Picture to the session once a tune has created its engine, and starts
    /// watching the session for failures while the window owns it.
    func attachPictureInPicture() {
        #if os(iOS)
        playerSession.bindPictureInPicture(presentation: presentation)
        if pictureInPictureMonitor == nil {
            pictureInPictureMonitor = LiveTVPictureInPictureMonitor(session: playerSession, presentation: presentation) { [weak self] in
                guard let self else { return }
                self.playerSession.bindPictureInPicture(presentation: self.presentation)
            }
        }
        #endif
    }

    /// A channel was chosen in the list or the guide. Opens the player, or retunes the Picture in
    /// Picture window in place.
    func choose(_ channel: LiveTVChannel, from presenter: LiveTVPresenter) {
        if presentation.select(channel, from: presenter) == .playInPlace {
            playerSession.play(channel)
        }
    }

    func toggleFavorite(_ channel: LiveTVChannel) {
        if !favoriteChannelIDs.insert(channel.id).inserted { favoriteChannelIDs.remove(channel.id) }
        defaults.set(favoriteChannelIDs.sorted(), forKey: Self.favoritesKey)
    }

    func isFavorite(_ channel: LiveTVChannel) -> Bool {
        favoriteChannelIDs.contains(channel.id)
    }

    func programPair(for channel: LiveTVChannel, at date: Date = .now) -> LiveTVProgramPair {
        guard let providerID = UUID(uuidString: String(channel.id.prefix(36))) else {
            return LiveTVProgramPair(current: nil, next: nil)
        }
        guard let index = guideIndexes[providerID] else { return LiveTVProgramPair(current: nil, next: nil) }
        let pair = index.nowNext(guideID: channel.guideID, name: channel.name, at: date)
        return LiveTVProgramPair(current: pair.current.map(LiveTVProgram.init), next: pair.next.map(LiveTVProgram.init))
    }

    /// Listings for one channel that overlap `interval`, in airing order. Empty when its guide is
    /// missing or no longer usable.
    func guidePrograms(for channel: LiveTVChannel, overlapping interval: DateInterval) -> [EPGProgram] {
        guard !isGuideStale,
              let providerID = UUID(uuidString: String(channel.id.prefix(36))),
              let index = guideIndexes[providerID],
              let key = index.channelKey(guideID: channel.guideID, name: channel.name) else { return [] }
        return index.programs(channelKey: key, overlapping: interval)
    }

    private func fetch(_ address: String, maximumBytes: Int) async throws -> Data {
        guard let url = URL(string: address), Self.isWebURL(address) else {
            throw LiveTVError.invalidConfiguration
        }
        return try await fetch(url, maximumBytes: maximumBytes)
    }

    private func fetch(_ url: URL, maximumBytes: Int) async throws -> Data {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil else {
            throw LiveTVError.invalidConfiguration
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/x-mpegURL, application/xml, text/xml, */*", forHTTPHeaderField: "Accept")
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LiveTVError.providerRejected
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LiveTVError.providerRejected
        }
        if http.expectedContentLength > Int64(maximumBytes) || data.count > maximumBytes {
            throw LiveTVError.responseTooLarge
        }
        return data
    }

    private func persistProviders() {
        guard let data = try? JSONEncoder().encode(providers) else { return }
        defaults.set(data, forKey: Self.providersKey)
    }

    private func updateGuideFreshness(for providerID: UUID) {
        guard let index = guideIndexes[providerID] else {
            isGuideStale = true
            return
        }
        isGuideStale = !epg.policy.freshness(of: index, now: .now).isUsable
    }

    private static func secretAccount(_ id: UUID) -> String { "provider.\(id.uuidString)" }

    nonisolated private static func isWebURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        return ["http", "https"].contains(components.scheme?.lowercased() ?? "")
            && components.host != nil
    }

    nonisolated private static func webURL(_ value: String) -> URL? {
        guard let components = URLComponents(string: value), ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.host != nil else { return nil }
        return components.url
    }
}

@MainActor
protocol LiveTVSecretStore {
    func read(account: String) -> String?
    func save(_ value: String, account: String) -> Bool
    func remove(account: String) -> Bool
}

@MainActor
struct KeychainLiveTVSecretStore: LiveTVSecretStore {
    private let keychain = SharedKeychain(service: "com.cubbiestream.kyro.livetv")

    func read(account: String) -> String? { keychain.get(account) }
    func save(_ value: String, account: String) -> Bool { keychain.set(value, for: account) }
    func remove(account: String) -> Bool { keychain.delete(account) }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
