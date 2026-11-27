#if os(iOS)
import NukeUI
import Observation
import SwiftUI

// Build 139: IPTV music channels in Radio. Reads the existing indexed Live TV
// catalog (no second import or database), organises music channels into
// collections, and plays them with Radio's audio player. Channels stay in
// Live TV; Radio only organises them.

// MARK: - History

/// A played IPTV music channel: a reference by channel ID, never its stream
/// address (which can carry provider credentials).
struct KyroIPTVHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    let channelID: String
    let providerID: UUID
    let name: String
    let providerName: String
    let category: String
    let collection: KyroMusicCollection
    let logo: URL?
    let guideID: String?
    var date: Date
    var id: String { channelID }

    static let key = "kyrox.radio.iptvHistory.v1"
    static let limit = 50

    /// Logos are kept only when the address carries no query or credentials.
    static func safeLogo(_ url: URL?) -> URL? {
        guard let url, url.query == nil, url.user == nil, url.password == nil,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }
}

// MARK: - Library

@MainActor @Observable
final class KyroIPTVMusicLibrary: KyroRadioExternalStations {
    static let shared = KyroIPTVMusicLibrary()

    private(set) var preferences: KyroIPTVMusicPreferences
    private(set) var history: [KyroIPTVHistoryEntry]
    /// One index per configured provider, including excluded ones (Settings shows them).
    private(set) var indexes: [KyroIPTVMusicIndex] = []
    private(set) var isBuilding = false
    /// Increases when the listener changes a classification, so open pages reload.
    private(set) var revision = 0
    @ObservationIgnored private var builtKey: String?
    @ObservationIgnored private var lookup: [UUID: [String: KyroIPTVMusicIndex.Category]] = [:]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preferences = KyroIPTVMusicPreferences.load(from: defaults)
        history = defaults.data(forKey: KyroIPTVHistoryEntry.key)
            .flatMap { try? JSONDecoder().decode([KyroIPTVHistoryEntry].self, from: $0) } ?? []
        KyroRadioLibrary.shared.external = self
        // A Settings Backup restore may have changed music source preferences.
        NotificationCenter.default.addObserver(forName: .kyroSettingsDidRestore, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    private var service: LiveTVService { .shared }

    /// Indexes Radio uses: integration on, provider not excluded, provider still configured.
    var activeIndexes: [KyroIPTVMusicIndex] {
        guard preferences.enabled else { return [] }
        let configured = Set(service.providers.map(\.id))
        return indexes.filter { configured.contains($0.providerID) && !preferences.excludedProviders.contains($0.providerID) }
    }

    var availableCollections: [KyroMusicCollection] {
        KyroMusicCollection.allCases.filter { count($0) > 0 }
    }

    func count(_ collection: KyroMusicCollection) -> Int {
        activeIndexes.reduce(0) { $0 + $1.count(collection) }
    }

    func providerNames(_ collection: KyroMusicCollection) -> [String] {
        activeIndexes.filter { $0.count(collection) > 0 }.map(\.providerName)
    }

    // MARK: Classification refresh

    /// Rebuilds only when the catalog, provider list, hidden categories or a
    /// manual decision changed. Each provider costs one category query and a
    /// few bounded full-text searches, all off the main thread.
    func refresh() async {
        let providers = service.providers
        let hidden = Dictionary(uniqueKeysWithValues: providers.map {
            ($0.id, LiveTVCategoryPreferences.load(providerID: $0.id).hidden)
        })
        let prefs = preferences
        let key = ([String(service.channelCatalogRevision), String(revision)]
            + providers.map { "\($0.id)" } + hidden.sorted { $0.key.uuidString < $1.key.uuidString }.map { $0.value.sorted().joined(separator: ",") })
            .joined(separator: "|")
        guard key != builtKey, !providers.isEmpty else {
            if providers.isEmpty { indexes = []; lookup = [:] }
            return
        }
        isBuilding = true
        defer { isBuilding = false }
        var built: [KyroIPTVMusicIndex] = []
        for provider in providers {
            let extra = prefs.channelOverrides.keys.filter { $0.hasPrefix(provider.id.uuidString) }
            guard let snapshot = await service.musicCatalogSnapshot(providerID: provider.id, extraChannelIDs: Array(extra)) else { continue }
            guard !Task.isCancelled else { return }
            let hiddenSet = hidden[provider.id] ?? []
            let index = await Task.detached(priority: .utility) {
                KyroIPTVMusicIndexer.build(snapshot, categoryAssignments: prefs.categoryAssignments,
                                           channelOverrides: prefs.channelOverrides, hidden: hiddenSet)
            }.value
            built.append(index)
        }
        guard !Task.isCancelled else { return }
        indexes = built
        lookup = Dictionary(uniqueKeysWithValues: built.map { index in
            (index.providerID, Dictionary(index.categories.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first }))
        })
        builtKey = key
    }

    static func providerID(of channelID: String) -> UUID? { UUID(uuidString: String(channelID.prefix(36))) }

    /// The channel's collection, or nil when it isn't music, is hidden in Live
    /// TV, or its provider is excluded.
    func collection(of channel: LiveTVChannel) -> KyroMusicCollection? {
        guard preferences.enabled, let providerID = Self.providerID(of: channel.id),
              !preferences.excludedProviders.contains(providerID), let categories = lookup[providerID] else { return nil }
        let category = categories[channel.category]
        if category?.isHidden == true { return nil }
        return KyroMusicClassifier.resolve(channelID: channel.id, name: channel.name, category: channel.category,
                                           channelOverrides: preferences.channelOverrides,
                                           categoryCollection: { categories[$0]?.collection })
    }

    func providerName(_ providerID: UUID) -> String {
        indexes.first { $0.providerID == providerID }?.providerName
            ?? service.providers.first { $0.id == providerID }?.name ?? "IPTV"
    }

    /// A Radio station for the channel, played by Radio's audio player.
    func station(for channel: LiveTVChannel, collection: KyroMusicCollection) -> KyroRadioStation? {
        guard let providerID = Self.providerID(of: channel.id) else { return nil }
        let options = service.musicStreamOptions(providerID: providerID)
        let candidates = KyroIPTVAudioRoute.candidates(for: channel.streamURL, isXtream: options.isXtream,
                                                       allowedFormats: options.formats)
        // Build 140: `streamURL` is the channel's own address (played first,
        // and the one Watch in Live TV uses); `resolvedURL` is the optional
        // HLS fallback.
        guard let original = candidates.first else { return nil }
        var station = KyroRadioStation(id: channel.id, name: channel.name, streamURL: original,
                                       resolvedURL: candidates.count > 1 ? candidates.last : nil,
                                       favicon: channel.logoURL, tags: channel.category.isEmpty ? [] : [channel.category],
                                       isHLS: original.pathExtension.lowercased() == "m3u8")
        station.iptv = KyroIPTVStationSource(providerID: providerID, providerName: providerName(providerID),
                                             channelID: channel.id, collection: collection,
                                             category: channel.category, guideID: channel.guideID)
        return station
    }

    func liveChannel(for station: KyroRadioStation) -> LiveTVChannel? {
        guard let source = station.iptv, let stream = station.streamURL else { return nil }
        return LiveTVChannel(id: source.channelID, guideID: source.guideID, name: station.name, streamURL: stream,
                             logoURL: station.favicon, category: source.category)
    }

    // MARK: Playback

    /// Resolves a saved reference against the current catalog and plays it.
    /// Returns false when the channel no longer exists or isn't music any more.
    @discardableResult
    func play(channelID: String) async -> Bool {
        guard let providerID = Self.providerID(of: channelID),
              let channel = await service.musicChannels(providerID: providerID, ids: [channelID]).first else { return false }
        await refresh()
        guard let collection = collection(of: channel) ?? preferences.channelOverrides[channelID]?.collection,
              let station = station(for: channel, collection: collection) else { return false }
        KyroRadioPlayer.shared.play(station)
        return true
    }

    /// The Live TV player for the same channel: the video, or a stream the
    /// audio player can't read. Radio stops first, so only one session plays.
    func watchInLiveTV(_ station: KyroRadioStation) async {
        guard let source = station.iptv,
              let channel = await service.musicChannels(providerID: source.providerID, ids: [source.channelID]).first else { return }
        KyroRadioPlayer.shared.stop()
        service.choose(channel, from: .shell)
    }

    // MARK: KyroRadioExternalStations

    /// Live TV's favorite store is the one source of truth, so a heart in Radio
    /// and a star in Live TV can never disagree.
    func isFavorite(_ id: String) -> Bool { service.favoriteChannelIDs.contains(id) }

    func toggleFavorite(_ station: KyroRadioStation) {
        guard let channel = liveChannel(for: station) else { return }
        service.toggleFavorite(channel)
    }

    func recordPlay(_ station: KyroRadioStation) {
        guard let source = station.iptv else { return }
        history.removeAll { $0.channelID == source.channelID }
        history.insert(KyroIPTVHistoryEntry(channelID: source.channelID, providerID: source.providerID, name: station.name,
                                            providerName: source.providerName, category: source.category,
                                            collection: source.collection, logo: KyroIPTVHistoryEntry.safeLogo(station.favicon),
                                            guideID: source.guideID, date: Date()), at: 0)
        if history.count > KyroIPTVHistoryEntry.limit { history.removeLast(history.count - KyroIPTVHistoryEntry.limit) }
        saveHistory()
    }

    func removeFromHistory(_ id: String) { history.removeAll { $0.channelID == id }; saveHistory() }
    func clearHistory() { history = []; saveHistory() }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) { defaults.set(data, forKey: KyroIPTVHistoryEntry.key) }
    }

    /// Favorite music channels, resolved against the current catalog (at most 200 per provider).
    func favoriteStations() async -> [KyroRadioStation] {
        await refresh()
        var result: [KyroRadioStation] = []
        for index in activeIndexes {
            let prefix = index.providerID.uuidString + ":"
            let ids = service.favoriteChannelIDs.filter { $0.hasPrefix(prefix) }.sorted()
            guard !ids.isEmpty else { continue }
            for channel in await service.musicChannels(providerID: index.providerID, ids: Array(ids.prefix(200))) {
                if let collection = collection(of: channel), let station = station(for: channel, collection: collection) {
                    result.append(station)
                }
            }
        }
        return result
    }

    // MARK: Manual management

    private func update(_ change: (inout KyroIPTVMusicPreferences) -> Void) {
        var next = preferences
        change(&next)
        guard next != preferences else { return }
        preferences = next
        preferences.save(to: defaults)
        revision &+= 1
    }

    func setEnabled(_ enabled: Bool) { update { $0.enabled = enabled } }

    func setProvider(_ providerID: UUID, included: Bool) {
        update { if included { $0.excludedProviders.remove(providerID) } else { $0.excludedProviders.insert(providerID) } }
    }

    /// nil returns the category to automatic classification.
    func assignCategory(_ name: String, _ assignment: KyroMusicAssignment?) {
        update {
            $0.categoryAssignments[name] = assignment
            if $0.categoryAssignments.count > KyroIPTVMusicPreferences.maxCategoryAssignments, assignment != nil {
                $0.categoryAssignments[name] = nil
            }
        }
    }

    /// nil returns the channel to automatic classification.
    func overrideChannel(_ id: String, _ assignment: KyroMusicAssignment?) {
        update {
            $0.channelOverrides[id] = assignment
            if $0.channelOverrides.count > KyroIPTVMusicPreferences.maxChannelOverrides, assignment != nil {
                $0.channelOverrides[id] = nil
            }
        }
    }

    func resetOverrides() {
        update { $0.categoryAssignments = [:]; $0.channelOverrides = [:] }
    }

    /// Settings Backup restored new preferences.
    func reload() {
        preferences = KyroIPTVMusicPreferences.load(from: defaults)
        revision &+= 1
    }
}

// MARK: - Collection browsing

/// Pages a collection's channels from the indexed catalog: each music
/// category in turn (60 at a time), then channels found by name. Every page is
/// checked channel by channel, so music television in a music category and
/// manual exclusions never appear.
@MainActor @Observable
final class KyroIPTVCollectionBrowser {
    let collection: KyroMusicCollection
    private(set) var stations: [KyroRadioStation] = []
    private(set) var isLoading = false
    private(set) var canLoadMore = true
    /// Build 140: false until the first page for the current query returns, so
    /// the page shows a loading state instead of a brief "No Channels".
    private(set) var hasLoaded = false
    /// No enabled provider has this collection (catalog still loading,
    /// integration off, or every provider excluded).
    private(set) var isUnavailable = false
    var query = ""

    private struct Source {
        let providerID: UUID
        let category: String?
        let channelIDs: [String]
        var offset = 0
        var done = false
    }
    @ObservationIgnored private var sources: [Source] = []
    @ObservationIgnored private var seen = Set<String>()
    @ObservationIgnored private var generation = 0
    private let library = KyroIPTVMusicLibrary.shared
    static let pageSize = 60

    init(collection: KyroMusicCollection) { self.collection = collection }

    func reload() async {
        generation &+= 1
        let current = generation
        hasLoaded = false
        await library.refresh()
        guard current == generation else { return }
        stations = []
        seen = []
        canLoadMore = true
        sources = library.activeIndexes.filter { $0.count(collection) > 0 }.flatMap { index in
            index.categories(in: collection).map { Source(providerID: index.providerID, category: $0.name, channelIDs: []) }
                + [Source(providerID: index.providerID, category: nil, channelIDs: index.channels(in: collection).map(\.id))]
        }
        isUnavailable = sources.isEmpty
        await loadMore()
        if current == generation { hasLoaded = true }
    }

    func loadMore() async {
        guard !isLoading, canLoadMore else { return }
        isLoading = true
        defer { isLoading = false }
        let current = generation
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var added = 0
        while added < 30, let index = sources.firstIndex(where: { !$0.done }) {
            var source = sources[index]
            let page: [LiveTVChannel]
            if let category = source.category {
                page = await LiveTVService.shared.channelPage(providerID: source.providerID, query: term, category: category,
                                                              offset: source.offset, limit: Self.pageSize)
                source.offset += page.count
                source.done = page.count < Self.pageSize
            } else {
                let ids = Array(source.channelIDs.dropFirst(source.offset).prefix(200))
                let channels = await LiveTVService.shared.musicChannels(providerID: source.providerID, ids: ids)
                page = term.isEmpty ? channels : channels.filter { $0.name.localizedCaseInsensitiveContains(term) }
                source.offset += ids.count
                source.done = source.offset >= source.channelIDs.count
            }
            guard current == generation else { return }
            sources[index] = source
            for channel in page where seen.insert(channel.id).inserted {
                guard library.collection(of: channel) == collection,
                      let station = library.station(for: channel, collection: collection) else { continue }
                stations.append(station)
                added += 1
            }
        }
        canLoadMore = sources.contains { !$0.done }
    }
}

/// Search across music channels of every enabled provider, optionally one collection.
@MainActor @Observable
final class KyroIPTVMusicSearch {
    private(set) var results: [KyroRadioStation] = []
    private(set) var isSearching = false
    private let library = KyroIPTVMusicLibrary.shared

    func search(_ text: String, in scope: KyroMusicCollection?) async {
        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.count >= 2 else { results = []; return }
        isSearching = true
        defer { isSearching = false }
        await library.refresh()
        var found: [KyroRadioStation] = []
        for index in library.activeIndexes {
            let page = await LiveTVService.shared.channelPage(providerID: index.providerID, query: term, limit: 120)
            guard !Task.isCancelled else { return }
            for channel in page {
                guard let collection = library.collection(of: channel), scope == nil || scope == collection,
                      let station = library.station(for: channel, collection: collection) else { continue }
                found.append(station)
            }
        }
        results = Array(found.prefix(60))
    }
}

/// Where Radio's search looks.
enum KyroRadioSearchScope: Hashable {
    case all, internetRadio, collection(KyroMusicCollection)

    var title: String {
        switch self {
        case .all: "All Sources"
        case .internetRadio: "Internet Radio"
        case .collection(let collection): collection.title
        }
    }

    var includesInternetRadio: Bool { self == .all || self == .internetRadio }
    var includesIPTV: Bool { self != .internetRadio }
    var collection: KyroMusicCollection? { if case .collection(let collection) = self { collection } else { nil } }
}

// MARK: - Artwork

/// One artwork container for every Radio source: logos of any shape are
/// fitted (never stretched or cropped) on a dark tile; a missing logo shows the
/// source's own mark.
struct KyroRadioSourceArtwork: View {
    let url: URL?
    let collection: KyroMusicCollection?
    let size: CGFloat
    var decodeSize: CGFloat? = nil
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
        ZStack {
            shape.fill(LinearGradient(colors: [KyroSignature.card, KyroSignature.night], startPoint: .top, endPoint: .bottom))
            if let url, let request = PosterImageCache.displayRequest(url: url, pointSize: CGSize(width: decodeSize ?? size, height: decodeSize ?? size),
                                                                       scale: displayScale, priority: .normal) {
                LazyImage(request: request) { state in
                    if let image = state.image {
                        image.resizable().scaledToFit().padding(size * 0.1)
                    } else {
                        fallback
                    }
                }
                .onDisappear(.cancel)
            } else {
                fallback
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.10)))
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var fallback: some View {
        VStack(spacing: size * 0.04) {
            Image(systemName: collection?.symbol ?? "radio")
                .font(.system(size: size * 0.34, weight: .semibold))
                .foregroundStyle(KyroSignature.crimson)
            if size >= 90, let collection {
                Text(collection.title).font(.system(size: size * 0.1, weight: .semibold)).foregroundStyle(KyroSignature.secondary)
                    .lineLimit(1).minimumScaleFactor(0.7).padding(.horizontal, 6)
            }
        }
    }
}

// MARK: - Discover: sources shelf

/// Internet Radio and every IPTV music collection that has channels. Absent
/// entirely without IPTV music, so Radio looks as before.
struct KyroRadioSourcesShelf: View {
    let openInternetRadio: () -> Void
    let openCollection: (KyroMusicCollection) -> Void
    private let library = KyroIPTVMusicLibrary.shared

    var body: some View {
        let collections = library.availableCollections
        if collections.isEmpty, library.isBuilding {
            // Build 140: the first classification of a large catalog takes a moment.
            HStack(spacing: 10) {
                ProgressView()
                Text("Finding music channels in your IPTV providers…").font(.footnote).foregroundStyle(KyroSignature.secondary)
            }
            .padding(.horizontal, 20)
            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        } else if !collections.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                KyroAudioShelfHeader(title: "Music Sources", caption: "Internet Radio and your IPTV providers")
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        tile(title: "Internet Radio", subtitle: "Radio Browser", symbol: "radio", action: openInternetRadio)
                        ForEach(collections) { collection in
                            let count = library.count(collection)
                            tile(title: collection.title,
                                 subtitle: "\(KyroIPTVMusicCounts.label(count)) · \(library.providerNames(collection).joined(separator: ", "))",
                                 symbol: collection.symbol) { openCollection(collection) }
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .scrollIndicators(.hidden)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
    }

    private func tile(title: String, subtitle: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            KyroAudioArtworkTile(title: title, subtitle: subtitle, size: 132) {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(LinearGradient(colors: [KyroSignature.crimsonDeep, KyroSignature.night], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay {
                        Image(systemName: symbol).font(.system(size: 44, weight: .semibold)).foregroundStyle(.white)
                    }
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(KyroSignature.border))
                    .frame(width: 132, height: 132)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
    }
}

// MARK: - Collection page

struct KyroIPTVMusicCollectionPage: View {
    let collection: KyroMusicCollection
    @Environment(\.nowPlayingShelfCoversPushedPages) private var shelfCoversPushedPages
    @State private var browser: KyroIPTVCollectionBrowser
    @FocusState private var searchFocused: Bool
    private let library = KyroIPTVMusicLibrary.shared

    init(collection: KyroMusicCollection) {
        self.collection = collection
        _browser = State(initialValue: KyroIPTVCollectionBrowser(collection: collection))
    }

    /// "312 channels · Provider A, Provider B", from the classification index.
    private var summary: String? {
        let count = library.count(collection)
        guard count > 0 else { return nil }
        return KyroIPTVMusicCounts.label(count) + " · " + library.providerNames(collection).joined(separator: ", ")
    }

    var body: some View {
        List {
            KyroAudioSearchField(hasText: !browser.query.isEmpty, clear: { browser.query = "" }) {
                TextField("Search \(collection.title)", text: $browser.query)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().focused($searchFocused).submitLabel(.search)
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            VStack(alignment: .leading, spacing: 2) {
                Text(collection.subtitle)
                if summary != nil { Text(summary ?? "").foregroundStyle(KyroSignature.secondary.opacity(0.8)) }
            }
            .font(.footnote).foregroundStyle(KyroSignature.secondary)
            .listRowBackground(Color.clear).listRowSeparator(.hidden)
            ForEach(browser.stations) { station in
                KyroRadioStationRow(station: station)
                    .contextMenu { KyroIPTVChannelActions(station: station) }
            }
            if browser.isLoading || !browser.hasLoaded {
                Group {
                    if browser.stations.isEmpty { ProgressView("Loading channels…") } else { ProgressView() }
                }
                    .frame(maxWidth: .infinity).listRowBackground(Color.clear).listRowSeparator(.hidden)
            } else if browser.isUnavailable {
                ContentUnavailableView("Source Unavailable", systemImage: "antenna.radiowaves.left.and.right.slash",
                    description: Text("Your IPTV catalog isn’t loaded, or this provider is turned off in Manage Music Sources."))
                    .listRowBackground(Color.clear)
            } else if browser.stations.isEmpty {
                ContentUnavailableView(browser.query.isEmpty ? "No Channels" : "No Matches", systemImage: collection.symbol,
                    description: Text(browser.query.isEmpty ? "None of this collection's channels are available right now."
                                                            : "Try another name."))
                    .listRowBackground(Color.clear)
            } else if browser.canLoadMore {
                Button("Load More Channels") { Task { await browser.loadMore() } }
                    .frame(maxWidth: .infinity).listRowBackground(Color.clear)
                    .onAppear { Task { await browser.loadMore() } }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .background { KyroSignatureBackdrop(finish: .dense).ignoresSafeArea() }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !shelfCoversPushedPages { KyroRadioPageNowPlayingBar() }
        }
        .navigationTitle(collection.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("kyroIPTVCollectionPage")
        .toolbar(.visible, for: .navigationBar)
        .task(id: "\(browser.query)|\(library.revision)") {
            // Debounced: a pause in typing, then one indexed query per source page.
            if !browser.query.isEmpty { try? await Task.sleep(for: .milliseconds(350)) }
            guard !Task.isCancelled else { return }
            await browser.reload()
        }
        .tint(KyroTheme.accentInk)
    }
}

/// Watch the video, or correct the channel's classification.
struct KyroIPTVChannelActions: View {
    let station: KyroRadioStation
    private let library = KyroIPTVMusicLibrary.shared

    var body: some View {
        if let source = station.iptv {
            Button("Watch in Live TV", systemImage: "tv") { Task { await library.watchInLiveTV(station) } }
            Menu("Move to Collection", systemImage: "folder") {
                ForEach(KyroMusicCollection.allCases.filter { $0 != source.collection }) { collection in
                    Button(collection.title) { library.overrideChannel(source.channelID, .collection(collection)) }
                }
            }
            Button("Not a Music Channel", systemImage: "nosign", role: .destructive) {
                library.overrideChannel(source.channelID, .excluded)
            }
            if library.preferences.channelOverrides[source.channelID] != nil {
                Button("Use Automatic Classification", systemImage: "arrow.uturn.backward") {
                    library.overrideChannel(source.channelID, nil)
                }
            }
        }
    }
}

// MARK: - Search results, favorites and history rows

struct KyroIPTVSearchResults: View {
    let text: String
    let scope: KyroRadioSearchScope
    @State private var search = KyroIPTVMusicSearch()
    private let library = KyroIPTVMusicLibrary.shared

    var body: some View {
        Group {
            if !library.availableCollections.isEmpty, scope.includesIPTV {
                Text(scope.collection.map { "\($0.title) Channels" } ?? "Music Channels")
                    .font(.title3.bold()).accessibilityAddTraits(.isHeader)
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                if search.isSearching {
                    ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
                } else if search.results.isEmpty {
                    Text("No music channels match.").font(.subheadline).foregroundStyle(KyroSignature.secondary)
                        .listRowBackground(Color.clear)
                }
                ForEach(search.results) { station in
                    KyroRadioStationRow(station: station).contextMenu { KyroIPTVChannelActions(station: station) }
                }
            }
        }
        .task(id: "\(text)|\(scope.title)|\(library.revision)") {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await search.search(text, in: scope.collection)
        }
    }
}

/// Favorite IPTV music channels, from Live TV's favorite store.
struct KyroIPTVFavoriteRows: View {
    let searchText: String
    @State private var stations: [KyroRadioStation] = []
    private let library = KyroIPTVMusicLibrary.shared

    var body: some View {
        let shown = stations.filter { searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText) }
        Group {
            if !shown.isEmpty {
                Text("Favorite Music Channels").font(.title3.bold()).accessibilityAddTraits(.isHeader)
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                ForEach(shown) { station in
                    KyroRadioStationRow(station: station).contextMenu { KyroIPTVChannelActions(station: station) }
                }
            }
        }
        .task(id: "\(LiveTVService.shared.favoriteChannelIDs.count)|\(library.revision)|\(LiveTVService.shared.channelCatalogRevision)") {
            stations = await library.favoriteStations()
        }
    }
}

/// A played IPTV music channel in Radio History.
struct KyroIPTVHistoryRow: View {
    let entry: KyroIPTVHistoryEntry
    @State private var unavailable = false
    private let player = KyroRadioPlayer.shared
    private let library = KyroIPTVMusicLibrary.shared

    var body: some View {
        HStack(spacing: 12) {
            Button {
                Task { unavailable = !(await library.play(channelID: entry.channelID)) }
            } label: {
                HStack(spacing: 12) {
                    KyroRadioSourceArtwork(url: entry.logo, collection: entry.collection, size: 52, decodeSize: 72)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.name).font(.body.weight(.semibold))
                            .foregroundStyle(player.station?.id == entry.channelID ? KyroTheme.accentInk : KyroTheme.textPrimary)
                            .lineLimit(2)
                        Text("\(entry.collection.title) · \(entry.providerName)").font(.subheadline)
                            .foregroundStyle(KyroTheme.textSecondary).lineLimit(1)
                        Text(unavailable ? "No longer available from this provider" : entry.date.formatted(.relative(presentation: .named)))
                            .font(.caption).foregroundStyle(KyroTheme.textSecondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play \(entry.name)")
            .accessibilityHint("\(entry.collection.title) from \(entry.providerName)")
            Button {
                LiveTVService.shared.toggleFavorite(LiveTVChannel(id: entry.channelID, guideID: entry.guideID, name: entry.name,
                                                                  streamURL: URL(string: "https://invalid.local")!,
                                                                  logoURL: nil, category: entry.category))
            } label: {
                Image(systemName: library.isFavorite(entry.channelID) ? "heart.fill" : "heart")
                    .font(.title3).foregroundStyle(KyroTheme.accentInk).frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(library.isFavorite(entry.channelID) ? "Remove \(entry.name) from Favorites" : "Add \(entry.name) to Favorites")
        }
        .listRowBackground(Color.clear)
    }
}

// MARK: - Now Playing additions

/// For an IPTV station: the guide's current programme, and the Live TV player
/// when the audio player can't read the stream (or to watch the video).
struct KyroIPTVNowPlayingExtras: View {
    let station: KyroRadioStation?
    let failed: Bool
    var tint: Color = KyroTheme.accentInk
    private let library = KyroIPTVMusicLibrary.shared

    var body: some View {
        if let station, let channel = library.liveChannel(for: station) {
            VStack(alignment: .leading, spacing: 8) {
                if let program = LiveTVService.shared.programPair(for: channel).current {
                    Label("On now: \(program.title)", systemImage: "list.bullet.rectangle")
                        .font(.footnote).lineLimit(2)
                }
                Button {
                    Task { await library.watchInLiveTV(station) }
                } label: {
                    Label(failed ? "Play in Live TV Instead" : "Watch Video in Live TV", systemImage: "tv")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(tint)
                .accessibilityHint("Stops Radio and opens this channel in the Live TV player")
            }
        }
    }
}

// MARK: - Settings: Manage Music Sources

struct KyroIPTVMusicSourcesSettings: View {
    @State private var confirmReset = false
    private let library = KyroIPTVMusicLibrary.shared
    private let service = LiveTVService.shared

    var body: some View {
        Form {
            Section {
                Toggle("Music Channels from IPTV", isOn: Binding(get: { library.preferences.enabled }, set: library.setEnabled))
            } footer: {
                Text("Radio shows SiriusXM, Music Choice, Stingray Music and other music channels your IPTV providers already include. Channels stay in Live TV; categories you hid in Live TV stay hidden.")
            }
            .kyroSettingsRowSurface()
            if service.providers.isEmpty {
                Section { Text("Add an IPTV provider in Live TV Settings to see its music channels here.").foregroundStyle(.secondary) }
                    .kyroSettingsRowSurface()
            } else if library.preferences.enabled {
                Section("Providers") {
                    ForEach(service.providers) { provider in
                        Toggle(isOn: Binding(get: { !library.preferences.excludedProviders.contains(provider.id) },
                                             set: { library.setProvider(provider.id, included: $0) })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(provider.name)
                                let index = library.indexes.first { $0.providerID == provider.id }
                                Text(index.map { summary($0) } ?? (library.isBuilding ? "Checking channels…" : "No indexed channel catalog yet"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .kyroSettingsRowSurface()
                ForEach(library.indexes.filter { !library.preferences.excludedProviders.contains($0.providerID) }, id: \.providerID) { index in
                    Section {
                        let music = index.categories.filter { $0.collection != nil || !$0.isAutomatic }
                        if music.isEmpty { Text("No music categories detected.").foregroundStyle(.secondary) }
                        ForEach(music, id: \.name) { category in categoryRow(category) }
                        NavigationLink("Assign Another Category") { KyroIPTVCategoryAssignment(index: index) }
                    } header: {
                        Text("\(index.providerName): Detected Categories")
                    }
                    .kyroSettingsRowSurface()
                }
                Section {
                    NavigationLink("Channel Corrections (\(library.preferences.channelOverrides.count))") { KyroIPTVChannelCorrections() }
                    Button("Reset Classification Overrides", role: .destructive) { confirmReset = true }
                        .disabled(!library.preferences.hasOverrides)
                } footer: {
                    Text("Your choices take priority over automatic detection. To include or exclude a single channel, long-press it in Radio.")
                }
                .kyroSettingsRowSurface()
            }
        }
        .scrollContentBackground(.hidden)
        .background(SettingsBackdrop())
        .navigationTitle("Music Sources")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(library.revision)|\(service.channelCatalogRevision)|\(library.preferences.enabled)") { await library.refresh() }
        .confirmationDialog("Reset all music classification overrides?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset Overrides", role: .destructive) { library.resetOverrides() }
        }
    }

    private func summary(_ index: KyroIPTVMusicIndex) -> String {
        let collections = index.availableCollections
        return collections.isEmpty ? "No music channels detected"
            : collections.map { "\($0.title) \(min(index.count($0), 9_999))" }.joined(separator: " · ")
    }

    private func categoryRow(_ category: KyroIPTVMusicIndex.Category) -> some View {
        KyroIPTVAssignmentPicker(title: category.name,
                                 detail: category.isHidden ? "Hidden in Live TV · \(category.count) channels" : "\(category.count) channels",
                                 automatic: KyroMusicClassifier.category(category.name),
                                 selection: library.preferences.categoryAssignments[category.name]) {
            library.assignCategory(category.name, $0)
        }
    }
}

/// Automatic, a collection, or Not Music.
struct KyroIPTVAssignmentPicker: View {
    let title: String
    let detail: String
    let automatic: KyroMusicCollection?
    let selection: KyroMusicAssignment?
    let select: (KyroMusicAssignment?) -> Void

    var body: some View {
        Picker(selection: Binding(get: { selection?.storageValue ?? "automatic" },
                                  set: { select($0 == "automatic" ? nil : KyroMusicAssignment(storageValue: $0)) })) {
            Text("Automatic (\(automatic?.title ?? "Not Music"))").tag("automatic")
            ForEach(KyroMusicCollection.allCases) { Text($0.title).tag($0.rawValue) }
            Text("Not Music").tag("excluded")
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(2)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Every category of a provider, searchable, for manual assignment.
private struct KyroIPTVCategoryAssignment: View {
    let index: KyroIPTVMusicIndex
    @State private var query = ""
    private let library = KyroIPTVMusicLibrary.shared

    var body: some View {
        let shown = index.categories.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }.prefix(300)
        List(Array(shown), id: \.name) { category in
            KyroIPTVAssignmentPicker(title: category.name,
                                     detail: category.isHidden ? "Hidden in Live TV · \(category.count) channels" : "\(category.count) channels",
                                     automatic: KyroMusicClassifier.category(category.name),
                                     selection: library.preferences.categoryAssignments[category.name]) {
                library.assignCategory(category.name, $0)
            }
        }
        .searchable(text: $query, prompt: "Search \(index.providerName) categories")
        .navigationTitle("Assign Category")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Channel-level decisions, with a search to include or exclude any channel.
private struct KyroIPTVChannelCorrections: View {
    @State private var query = ""
    @State private var matches: [LiveTVChannel] = []
    @State private var names: [String: String] = [:]
    private let library = KyroIPTVMusicLibrary.shared

    var body: some View {
        List {
            if !query.isEmpty {
                Section("Channels") {
                    if matches.isEmpty { Text("No channels match.").foregroundStyle(.secondary) }
                    ForEach(matches, id: \.id) { channel in
                        KyroIPTVAssignmentPicker(title: channel.name,
                                                 detail: "\(channel.category) · \(library.providerName(KyroIPTVMusicLibrary.providerID(of: channel.id) ?? UUID()))",
                                                 automatic: KyroMusicClassifier.channel(name: channel.name,
                                                                                         categoryCollection: KyroMusicClassifier.category(channel.category)),
                                                 selection: library.preferences.channelOverrides[channel.id]) {
                            library.overrideChannel(channel.id, $0)
                        }
                    }
                }
            }
            Section("Your Corrections") {
                let overrides = library.preferences.channelOverrides.sorted { (names[$0.key] ?? $0.key) < (names[$1.key] ?? $1.key) }
                if overrides.isEmpty { Text("None yet.").foregroundStyle(.secondary) }
                ForEach(overrides, id: \.key) { id, assignment in
                    LabeledContent(names[id] ?? "Unavailable channel", value: assignment.collection?.title ?? "Not Music")
                        .swipeActions { Button("Remove", role: .destructive) { library.overrideChannel(id, nil) } }
                }
            }
        }
        .searchable(text: $query, prompt: "Find a channel")
        .navigationTitle("Channel Corrections")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: query) {
            let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard term.count >= 2 else { matches = []; return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            var found: [LiveTVChannel] = []
            for provider in LiveTVService.shared.providers where !library.preferences.excludedProviders.contains(provider.id) {
                found += await LiveTVService.shared.channelPage(providerID: provider.id, query: term, limit: 40)
            }
            matches = found
        }
        .task(id: library.preferences.channelOverrides.count) {
            var resolved: [String: String] = [:]
            let byProvider = Dictionary(grouping: library.preferences.channelOverrides.keys) { KyroIPTVMusicLibrary.providerID(of: $0) }
            for (providerID, ids) in byProvider {
                guard let providerID else { continue }
                for channel in await LiveTVService.shared.musicChannels(providerID: providerID, ids: Array(ids.prefix(200))) {
                    resolved[channel.id] = channel.name
                }
            }
            names = resolved
        }
    }
}
#endif
