#if os(iOS) || KYRO_STANDALONE_TESTS
import Foundation

// Build 139: music channels from the listener's own IPTV providers, organised
// for Radio. Pure rules here, so they are host-tested; the catalog reads and
// views live in KyroIPTVMusic.swift.
//
// Classification never scans the whole catalog. It reads:
// - the provider's category list (one indexed GROUP BY), classified by name;
// - a few bounded full-text searches for brand names (SiriusXM, Music Choice,
//   Stingray, radio), classified per channel.
// Channels inside a music category are checked again, page by page, as a
// collection is browsed, so music-television channels in a music category
// stay out.

/// Where an IPTV music channel appears in Radio.
enum KyroMusicCollection: String, Codable, CaseIterable, Identifiable, Sendable {
    case siriusXM, musicChoice, stingray, otherRadio, otherMusic
    var id: String { rawValue }

    var title: String {
        switch self {
        case .siriusXM: "SiriusXM"
        case .musicChoice: "Music Choice"
        case .stingray: "Stingray Music"
        case .otherRadio: "IPTV Radio"
        case .otherMusic: "IPTV Music"
        }
    }

    var subtitle: String {
        switch self {
        case .siriusXM: "SiriusXM channels from your IPTV provider"
        case .musicChoice: "Music Choice channels from your IPTV provider"
        case .stingray: "Stingray Music audio channels"
        case .otherRadio: "Radio stations carried by your IPTV provider"
        case .otherMusic: "Other audio music channels"
        }
    }

    var symbol: String {
        switch self {
        case .siriusXM: "dot.radiowaves.up.forward"
        case .musicChoice: "music.note.list"
        case .stingray: "waveform"
        case .otherRadio: "antenna.radiowaves.left.and.right"
        case .otherMusic: "music.note"
        }
    }
}

/// A manual decision: put the category or channel in a collection, or keep it
/// out of Radio. Manual decisions beat automatic ones.
enum KyroMusicAssignment: Codable, Equatable, Hashable, Sendable {
    case collection(KyroMusicCollection)
    case excluded

    var collection: KyroMusicCollection? {
        if case .collection(let collection) = self { return collection }
        return nil
    }

    var storageValue: String {
        switch self {
        case .collection(let collection): collection.rawValue
        case .excluded: "excluded"
        }
    }

    init?(storageValue: String) {
        if storageValue == "excluded" { self = .excluded; return }
        guard let collection = KyroMusicCollection(rawValue: storageValue) else { return nil }
        self = .collection(collection)
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let value = Self(storageValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown assignment"))
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storageValue)
    }
}

enum KyroMusicClassifier {
    // MARK: Normalisation

    /// Lowercased, accent-free words; "&" reads as "and".
    static func tokens(_ text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "&", with: " and ")
        return folded.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// Words run together: "Sirius XM" and "SiriusXM" both read "siriusxm".
    static func compact(_ text: String) -> String { tokens(text).joined() }

    // MARK: Brands

    /// Stingray's video services (concerts, karaoke, scenery, music video).
    /// Their names contain the brand but they are television, not audio.
    static let stingrayVideo: [String] = [
        "stingrayqello", "stingraykaraoke", "stingraynaturescape", "stingrayclassica", "stingrayiconcerts",
        "stingraydjazz", "stingrayhits", "stingrayjuicebox", "stingrayloud", "stingrayretro", "stingrayvibe",
        "stingraycmusic", "stingraylitetv", "stingrayholidayscapes", "stingrayrock", "stingrayspotlight",
    ]

    /// The music brand a name belongs to, if any. Stingray video services
    /// return nil (they are music television).
    static func brand(_ text: String) -> KyroMusicCollection? {
        let words = Set(tokens(text))
        let joined = compact(text)
        if joined.contains("siriusxm") || words.contains("sirius") || words.contains("sxm") { return .siriusXM }
        if joined.contains("musicchoice") { return .musicChoice }
        if words.contains("stingray") {
            if stingrayVideo.contains(where: { joined.contains($0) }) { return nil }
            return .stingray
        }
        return nil
    }

    static func isStingrayVideo(_ text: String) -> Bool {
        let joined = compact(text)
        return joined.contains("stingray") && stingrayVideo.contains { joined.contains($0) }
    }

    // MARK: Television and radio signals

    static let musicTelevision: Set<String> = [
        "mtv", "vh1", "cmt", "fuse", "revolt", "trace", "mezzo", "qello", "karaoke", "concert", "concerts",
        "video", "videos", "clubland", "kerrang", "4music", "musictv", "tvmusic", "jukebox",
    ]

    static let television: Set<String> = ["tv", "tele", "television", "televizija", "televisao", "rtv", "telé", "telefe", "teve"]

    /// Phrases where "radio" names a television broadcaster.
    static let radioTelevisionPhrases: [String] = ["radiocanada", "radiotelevision", "radiotv", "radiotele", "radiotelevisao"]

    /// A music-television channel or category (music videos, concerts, karaoke).
    static func isMusicTelevision(_ text: String) -> Bool {
        let words = tokens(text)
        let joined = words.joined()
        if words.contains(where: musicTelevision.contains) || joined.contains("musictelevision") || joined.contains("musictv") {
            return true
        }
        // "BET Jams", "BET Soul": music video channels.
        if words.contains("bet"), words.contains(where: { ["jams", "soul", "hits", "her"].contains($0) }) { return true }
        if isStingrayVideo(text) { return true }
        // "Music" with a TV marker ("Music TV", "Hits TV").
        return words.contains(where: television.contains) && words.contains(where: { ["music", "hits", "musica", "musique"].contains($0) })
    }

    static func isTelevision(_ text: String) -> Bool {
        let words = tokens(text)
        let joined = words.joined()
        return words.contains(where: television.contains) || radioTelevisionPhrases.contains { joined.contains($0) }
    }

    /// A radio name: "Radio", "Radios", an FM or AM frequency, "101.1 FM".
    static func isRadio(_ text: String) -> Bool {
        let words = tokens(text)
        if words.contains("radio") || words.contains("radios") || words.contains("fm") { return true }
        if words.contains(where: { $0.count > 2 && $0.hasSuffix("fm") && $0.dropLast(2).allSatisfy(\.isNumber) }) { return true }
        // "AM" only beside a frequency ("WGN 720 AM").
        if words.contains("am"), words.contains(where: { $0.count >= 3 && $0.allSatisfy(\.isNumber) }) { return true }
        return false
    }

    static func isAudioMusic(_ text: String) -> Bool {
        let words = Set(tokens(text))
        let music = !words.isDisjoint(with: ["music", "musica", "musique", "musik"])
        let audio = !words.isDisjoint(with: ["audio", "audios", "radio", "radios", "streams", "stream", "station", "stations"])
        return music && audio
    }

    // MARK: Automatic classification

    /// A whole category's collection, from its name only.
    static func category(_ name: String) -> KyroMusicCollection? {
        if let brand = brand(name) { return brand }
        if isStingrayVideo(name) || isMusicTelevision(name) { return nil }
        if isRadio(name) && !isTelevision(name) { return .otherRadio }
        if isAudioMusic(name) && !isTelevision(name) { return .otherMusic }
        return nil
    }

    /// One channel's collection. A brand in the channel's own name wins; music
    /// television is never included; otherwise the channel follows its
    /// category, or is radio by its own name.
    static func channel(name: String, categoryCollection: KyroMusicCollection?) -> KyroMusicCollection? {
        if isStingrayVideo(name) { return nil }
        if let brand = brand(name) { return brand }
        if isMusicTelevision(name) { return nil }
        if let categoryCollection { return categoryCollection }
        if isRadio(name) && !isTelevision(name) { return .otherRadio }
        return nil
    }

    /// Manual decisions first (channel, then category), then the rules.
    static func resolve(channelID: String, name: String, category: String,
                        channelOverrides: [String: KyroMusicAssignment],
                        categoryCollection: (String) -> KyroMusicCollection?) -> KyroMusicCollection? {
        if let manual = channelOverrides[channelID] { return manual.collection }
        return channel(name: name, categoryCollection: categoryCollection(category))
    }

    /// Full-text terms searched once per catalog for channel-level brands.
    static let brandSearchTerms = ["SiriusXM", "Sirius", "SXM", "Music Choice", "Stingray", "Radio"]
}

// MARK: - Index

/// What one provider's catalog contributes to Radio, for one catalog
/// generation and one set of manual decisions. Holds names and channel IDs
/// only: never stream addresses.
struct KyroIPTVMusicIndex: Codable, Equatable, Sendable {
    struct Category: Codable, Equatable, Hashable, Sendable {
        let name: String
        let count: Int
        /// The category's collection, or nil when it isn't music.
        let collection: KyroMusicCollection?
        let isAutomatic: Bool
        /// Hidden in Live TV: never shown in Radio.
        let isHidden: Bool
    }

    struct Channel: Codable, Equatable, Hashable, Sendable {
        let id: String
        let name: String
        let category: String
        let collection: KyroMusicCollection
    }

    let providerID: UUID
    let providerName: String
    let generation: String
    let signature: String
    /// Every category the provider has, classified (so Settings can show them).
    let categories: [Category]
    /// Music channels outside music categories, found by name.
    let channels: [Channel]

    func categoryCollection(_ name: String) -> KyroMusicCollection? {
        categories.first { $0.name == name && !$0.isHidden }?.collection
    }

    func categories(in collection: KyroMusicCollection) -> [Category] {
        categories.filter { $0.collection == collection && !$0.isHidden && $0.count > 0 }
    }

    func channels(in collection: KyroMusicCollection) -> [Channel] {
        channels.filter { $0.collection == collection }
    }

    /// Channels the collection can show (an estimate before per-channel checks).
    func count(_ collection: KyroMusicCollection) -> Int {
        categories(in: collection).reduce(0) { $0 + $1.count } + channels(in: collection).count
    }

    var availableCollections: [KyroMusicCollection] {
        KyroMusicCollection.allCases.filter { count($0) > 0 }
    }
}

/// The catalog facts classification reads.
struct KyroIPTVCatalogSnapshot: Sendable {
    struct Match: Sendable, Hashable {
        let id: String
        let name: String
        let category: String
    }
    let providerID: UUID
    let providerName: String
    let generation: String
    let categories: [(name: String, count: Int)]
    let matches: [Match]
}

enum KyroIPTVMusicIndexer {
    /// Inputs that require a rebuild: catalog generation, manual decisions and hidden categories.
    static func signature(generation: String, categoryAssignments: [String: KyroMusicAssignment],
                          channelOverrides: [String: KyroMusicAssignment], hidden: Set<String>) -> String {
        let categories = categoryAssignments.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.storageValue)" }
        let channels = channelOverrides.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.storageValue)" }
        return ([generation] + categories + ["|"] + channels + ["|"] + hidden.sorted()).joined(separator: "\u{1F}")
    }

    static func build(_ snapshot: KyroIPTVCatalogSnapshot, categoryAssignments: [String: KyroMusicAssignment],
                      channelOverrides: [String: KyroMusicAssignment], hidden: Set<String>) -> KyroIPTVMusicIndex {
        var categories: [KyroIPTVMusicIndex.Category] = []
        var categoryMap: [String: KyroMusicCollection] = [:]
        for (name, count) in snapshot.categories {
            let manual = categoryAssignments[name]
            let collection = manual.map(\.collection) ?? KyroMusicClassifier.category(name)
            let hiddenCategory = hidden.contains(name)
            categories.append(.init(name: name, count: count, collection: collection, isAutomatic: manual == nil, isHidden: hiddenCategory))
            if let collection, !hiddenCategory { categoryMap[name] = collection }
        }
        var seen = Set<String>()
        var channels: [KyroIPTVMusicIndex.Channel] = []
        // Brand and radio matches outside music categories, plus channels the listener added by hand.
        for match in snapshot.matches where seen.insert(match.id).inserted {
            guard !hidden.contains(match.category), categoryMap[match.category] == nil else { continue }
            let collection = KyroMusicClassifier.resolve(channelID: match.id, name: match.name, category: match.category,
                                                         channelOverrides: channelOverrides,
                                                         categoryCollection: { categoryMap[$0] })
            if let collection {
                channels.append(.init(id: match.id, name: match.name, category: match.category, collection: collection))
            }
        }
        return KyroIPTVMusicIndex(providerID: snapshot.providerID, providerName: snapshot.providerName,
                                  generation: snapshot.generation,
                                  signature: signature(generation: snapshot.generation, categoryAssignments: categoryAssignments,
                                                       channelOverrides: channelOverrides, hidden: hidden),
                                  categories: categories, channels: channels)
    }
}

// MARK: - Preferences

/// Radio's IPTV music settings. Category assignments are by category name and
/// apply to every provider with that category; channel decisions and provider
/// choices are by provider-scoped ID and never leave the device.
struct KyroIPTVMusicPreferences: Codable, Equatable, Sendable {
    var enabled = true
    var excludedProviders: Set<UUID> = []
    var categoryAssignments: [String: KyroMusicAssignment] = [:]
    var channelOverrides: [String: KyroMusicAssignment] = [:]

    static let key = "kyrox.radio.iptvMusic.v1"
    static let maxCategoryAssignments = 200
    static let maxChannelOverrides = 500

    static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: key), data.count < 1_000_000,
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }

    var hasOverrides: Bool { !categoryAssignments.isEmpty || !channelOverrides.isEmpty }
}

// MARK: - Playback route

/// Which addresses Radio tries for an IPTV channel, in order.
///
/// Build 140: the channel's own address comes first, exactly as Live TV plays
/// it, read by AetherEngine (`KyroIPTVAudioLoadPlan`). Build 139 put the
/// Xtream `.m3u8` variant first, even for accounts that never advertised HLS,
/// because AVPlayer can't read raw MPEG-TS; that swapped in the provider's
/// on-demand HLS segmenter for the stream other apps play. The HLS variant is
/// now only a startup fallback, and only when the account lists `m3u8`.
enum KyroIPTVAudioRoute {
    static func candidates(for streamURL: URL, isXtream: Bool, allowedFormats: [String]) -> [URL] {
        guard let scheme = streamURL.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return [] }
        let ext = streamURL.pathExtension.lowercased()
        if isXtream, ext == "ts", allowedFormats.contains("m3u8"),
           let hls = replacingExtension(of: streamURL, with: "m3u8") {
            return [streamURL, hls]
        }
        return [streamURL]
    }

    /// True when the audio player has a supported format to try first.
    static func prefersAudioPlayer(_ url: URL) -> Bool {
        ["m3u8", "m3u", "aac", "mp3", "m4a", "pls", ""].contains(url.pathExtension.lowercased())
    }

    private static func replacingExtension(of url: URL, with ext: String) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let path = components.percentEncodedPath
        guard let dot = path.range(of: ".", options: .backwards) else { return nil }
        components.percentEncodedPath = String(path[..<dot.lowerBound]) + "." + ext
        return components.url
    }
}

/// Build 140: channel counts as Radio shows them. The index counts a
/// category's channels up to a bound, so large counts read "1,000+".
enum KyroIPTVMusicCounts {
    static func label(_ count: Int) -> String {
        switch count {
        case ..<1: "No channels"
        case 1: "1 channel"
        case 1_000...: "1,000+ channels"
        default: "\(count) channels"
        }
    }
}

/// Build 140: how `KyroIPTVAudioEngine` loads one IPTV address. Kept free of
/// AetherEngine types so the host checks can verify it.
struct KyroIPTVAudioLoadPlan: Equatable, Sendable {
    enum Route: String, Sendable { case transportStream = "ts", hls }

    let route: Route
    /// Always live: no seeking, and a dropped connection is reconnected
    /// rather than treated as the end of the stream.
    let isLive = true
    /// Audio only: the video in a music channel is never decoded.
    let audioOnly = true
    /// FFmpeg's audio host for every route. It reads raw MPEG-TS (AVPlayer
    /// can't), decodes AAC, MP2, AC-3 and E-AC-3 at the source's own rate, and
    /// has no Now Playing session that would compete with Radio's.
    let softwareDecode = true

    init(url: URL) {
        route = url.pathExtension.lowercased() == "m3u8" ? .hls : .transportStream
    }
}

// MARK: - Audio shelf limits

/// Build 139: how many items each audio shelf on Home draws. Bounded choices,
/// defaults equal to Build 138's fixed limits.
enum KyroAudioShelfLimit {
    case favoriteRadio, recentRadio, continueListening, latestEpisodes, favoritePodcasts

    static let all: [Self] = [.favoriteRadio, .recentRadio, .continueListening, .latestEpisodes, .favoritePodcasts]
    static let choices = [5, 10, 12, 15, 20, 30]

    var key: String {
        switch self {
        case .favoriteRadio: "favoriteRadio"
        case .recentRadio: "recentRadio"
        case .continueListening: "continueListening"
        case .latestEpisodes: "latestEpisodes"
        case .favoritePodcasts: "favoritePodcasts"
        }
    }

    var title: String {
        switch self {
        case .favoriteRadio: "Favorite Radio Stations"
        case .recentRadio: "Recently Played Radio"
        case .continueListening: "Continue Listening"
        case .latestEpisodes: "Latest Podcast Episodes"
        case .favoritePodcasts: "Favorite Podcasts"
        }
    }

    /// Build 138: radio shelves drew 20, podcast shelves 12.
    var defaultValue: Int {
        switch self {
        case .favoriteRadio, .recentRadio: 20
        case .continueListening, .latestEpisodes, .favoritePodcasts: 12
        }
    }

    static let defaultsKey = "kyrox.home.audioShelfLimits.v1"

    static func value(_ limit: Self, in defaults: UserDefaults = .standard) -> Int {
        let stored = (defaults.dictionary(forKey: defaultsKey) as? [String: Int])?[limit.key]
        return stored.flatMap { choices.contains($0) ? $0 : nil } ?? limit.defaultValue
    }

    static func set(_ value: Int, for limit: Self, in defaults: UserDefaults = .standard) {
        guard choices.contains(value) else { return }
        var stored = (defaults.dictionary(forKey: defaultsKey) as? [String: Int]) ?? [:]
        stored[limit.key] = value == limit.defaultValue ? nil : value
        defaults.set(stored, forKey: defaultsKey)
    }
}
#endif
