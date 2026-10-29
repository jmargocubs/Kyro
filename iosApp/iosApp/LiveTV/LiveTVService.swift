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
    /// Soft notice for a successful import that hit the channel cap. Distinct from hard `errorMessage`
    /// failures such as an oversized playlist download.
    private(set) var catalogNotice: String?
    private(set) var guideMessage: String?
    private(set) var isGuideStale = false
    /// True while a guide download for the selected playlist is in progress.
    private(set) var isGuideLoading = false
    /// Changes whenever a full guide, provider, or source state changes, so views can drop
    /// derived layout. Single-channel short-guide publications use `guideChannelRevisions`.
    private(set) var guideRevision = 0
    /// Per-channel revisions let guide cells invalidate only the row whose short guide changed.
    /// IDs are provider-qualified, so switching providers cannot reuse a token accidentally.
    private(set) var guideChannelRevisions: [String: Int] = [:]
    private(set) var favoriteChannelIDs = Set<String>()
    private(set) var channelCatalogRevision = 0

    private var channelCatalogs: [UUID: [LiveTVChannel]] = [:]
    private var guideIndexes: [UUID: EPGIndex] = [:]
    private var categoryCatalogs: [UUID: [String]] = [:]
    private var shortEPGInFlight = Set<String>()
    private var shortEPGFreshUntil: [String: Date] = [:]
    private let shortEPGNow: () -> Date
    private let defaults: UserDefaults
    private let secretStore: LiveTVSecretStore
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let epg: EPGService
    @ObservationIgnored private let channelSnapshotStore: LiveTVChannelSnapshotStore
    /// The one playlist download in flight. Removing its provider cancels it and clears this, so a
    /// late result can no longer be applied.
    @ObservationIgnored private var playlistRefresh: (providerID: UUID, token: UUID, task: Task<LiveTVCachedCatalog, Error>)?
    /// Cached channel and guide restores, kept after they finish so each provider is read from disk once.
    @ObservationIgnored private var cacheRestores: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var guideCacheOrphanSweep: Task<Void, Never>?
    /// Providers whose channels came from a playlist download in this process, so they can play.
    @ObservationIgnored private var liveCatalogs = Set<UUID>()
    @ObservationIgnored private var automaticRefreshAttempts: [UUID: Date] = [:]
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
    /// A downloaded playlist older than this is refreshed when Live TV opens.
    private static let playlistRefreshInterval: TimeInterval = 12 * 60 * 60
    /// Opening Live TV again within this time does not retry a download that just ran or failed.
    private static let automaticRetryInterval: TimeInterval = 5 * 60

    init(
        defaults: UserDefaults = .standard,
        secretStore: LiveTVSecretStore? = nil,
        session: URLSession? = nil,
        epg: EPGService? = nil,
        channelSnapshotStore: LiveTVChannelSnapshotStore = LiveTVChannelSnapshotStore(),
        shortEPGNow: @escaping () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.secretStore = secretStore ?? KeychainLiveTVSecretStore()
        self.channelSnapshotStore = channelSnapshotStore
        self.shortEPGNow = shortEPGNow
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
        if let selectedProviderID {
            // Cached-first startup reads a verified v2 guide. Legacy v1 migration stays off:
            // `EPGService.migrateLegacyCache(providerID:source:)` is the only switch, and nothing
            // in startup, restore, or refresh calls it.
            Task { [weak self] in await self?.restoreCachedState(for: selectedProviderID) }
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
        catalogNotice = nil
        guideMessage = nil
        isGuideLoading = false
        updateGuideFreshness(for: id)
        Task { [weak self] in await self?.restoreCachedState(for: id) }
    }

    /// Shows the provider's cached channels and guide without touching the network. Concurrent
    /// callers share one disk read; the files are decoded off the main actor.
    func restoreCachedState(for providerID: UUID) async {
        if let restore = cacheRestores[providerID] { return await restore.value }
        guard providers.contains(where: { $0.id == providerID }) else { return }
        if let guideCacheOrphanSweep {
            await guideCacheOrphanSweep.value
        } else {
            let service = epg
            let knownProviderIDs = Set(providers.map(\.id))
            let sweep = Task { await service.removeOrphanedCacheFiles(keeping: knownProviderIDs) }
            guideCacheOrphanSweep = sweep
            await sweep.value
        }
        guard providers.contains(where: { $0.id == providerID }) else { return }
        if let restore = cacheRestores[providerID] { return await restore.value }
        let restore = Task { [weak self] in
            guard let self else { return }
            await self.loadCachedState(for: providerID)
        }
        cacheRestores[providerID] = restore
        await restore.value
    }

    private func loadCachedState(for providerID: UUID) async {
        let secrets = snapshotSecrets(providerID: providerID)
        let epgSource = loadSourceConfiguration(providerID: providerID).flatMap(Self.epgFeedSource)
        if channelCatalogs[providerID] == nil,
           let cached = await channelSnapshotStore.loadCatalog(providerID: providerID, secrets: secrets),
           // A download may have finished, or the provider been removed, while the file was read.
           channelCatalogs[providerID] == nil, providers.contains(where: { $0.id == providerID }) {
            channelCatalogs[providerID] = cached.channels
            categoryCatalogs[providerID] = cached.categories
            channelCatalogRevision &+= 1
        }
        // The guide cache is keyed by provider and only returned while still usable. Short-guide
        // listings alone never stand in for it.
        guard !showsFullGuide(providerID), let epgSource,
              let index = await epg.index(for: providerID, source: epgSource),
              !showsFullGuide(providerID), providers.contains(where: { $0.id == providerID }) else { return }
        guideIndexes[providerID] = index
        invalidateAllGuideRows()
        if selectedProviderID == providerID { updateGuideFreshness(for: providerID) }
    }

    /// Cached channels and guide first, then a playlist download only when one is due: no playable
    /// catalog yet this session, or the last download is old. Explicit refreshes skip this check.
    func prepareSelectedProvider(now: Date = .now) async {
        guard let providerID = selectedProviderID else { return }
        await restoreCachedState(for: providerID)
        guard selectedProviderID == providerID, needsAutomaticRefresh(providerID, now: now) else { return }
        automaticRefreshAttempts[providerID] = now
        await refresh(providerID: providerID)
    }

    private func needsAutomaticRefresh(_ providerID: UUID, now: Date) -> Bool {
        guard playlistRefresh == nil else { return false }
        if let attempt = automaticRefreshAttempts[providerID],
           now.timeIntervalSince(attempt) < Self.automaticRetryInterval { return false }
        guard liveCatalogs.contains(providerID),
              let refreshed = providers.first(where: { $0.id == providerID })?.lastRefreshed else { return true }
        return now.timeIntervalSince(refreshed) > Self.playlistRefreshInterval
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

    /// Forgets the provider at once, then deletes its files. Everything the UI reads (selection,
    /// channels, guide, status) is settled before the first suspension, so no view or late task can
    /// observe a selected provider that no longer exists.
    func removeProvider(_ id: UUID) async {
        forgetProvider(id)
        await deleteProviderFiles(id)
    }

    /// The synchronous half of removal: in-memory state, credentials and the selection.
    func forgetProvider(_ id: UUID) {
        presentation.providerRemoved(id, activeChannelID: playerSession.activeChannelID)
        if playlistRefresh?.providerID == id {
            playlistRefresh?.task.cancel()
            playlistRefresh = nil
            isLoading = false
        }
        cacheRestores.removeValue(forKey: id)?.cancel()
        liveCatalogs.remove(id)
        automaticRefreshAttempts[id] = nil
        providers.removeAll { $0.id == id }
        channelCatalogs[id] = nil
        categoryCatalogs[id] = nil
        guideIndexes[id] = nil
        invalidateAllGuideRows()
        channelCatalogRevision &+= 1
        favoriteChannelIDs = favoriteChannelIDs.filter { !$0.hasPrefix("\(id.uuidString):") }
        defaults.set(favoriteChannelIDs.sorted(), forKey: Self.favoritesKey)
        shortEPGInFlight = shortEPGInFlight.filter { !$0.hasPrefix("\(id.uuidString):") }
        shortEPGFreshUntil = shortEPGFreshUntil.filter { !$0.key.hasPrefix("\(id.uuidString):") }
        _ = secretStore.remove(account: Self.secretAccount(id))
        let wasSelected = selectedProviderID == id
        if wasSelected { selectedProviderID = providers.first?.id }
        persistProviders()
        // Status belongs to the selected provider; removing another one leaves it alone.
        guard wasSelected else { return }
        errorMessage = nil
        catalogNotice = nil
        guideMessage = nil
        isGuideLoading = false
        if let selectedProviderID { updateGuideFreshness(for: selectedProviderID) } else { isGuideStale = true }
    }

    /// The disk half of removal: the channel snapshot and the guide cache.
    func deleteProviderFiles(_ id: UUID) async {
        await channelSnapshotStore.remove(providerID: id)
        await epg.remove(providerID: id)
    }

    func refreshSelectedProvider() async {
        guard let selectedProviderID else { return }
        await refresh(providerID: selectedProviderID)
    }

    func refresh(providerID: UUID) async {
        guard playlistRefresh == nil else { return }
        guard providers.contains(where: { $0.id == providerID }),
              let serialized = secretStore.read(account: Self.secretAccount(providerID)),
              let data = serialized.data(using: .utf8),
              let source = try? JSONDecoder().decode(LiveTVSourceConfiguration.self, from: data),
              (source.kind == .m3u ? source.playlistURL.map(Self.isWebURL) == true : source.serverURL.map(Self.isWebURL) == true) else {
            if selectedProviderID == providerID {
                errorMessage = "Add a valid playlist in Live TV settings to load channels."
            }
            return
        }

        let token = UUID()
        let work = Task { [weak self] () throws -> LiveTVCachedCatalog in
            guard let self else { throw CancellationError() }
            return try await self.downloadCatalog(source, providerID: providerID)
        }
        playlistRefresh = (providerID, token, work)
        isLoading = true
        if selectedProviderID == providerID {
            errorMessage = nil
            catalogNotice = nil
            guideMessage = nil
        }

        let result = await work.result
        // Removing the provider cancels this refresh and has already cleared the loading state.
        guard playlistRefresh?.token == token else { return }
        playlistRefresh = nil
        isLoading = false
        guard providers.contains(where: { $0.id == providerID }) else { return }

        let loaded: LiveTVCachedCatalog
        switch result {
        case .success(let catalog):
            loaded = catalog
        case .failure(let error as LiveTVError):
            if selectedProviderID == providerID { errorMessage = error.localizedDescription }
            return
        case .failure:
            if selectedProviderID == providerID {
                errorMessage = "The playlist could not be loaded. Check the provider settings and try again."
            }
            return
        }
        let previousChannels = channelCatalogs[providerID] ?? []
        let previousFilter = EPGChannelFilter(guideIDs: previousChannels.map(\.guideID), names: previousChannels.map(\.name))
        let updatedFilter = EPGChannelFilter(guideIDs: loaded.channels.map(\.guideID), names: loaded.channels.map(\.name))
        let guideFilterChanged = !previousChannels.isEmpty && previousFilter != updatedFilter
        channelCatalogs[providerID] = loaded.channels
        categoryCatalogs[providerID] = loaded.categories
        channelCatalogRevision &+= 1
        liveCatalogs.insert(providerID)
        if let providerIndex = providers.firstIndex(where: { $0.id == providerID }) {
            providers[providerIndex].channelCount = loaded.channels.count
            providers[providerIndex].lastRefreshed = .now
            persistProviders()
        }
        if selectedProviderID == providerID {
            catalogNotice = loaded.hitChannelLimit
                ? LiveTVCatalogNotice.channelLimitReached(limit: Self.maximumChannels)
                : nil
        }

        await channelSnapshotStore.save(providerID: providerID, channels: loaded.channels,
                                        secrets: LiveTVSnapshotSecrets(source: source))
        // The provider may have been removed while the snapshot was written; never leave it behind.
        guard providers.contains(where: { $0.id == providerID }) else {
            await channelSnapshotStore.remove(providerID: providerID)
            return
        }
        // Channels are usable now; the guide fills in behind them.
        await refreshGuide(providerID: providerID, source: source, force: guideFilterChanged)
    }

    private func downloadCatalog(_ source: LiveTVSourceConfiguration, providerID: UUID) async throws -> LiveTVCachedCatalog {
        let loadedChannels: [LiveTVChannel]
        let hitChannelLimit: Bool
        if source.kind == .m3u, let playlistURL = source.playlistURL {
            let playlistData = try await fetch(playlistURL, maximumBytes: Self.maximumPlaylistBytes)
            let channelLimit = Self.maximumChannels
            let parsed = try await Task.detached(priority: .utility) {
                try LiveTVM3UParser.parseResult(data: playlistData, providerID: providerID, limit: channelLimit)
            }.value
            loadedChannels = parsed.channels
            hitChannelLimit = parsed.hitChannelLimit
        } else {
            let xtream = try await loadXtream(source, providerID: providerID)
            loadedChannels = xtream.channels
            hitChannelLimit = xtream.hitChannelLimit
        }
        guard !loadedChannels.isEmpty else { throw LiveTVError.noChannels }
        let categories = await Task.detached(priority: .utility) {
            LiveTVChannel.orderedCategories(of: loadedChannels)
        }.value
        return LiveTVCachedCatalog(channels: loadedChannels, categories: categories, hitChannelLimit: hitChannelLimit)
    }

    /// Shows the cached guide immediately, then refreshes it when the policy says it is due.
    private func refreshGuide(providerID: UUID, source: LiveTVSourceConfiguration, force: Bool = false) async {
        guard providers.contains(where: { $0.id == providerID }) else { return }
        let feed = Self.epgFeedSource(source)
        guard let feed else {
            guideIndexes[providerID] = nil
            invalidateAllGuideRows()
            await epg.clear(providerID: providerID)
            guard providers.contains(where: { $0.id == providerID }) else { return }
            if selectedProviderID == providerID {
                guideMessage = nil
                updateGuideFreshness(for: providerID)
            }
            return
        }
        if selectedProviderID == providerID { isGuideLoading = true }
        defer { if selectedProviderID == providerID { isGuideLoading = false } }
        let channels = channelCatalogs[providerID] ?? []
        let filter = EPGChannelFilter(guideIDs: channels.map(\.guideID), names: channels.map(\.name))
        let currentEPGSource = Self.epgFeedSource(source)
        if !showsFullGuide(providerID), let currentEPGSource {
            let cached = await epg.index(for: providerID, source: currentEPGSource)
            // Removal can finish while the source-verified cached read is queued on disk. Never
            // fall through and start a network refresh after that await.
            guard providers.contains(where: { $0.id == providerID }) else { return }
            if let cached, !showsFullGuide(providerID) {
                guideIndexes[providerID] = cached
                invalidateAllGuideRows()
                if selectedProviderID == providerID { updateGuideFreshness(for: providerID) }
            }
        }
        guard providers.contains(where: { $0.id == providerID }) else { return }
        do {
            let index = try await epg.refresh(providerID: providerID, source: feed, channels: filter, force: force)
            guard providers.contains(where: { $0.id == providerID }) else { return }
            guideIndexes[providerID] = index
            invalidateAllGuideRows()
            if selectedProviderID == providerID {
                guideMessage = EPGGuideStatus.message(for: index)
            }
        } catch is CancellationError {
            return
        } catch {
            // Keep a previously loaded guide; never print or surface a provider URL or transport error.
            if providers.contains(where: { $0.id == providerID }), selectedProviderID == providerID {
                guideMessage = "Guide data could not be refreshed."
            }
        }
        if providers.contains(where: { $0.id == providerID }), selectedProviderID == providerID {
            updateGuideFreshness(for: providerID)
        }
    }

    var categories: [String] {
        guard let selectedProviderID else { return [] }
        return categoryCatalogs[selectedProviderID] ?? []
    }

    private func loadXtream(_ source: LiveTVSourceConfiguration, providerID: UUID) async throws -> (channels: [LiveTVChannel], hitChannelLimit: Bool) {
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
        let parsed = try await Task.detached(priority: .utility) {
            let records = try XtreamResponseParser.streams(from: streamsData)
            var channels: [LiveTVChannel] = []
            channels.reserveCapacity(min(records.count, maxChannels))
            var seen = Set<Int>()
            var accepted = 0
            var hitChannelLimit = false
            for record in records {
                if accepted >= maxChannels {
                    // More stream records remain after the cap; do not invent a total count.
                    hitChannelLimit = true
                    break
                }
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
                accepted += 1
            }
            return (channels: channels, hitChannelLimit: hitChannelLimit)
        }.value
        guard !parsed.channels.isEmpty else { throw LiveTVError.noChannels }
        return (channels: parsed.channels, hitChannelLimit: parsed.hitChannelLimit)
    }

    func refreshShortEPG(for channel: LiveTVChannel) async {
        guard let streamID = channel.streamID,
              let providerID = UUID(uuidString: String(channel.id.prefix(36))),
              !shortEPGInFlight.contains(channel.id) else { return }
        let guideID = channel.guideID ?? String(streamID)
        if (shortEPGFreshUntil[channel.id] ?? .distantPast) > shortEPGNow(),
           await epg.hasShortGuide(providerID: providerID, guideID: guideID) {
            return
        }
        guard
              let serialized = secretStore.read(account: Self.secretAccount(providerID)),
              let data = serialized.data(using: .utf8),
              let source = try? JSONDecoder().decode(LiveTVSourceConfiguration.self, from: data),
              source.kind == .xtream, let server = source.serverURL,
              let username = source.username, let password = source.password else { return }
        shortEPGInFlight.insert(channel.id)
        defer { shortEPGInFlight.remove(channel.id) }
        // The ticket is issued before the request is sent. A full refresh, source change or removal
        // that happens while the request is in flight makes the response stale, and EPGService drops it.
        guard let epgSource = Self.epgFeedSource(source),
              let ticket = await epg.beginShortRequest(providerID: providerID, source: epgSource,
                                                       guideID: guideID) else {
            return
        }
        do {
            let url = try XtreamURLBuilder.apiURL(server: server, username: username, password: password,
                                                 action: "get_short_epg", streamID: streamID, limit: 10)
            let data = try await fetch(url, maximumBytes: 512 * 1024)
            try Task.checkCancellation()
            guard providers.contains(where: { $0.id == providerID }) else { return }
            let programs = try XtreamEPG.programs(from: data, guideID: guideID, limits: epg.limits)
            guard let publication = await epg.applyShortProgramsWithRetention(programs, guideID: guideID,
                                                                                ticket: ticket) else {
                // Superseded by a newer full guide, a newer response for this channel, a source
                // change, or cancelled before publication. A later selection may request it again.
                return
            }
            let index = publication.index
            shortEPGFreshUntil[channel.id] = shortEPGNow().addingTimeInterval(programs.isEmpty ? 5 * 60 : 15 * 60)
            if shortEPGFreshUntil.count > 256,
               let oldest = shortEPGFreshUntil.min(by: { $0.value < $1.value })?.key {
                shortEPGFreshUntil.removeValue(forKey: oldest)
            }
            guard providers.contains(where: { $0.id == providerID }) else { return }
            // A short-guide result that lost the race with cache load must not replace a full guide
            // already published here. Re-read so the short listings are applied on top of it.
            let published: EPGIndex
            if index.isShortGuideOnly, showsFullGuide(providerID) {
                guard let merged = await epg.index(for: providerID, source: epgSource),
                      !merged.isShortGuideOnly,
                      providers.contains(where: { $0.id == providerID }) else {
                    return
                }
                published = merged
            } else {
                published = index
            }
            guideIndexes[providerID] = published
            for evictedGuideID in publication.evictedGuideIDs {
                let evictedKey = EPGChannelKey.guideID(evictedGuideID)
                for evictedChannel in channelCatalogs[providerID] ?? []
                    where EPGChannelKey.guideID(evictedChannel.guideID) == evictedKey {
                    guideChannelRevisions[evictedChannel.id, default: 0] &+= 1
                }
            }
            guideChannelRevisions[channel.id, default: 0] &+= 1
            if selectedProviderID == providerID {
                // An empty short response is not evidence that the full guide has no listings.
                guideMessage = EPGGuideStatus.message(for: published)
                updateGuideFreshness(for: providerID)
            }
        } catch {
            // Bound retries for transport/parse failures; cancellation remains immediately retryable.
            if !(error is CancellationError), !Task.isCancelled {
                shortEPGFreshUntil[channel.id] = shortEPGNow().addingTimeInterval(2 * 60)
                if shortEPGFreshUntil.count > 256,
                   let oldest = shortEPGFreshUntil.min(by: { $0.value < $1.value })?.key {
                    shortEPGFreshUntil.removeValue(forKey: oldest)
                }
            }
            // The shared fetch reports a cancelled download as a provider error; the task's own
            // cancellation state is authoritative. Cancellation is not a failure to report.
            guard !(error is CancellationError), !Task.isCancelled else { return }
            if providers.contains(where: { $0.id == providerID }), selectedProviderID == providerID {
                guideMessage = "Guide data could not be refreshed."
            }
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
        guard isPlayable(channel) else { rejectCachedPlayback(); return }
        Task { await refreshShortEPG(for: channel) }
        if presentation.select(channel, from: presenter) == .playInPlace {
            playerSession.play(channel)
        }
    }

    /// Shared validation and session route for channel-picker retunes inside the player.
    @discardableResult
    func playFromPlayerPicker(_ channel: LiveTVChannel) -> Bool {
        guard isPlayable(channel) else { rejectCachedPlayback(); return false }
        Task { await refreshShortEPG(for: channel) }
        errorMessage = nil
        presentation.playerChannelChanged(to: channel)
        playerSession.play(channel)
        return true
    }

    private func isPlayable(_ channel: LiveTVChannel) -> Bool {
        guard let providerID = UUID(uuidString: String(channel.id.prefix(36))),
              providers.contains(where: { $0.id == providerID }),
              let scheme = channel.streamURL.scheme?.lowercased() else { return false }
        return ["http", "https"].contains(scheme)
    }

    private func rejectCachedPlayback() {
        if selectedProviderID != nil { errorMessage = "Refresh the playlist to play this channel." }
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

    func guideChannelRevision(for channel: LiveTVChannel) -> Int {
        guideChannelRevisions[channel.id] ?? 0
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

    private func snapshotSecrets(providerID: UUID) -> LiveTVSnapshotSecrets {
        guard let source = loadSourceConfiguration(providerID: providerID) else { return LiveTVSnapshotSecrets() }
        return LiveTVSnapshotSecrets(source: source)
    }

    private func loadSourceConfiguration(providerID: UUID) -> LiveTVSourceConfiguration? {
        guard let serialized = secretStore.read(account: Self.secretAccount(providerID)),
              let data = serialized.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(LiveTVSourceConfiguration.self, from: data)
    }

    private static func epgFeedSource(_ source: LiveTVSourceConfiguration) -> EPGFeedSource? {
        switch source.kind {
        case .m3u:
            return source.xmltvURL.flatMap(webURL).map(EPGFeedSource.xmltv)
        case .xtream:
            guard let server = source.serverURL, let username = source.username, let password = source.password else { return nil }
            return .xtream(server: server, username: username, password: password)
        }
    }

    /// Whether the provider shows a full guide, not just Xtream short-guide listings.
    private func showsFullGuide(_ providerID: UUID) -> Bool {
        guideIndexes[providerID].map { !$0.isShortGuideOnly } ?? false
    }

    private func invalidateAllGuideRows() {
        guideRevision &+= 1
        guideChannelRevisions.removeAll(keepingCapacity: true)
    }

    private func updateGuideFreshness(for providerID: UUID) {
        guard selectedProviderID == providerID else { return }
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
