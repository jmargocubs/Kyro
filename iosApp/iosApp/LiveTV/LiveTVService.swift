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
    private(set) var favoriteChannelIDs = Set<String>()
    private(set) var channelCatalogRevision = 0

    private var channelCatalogs: [UUID: [LiveTVChannel]] = [:]
    private var guideCatalogs: [UUID: [LiveTVProgram]] = [:]
    private var guideIndexes: [UUID: [String: [LiveTVProgram]]] = [:]
    private var categoryCatalogs: [UUID: [String]] = [:]
    private var shortEPGLoaded = Set<String>()
    private var guideRefreshDates: [UUID: Date] = [:]
    private let defaults: UserDefaults
    private let secretStore: LiveTVSecretStore
    @ObservationIgnored private let session: URLSession
    /// The one Live TV player session for the process, created on first playback. Views read it
    /// from here so a SwiftUI redraw never allocates a player or registers an audio claim.
    @ObservationIgnored private(set) lazy var playerSession = LiveTVPlayerSession.makeDefault()

    private static let providersKey = "liveTV.providers.v1"
    private static let favoritesKey = "liveTV.favorites.v1"
    private static let maximumPlaylistBytes = 16 * 1024 * 1024
    private static let maximumGuideBytes = 16 * 1024 * 1024
    private static let maximumChannels = 20_000
    private static let maximumPrograms = 50_000

    init(
        defaults: UserDefaults = .standard,
        secretStore: LiveTVSecretStore? = nil,
        session: URLSession? = nil
    ) {
        self.defaults = defaults
        self.secretStore = secretStore ?? KeychainLiveTVSecretStore()
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 20
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration)
        }
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
        providers.removeAll { $0.id == id }
        channelCatalogs[id] = nil
        guideCatalogs[id] = nil
        guideIndexes[id] = nil
        categoryCatalogs[id] = nil
        shortEPGLoaded = shortEPGLoaded.filter { !$0.hasPrefix("\(id.uuidString):") }
        guideRefreshDates[id] = nil
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
        defer { isLoading = false }

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

            if source.kind == .m3u, let xmltvURL = source.xmltvURL, Self.isWebURL(xmltvURL) {
                do {
                    let guideData = try await fetch(xmltvURL, maximumBytes: Self.maximumGuideBytes)
                    let guideLimit = Self.maximumPrograms
                    let (loadedGuide, guideIndex) = try await Task.detached(priority: .utility) {
                        let guide = try LiveTVXMLTVParser.parse(data: guideData, limit: guideLimit)
                        return (guide, Self.index(guide))
                    }.value
                    guideCatalogs[providerID] = loadedGuide
                    guideIndexes[providerID] = guideIndex
                    guideRefreshDates[providerID] = .now
                    guideMessage = loadedGuide.isEmpty ? "No guide listings are available yet." : nil
                } catch {
                    // Keep a previously parsed guide for this session; never
                    // print or surface a provider URL or transport error.
                    guideMessage = "Guide data could not be refreshed."
                }
            } else {
                if source.kind == .m3u {
                    guideCatalogs[providerID] = []
                    guideIndexes[providerID] = [:]
                    guideRefreshDates[providerID] = nil
                }
            }
            updateGuideFreshness(for: providerID)
        } catch let error as LiveTVError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = "The playlist could not be loaded. Check the provider settings and try again."
        }
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
            let response = try JSONDecoder().decode(XtreamShortEPGResponse.self,
                from: await fetch(url, maximumBytes: 512 * 1024))
            let programs = (response.epgList ?? []).compactMap { item -> LiveTVProgram? in
                guard let title = item.title?.nilIfEmpty,
                      let startValue = item.startTimestamp.flatMap(TimeInterval.init),
                      let endValue = item.stopTimestamp.flatMap(TimeInterval.init), startValue < endValue else { return nil }
                return LiveTVProgram(id: "xtream:\(streamID):\(Int(startValue))", channelID: channel.guideID ?? String(streamID),
                                     title: title, startsAt: Date(timeIntervalSince1970: startValue), endsAt: Date(timeIntervalSince1970: endValue))
            }
            let guideID = channel.guideID ?? String(streamID)
            guideCatalogs[providerID, default: []].removeAll { $0.channelID == guideID }
            guideCatalogs[providerID, default: []].append(contentsOf: programs)
            guideIndexes[providerID, default: [:]][guideID] = programs.sorted { $0.startsAt < $1.startsAt }
            guideRefreshDates[providerID] = .now
            guideMessage = programs.isEmpty ? "No guide listings are available yet." : nil
            updateGuideFreshness(for: providerID)
        } catch {
            shortEPGLoaded.remove(channel.id)
            guideMessage = "Guide data could not be refreshed."
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
        return LiveTVProgramSelection.pair(channelGuideID: channel.guideID,
                                           programsByChannel: guideIndexes[providerID] ?? [:], at: date)
    }

    nonisolated private static func index(_ programs: [LiveTVProgram]) -> [String: [LiveTVProgram]] {
        Dictionary(grouping: programs, by: \.channelID).mapValues { $0.sorted { $0.startsAt < $1.startsAt } }
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
        guard let refreshed = guideRefreshDates[providerID] else {
            isGuideStale = !(guideCatalogs[providerID]?.isEmpty == false)
            return
        }
        isGuideStale = Date.now.timeIntervalSince(refreshed) > 36 * 60 * 60
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
