#if KYRO_STANDALONE_TESTS
import Foundation

// Build 139 host checks: IPTV music classification (brands, radio, audio music,
// false positives), manual overrides, hidden categories, multiple providers,
// large-catalog bounds, the audio playback route, Radio's favorite/history
// routing for IPTV stations, Settings Backup, audio shelf limits and source
// contracts. Synthetic fixtures only; no provider or credential is used.

@MainActor
private final class FakeExternal: KyroRadioExternalStations {
    var favorites = Set<String>()
    var played: [String] = []
    func isFavorite(_ id: String) -> Bool { favorites.contains(id) }
    func toggleFavorite(_ station: KyroRadioStation) {
        if !favorites.insert(station.id).inserted { favorites.remove(station.id) }
    }
    func recordPlay(_ station: KyroRadioStation) { played.append(station.id) }
}

@main @MainActor
enum KyroBuild139HostChecks {
    static var count = 0
    static func check(_ condition: Bool, _ title: String) {
        precondition(condition, title)
        count += 1
    }

    static func main() throws {
        brandsAndCategories()
        falsePositives()
        channelsAndOverrides()
        indexing()
        audioRoute()
        try stationsAndLibrary()
        try backupAndLimits()
        try sourceContracts()
        print("Build 139: \(count) music classification, routing, backup and source checks passed.")
    }

    typealias C = KyroMusicClassifier

    // MARK: Classification

    static func brandsAndCategories() {
        for name in ["SiriusXM", "Sirius XM", "SIRIUS XM | Hits 1", "SXM: The Highway", "sirius-xm octane", "Sirius 1st Wave", "SiriusXM NFL Radio"] {
            check(C.brand(name) == .siriusXM, "SiriusXM variant: \(name)")
        }
        for name in ["Music Choice", "MUSIC CHOICE: Hip-Hop and R&B", "MusicChoice Pop Hits"] {
            check(C.brand(name) == .musicChoice, "Music Choice variant: \(name)")
        }
        check(C.brand("Stingray Music: Adult Alternative") == .stingray, "Stingray Music audio")
        check(C.brand("Stingray") == .stingray, "Stingray brand")
        check(C.category("US | SiriusXM") == .siriusXM && C.category("Music Choice") == .musicChoice
              && C.category("Stingray Music") == .stingray, "brand categories")
        for name in ["Radio", "UK | Radio Stations", "Radios FR", "FM Radio", "Radio: Talk", "Local AM/FM"] {
            check(C.category(name) == .otherRadio, "radio category: \(name)")
        }
        for name in ["Music | Audio", "Audio Music Channels", "Musique Audio", "Music Radio Streams"] {
            check(C.category(name) != nil, "audio music category: \(name)")
        }
        check(C.category("Music | Audio") == .otherMusic, "audio music is IPTV Music")
        check(C.isRadio("WGN 720 AM") && C.isRadio("Z100 100.3 FM") && C.isRadio("KIIS 1027FM"), "frequencies are radio")
    }

    static func falsePositives() {
        // Music television and video services are never audio channels.
        for name in ["MTV", "MTV Hits", "VH1 Classic", "CMT Music", "Music Videos", "BET Jams", "Clubland TV", "Music TV", "Fuse",
                     "Revolt", "Trace Urban", "Mezzo Live", "Stingray Qello", "Stingray Karaoke", "Stingray Naturescape",
                     "Stingray Hits!", "Stingray iConcerts", "Kerrang!", "4Music", "Hits TV", "Concerts HD"] {
            check(C.category(name) == nil && C.channel(name: name, categoryCollection: .otherMusic) == nil,
                  "music television stays out: \(name)")
        }
        // "Music" or "Classic" alone, television, sports and broadcasters named Radio.
        for name in ["Music", "Classic Movies", "TCM Classic", "Classic Rock Documentaries", "Sports", "ESPN", "Music City Sports",
                     "Entertainment", "News", "ICI Radio-Canada Télé", "Radio Canada", "Radio Televizija Srbije", "RTV Pink",
                     "Radio TV Lebanon", "Kids", "Music & Movies"] {
            check(C.category(name) == nil, "not a music category: \(name)")
        }
        check(C.channel(name: "ESPN 2", categoryCollection: nil) == nil && C.channel(name: "Fox Sports 1", categoryCollection: nil) == nil,
              "sports television is not radio")
        check(C.channel(name: "ESPN Radio", categoryCollection: nil) == .otherRadio, "sports radio is radio")
        check(C.channel(name: "ICI Radio-Canada Télé Montréal", categoryCollection: nil) == nil, "a TV broadcaster named Radio is not radio")
    }

    static func channelsAndOverrides() {
        check(C.channel(name: "Hits 1", categoryCollection: .siriusXM) == .siriusXM, "a channel follows its category")
        check(C.channel(name: "SiriusXM Octane", categoryCollection: nil) == .siriusXM, "a brand in an ordinary category")
        check(C.channel(name: "MTV Live", categoryCollection: .siriusXM) == nil, "music TV inside a music category stays out")
        check(C.channel(name: "Stingray Music: Jazz", categoryCollection: .otherMusic) == .stingray, "a brand beats the category")

        let overrides: [String: KyroMusicAssignment] = ["p:1": .excluded, "p:2": .collection(.otherMusic)]
        check(C.resolve(channelID: "p:1", name: "SiriusXM Hits 1", category: "SiriusXM", channelOverrides: overrides,
                        categoryCollection: { _ in .siriusXM }) == nil, "a manual exclusion beats the brand")
        check(C.resolve(channelID: "p:2", name: "Movie Channel", category: "Movies", channelOverrides: overrides,
                        categoryCollection: { _ in nil }) == .otherMusic, "a manual inclusion beats the rules")
        check(C.resolve(channelID: "p:3", name: "Chill", category: "Lounge", channelOverrides: overrides,
                        categoryCollection: { $0 == "Lounge" ? .otherMusic : nil }) == .otherMusic, "a category assignment applies")
        check(KyroMusicAssignment(storageValue: "excluded") == .excluded && KyroMusicAssignment(storageValue: "siriusXM") == .collection(.siriusXM)
              && KyroMusicAssignment(storageValue: "nonsense") == nil, "assignment storage")
    }

    // MARK: Index

    static func snapshot(_ provider: UUID, _ name: String, categories: [(String, Int)], matches: [(String, String, String)]) -> KyroIPTVCatalogSnapshot {
        KyroIPTVCatalogSnapshot(providerID: provider, providerName: name, generation: "g1",
                                categories: categories.map { (name: $0.0, count: $0.1) },
                                matches: matches.map { .init(id: $0.0, name: $0.1, category: $0.2) })
    }

    static func indexing() {
        let a = UUID(), b = UUID()
        let first = snapshot(a, "Provider A", categories: [("SiriusXM", 120), ("Music Choice", 40), ("Music Videos", 30),
                                                           ("Radio", 25), ("Hidden Radio", 10), ("Entertainment", 900)],
                             matches: [("\(a):1", "SiriusXM Hits 1", "SiriusXM"), ("\(a):2", "SiriusXM Octane", "Entertainment"),
                                       ("\(a):3", "Stingray Qello", "Entertainment"), ("\(a):4", "BBC Radio 2", "Entertainment"),
                                       ("\(a):5", "Radio Canada", "Entertainment"), ("\(a):6", "SXM Jazz", "Hidden Radio"),
                                       ("\(a):2", "SiriusXM Octane", "Entertainment")])
        let index = KyroIPTVMusicIndexer.build(first, categoryAssignments: ["Entertainment": .excluded],
                                               channelOverrides: ["\(a):4": .excluded], hidden: ["Hidden Radio"])
        check(index.categoryCollection("SiriusXM") == .siriusXM && index.categoryCollection("Radio") == .otherRadio
              && index.categoryCollection("Music Videos") == nil, "categories classified")
        check(index.categoryCollection("Hidden Radio") == nil && index.categories.first { $0.name == "Hidden Radio" }?.isHidden == true,
              "a category hidden in Live TV stays hidden in Radio")
        check(index.channels.map(\.id) == ["\(a):2"], "channel matches: brand outside music categories only, once; hidden, video, TV-named and excluded channels left out")
        check(index.count(.siriusXM) == 121 && index.count(.musicChoice) == 40 && index.count(.otherRadio) == 25,
              "collection counts from category counts")
        check(index.availableCollections == [.siriusXM, .musicChoice, .otherRadio], "empty collections aren't offered")
        check(!index.categories.first { $0.name == "Entertainment" }!.isAutomatic, "manual category decision recorded")

        // Two providers with the same channel name stay distinct.
        let second = snapshot(b, "Provider B", categories: [("Entertainment", 10)], matches: [("\(b):1", "SiriusXM Hits 1", "Entertainment")])
        let other = KyroIPTVMusicIndexer.build(second, categoryAssignments: [:], channelOverrides: [:], hidden: [])
        check(other.channels.map(\.id) == ["\(b):1"] && other.providerID == b && index.providerID == a,
              "same name on two providers: two channels, each with its provider identity")

        // Signature changes with the catalog generation, a decision or hidden categories.
        let base = KyroIPTVMusicIndexer.signature(generation: "g1", categoryAssignments: [:], channelOverrides: [:], hidden: [])
        check(base != KyroIPTVMusicIndexer.signature(generation: "g2", categoryAssignments: [:], channelOverrides: [:], hidden: [])
              && base != KyroIPTVMusicIndexer.signature(generation: "g1", categoryAssignments: ["x": .excluded], channelOverrides: [:], hidden: [])
              && base != KyroIPTVMusicIndexer.signature(generation: "g1", categoryAssignments: [:], channelOverrides: [:], hidden: ["x"]),
              "rebuild triggers: catalog, decisions, hidden categories")

        // A 100,000-channel provider: classification reads categories plus bounded searches, never every channel.
        let categories = (0..<2_000).map { ("Category \($0)", 50) } + [("SiriusXM", 300), ("Radio", 200)]
        let bounded = KyroMusicClassifier.brandSearchTerms.count * 200 + 200
        let matches = (0..<bounded).map { ("\(a):m\($0)", $0.isMultiple(of: 2) ? "SiriusXM \($0)" : "Channel \($0)", "Category \($0 % 2_000)") }
        let large = snapshot(a, "Large", categories: categories, matches: matches)
        let start = Date()
        let big = KyroIPTVMusicIndexer.build(large, categoryAssignments: [:], channelOverrides: [:], hidden: [])
        let elapsed = Date().timeIntervalSince(start)
        check(big.categories.count == 2_002 && big.count(.siriusXM) == 300 + bounded / 2, "large catalog classified from bounded inputs")
        check(elapsed < 0.5, String(format: "large catalog classification took %.0f ms on the host", elapsed * 1000))
        print(String(format: "Host: 100,000-channel provider (2,002 categories, %d search matches) classified in %.1f ms", bounded, elapsed * 1000))
    }

    // MARK: Playback route

    static func audioRoute() {
        let ts = URL(string: "http://provider.example/live/u/p/1234.ts")!
        check(KyroIPTVAudioRoute.candidates(for: ts, isXtream: true, allowedFormats: ["m3u8", "ts"]).map(\.absoluteString)
              == ["http://provider.example/live/u/p/1234.m3u8", ts.absoluteString], "Xtream TS: HLS first, original second")
        check(KyroIPTVAudioRoute.candidates(for: ts, isXtream: true, allowedFormats: []).count == 2, "Xtream without advertised formats: HLS tried")
        check(KyroIPTVAudioRoute.candidates(for: ts, isXtream: true, allowedFormats: ["ts"]) == [ts], "TS-only account: original only (Live TV fallback)")
        let hls = URL(string: "https://cdn.example/sxm/hits1.m3u8")!
        check(KyroIPTVAudioRoute.candidates(for: hls, isXtream: false, allowedFormats: []) == [hls], "M3U playlist HLS as is")
        check(KyroIPTVAudioRoute.candidates(for: URL(string: "rtmp://x.example/a")!, isXtream: false, allowedFormats: []).isEmpty,
              "non-web streams refused")
    }

    // MARK: Stations, favorites and history

    static func stationsAndLibrary() throws {
        let provider = UUID()
        var station = KyroRadioStation(id: "\(provider.uuidString):42", name: "SiriusXM Hits 1",
                                       streamURL: URL(string: "http://provider.example/live/u/p/42.ts"),
                                       resolvedURL: URL(string: "http://provider.example/live/u/p/42.m3u8"))
        station.iptv = KyroIPTVStationSource(providerID: provider, providerName: "Provider", channelID: station.id,
                                             collection: .siriusXM, category: "SiriusXM", guideID: nil)
        check(station.playbackCandidates.map(\.pathExtension) == ["m3u8", "ts"], "IPTV keeps the route's order (HLS, then original)")
        check(station.location == "SiriusXM · Provider", "IPTV stations show their source")
        let old = #"{"id":"0b1a0a5e-2b3c-4d5e-8f90-123456789abc","name":"Jazz","tags":[],"country":"","countryCode":"","state":"","language":"","codec":"","bitrate":0,"isHLS":false,"lastCheckOK":true}"#
        let decoded = try JSONDecoder().decode(KyroRadioStation.self, from: Data(old.utf8))
        check(decoded.iptv == nil && decoded.name == "Jazz", "stations saved by earlier builds decode unchanged")

        let suite = "kyro.build139.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = KyroRadioLibrary(defaults: defaults)
        let external = FakeExternal()
        library.external = external
        library.toggleFavorite(station)
        check(library.isFavorite(station.id) && library.favorites.isEmpty, "an IPTV favorite goes to the shared (Live TV) store, not Radio's list")
        library.recordPlay(station)
        check(library.history.isEmpty && external.played == [station.id], "IPTV history goes to the reference store")
        library.setFavorite(station, false)
        check(!library.isFavorite(station.id), "removing an IPTV favorite")
        let radio = KyroRadioStation(id: "0b1a0a5e-2b3c-4d5e-8f90-123456789abc", name: "Jazz", streamURL: URL(string: "https://j.example/live"))
        library.toggleFavorite(radio)
        library.recordPlay(radio)
        check(library.isFavorite(radio.id) && library.favorites.count == 1 && library.history.count == 1, "Radio Browser stations unchanged")
        let stored = String(decoding: defaults.data(forKey: KyroRadioLibrary.historyKey) ?? Data(), as: UTF8.self)
            + String(decoding: defaults.data(forKey: KyroRadioLibrary.favoritesKey) ?? Data(), as: UTF8.self)
        check(!stored.contains("provider.example"), "no IPTV stream address is written to Radio's storage")
    }

    // MARK: Backup and shelf limits

    static func backupAndLimits() throws {
        let suite = "kyro.build139.backup.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var prefs = KyroIPTVMusicPreferences()
        prefs.categoryAssignments = ["Lounge": .collection(.otherMusic), "Music Videos": .excluded, "https://evil": .excluded]
        prefs.channelOverrides = ["\(UUID().uuidString):9": .excluded]
        prefs.excludedProviders = [UUID()]
        prefs.save(to: defaults)
        check(KyroIPTVMusicPreferences.load(from: defaults) == prefs, "music source preferences persist")

        let settings = KyroRadioBackupSettings.make(library: KyroRadioLibrary(defaults: defaults), defaults: defaults,
                                                    appearance: KyroRadioPlayerAppearance(defaults: defaults))
        check(settings.map(\.id) == ["radio.favorites", "radio.preferences", "radio.homeShelves", "radio.playerTheme",
                                     "radio.musicSources", "radio.homeShelfLimits"], "Radio backup entries, earlier ones unchanged")
        let sources = settings.first { $0.id == "radio.musicSources" }!
        let value = sources.read()!
        check(!SettingsBackupSafety.isSuspiciousValue(value), "music sources back up as plain values")
        let restored = KyroRadioBackupSettings.musicSources(value)!
        check(restored.enabled && restored.categories == ["Lounge": .collection(.otherMusic), "Music Videos": .excluded],
              "category decisions back up; link-like names are dropped")
        let text = "\(value)"
        check(!text.contains(prefs.channelOverrides.keys.first!) && !text.contains(prefs.excludedProviders.first!.uuidString),
              "provider-scoped channel and provider choices stay on the device")
        // Restore onto a fresh device keeps its device-only choices.
        let other = UserDefaults(suiteName: suite + ".other")!
        defer { other.removePersistentDomain(forName: suite + ".other") }
        var local = KyroIPTVMusicPreferences(); local.channelOverrides = ["x:1": .excluded]; local.save(to: other)
        let otherSettings = KyroRadioBackupSettings.make(library: KyroRadioLibrary(defaults: other), defaults: other,
                                                         appearance: KyroRadioPlayerAppearance(defaults: other))
        try otherSettings.first { $0.id == "radio.musicSources" }!.write(value)
        let merged = KyroIPTVMusicPreferences.load(from: other)
        check(merged.categoryAssignments.count == 2 && merged.channelOverrides == ["x:1": .excluded], "restore keeps device-only corrections")
        check(!sources.validate(.record(["enabled": .bool(true)])), "malformed music sources rejected")

        // Shelf limits.
        check(KyroAudioShelfLimit.all.map { KyroAudioShelfLimit.value($0, in: defaults) } == [20, 20, 12, 12, 12], "defaults equal Build 138")
        KyroAudioShelfLimit.set(5, for: .continueListening, in: defaults)
        KyroAudioShelfLimit.set(999, for: .latestEpisodes, in: defaults)
        check(KyroAudioShelfLimit.value(.continueListening, in: defaults) == 5 && KyroAudioShelfLimit.value(.latestEpisodes, in: defaults) == 12,
              "bounded choices only")
        defaults.set(["favoriteRadio": 7000], forKey: KyroAudioShelfLimit.defaultsKey)
        check(KyroAudioShelfLimit.value(.favoriteRadio, in: defaults) == 20, "an out-of-range stored value falls back to the default")
        let limits = settings.first { $0.id == "radio.homeShelfLimits" }!
        let limitValue = limits.read()!
        check(limits.validate(limitValue) && !limits.validate(.record(["favoriteRadio": .int(7)])), "shelf limits validate")
        check(KyroAudioShelfLimit.choices.max() == 30, "never unlimited")
    }

    // MARK: Source contracts

    static func source(_ path: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("iosApp/iosApp/" + path), encoding: .utf8)
    }

    static func sourceContracts() throws {
        let music = try source("Kyro/Radio/KyroIPTVMusic.swift")
        let service = try source("LiveTV/LiveTVService.swift")
        let player = try source("Kyro/Radio/KyroRadioPlayer.swift")
        let views = try source("Kyro/Radio/KyroRadioViews.swift")
        let rail = try source("Kyro/Podcasts/KyroHomePodcastRail.swift")
        let theme = try source("KyroTheme/KyroTheme.swift")

        let extensionCode = service.components(separatedBy: "// MARK: - Build 139: Radio music sources").last ?? ""
        check(extensionCode.contains("store.categories(providerID:") && extensionCode.contains("query: term, limit: 200")
              && extensionCode.contains("limit: 200)") && !extensionCode.contains("offlineCatalog"),
              "catalog reads: one category query and bounded searches; no full catalog load")
        check(!extensionCode.contains("stage(") && !extensionCode.contains("promote(") && !extensionCode.contains("setFavorite("),
              "Radio never writes the Live TV catalog")
        check(music.contains("channelPage(providerID: source.providerID, query: term, category: category,")
              && music.contains("limit: Self.pageSize"), "collections page through the index")
        check(music.contains("guard key != builtKey"), "classification is rebuilt only when inputs change")
        check(music.contains("LiveTVCategoryPreferences.load(providerID: $0.id).hidden"), "hidden Live TV categories respected")
        check(music.contains("service.favoriteChannelIDs.contains(id)") && music.contains("service.toggleFavorite(channel)"),
              "IPTV favorites use Live TV's favorite store")
        check(!music.contains("streamURL: URL") || music.contains("struct KyroIPTVHistoryEntry"), "history entries hold references")
        let historyType = music.components(separatedBy: "struct KyroIPTVHistoryEntry").last?.components(separatedBy: "static let key").first ?? ""
        check(!historyType.contains("stream"), "history stores no stream address")
        check(music.contains("KyroRadioPlayer.shared.stop()\n        service.choose(channel, from: .shell)"),
              "Live TV fallback stops Radio first: one session")
        check(player.contains("guard station.iptv == nil else { return }"), "IPTV plays are never reported to Radio Browser")
        check(player.contains("KyroPlaybackExclusivity.shared.register(self, source: .radio)"), "Radio exclusivity unchanged")
        check(views.contains("case .iptv(let entry):") && views.contains("KyroIPTVFavoriteRows(searchText: searchText)"),
              "Library and History show both sources")
        check(views.contains("KyroRadioSourcesShelf(") && views.contains("KyroIPTVSearchResults(text: searchText, scope: scope)"),
              "Discover sources and unified search")
        check(music.contains("if !collections.isEmpty {"), "no empty IPTV collections")
        check(rail.contains("KyroHomeListeningCard(") && rail.contains("\"headphones\"") && rail.contains("min left"),
              "Continue Listening card: square art, headphones, time left")
        check(rail.contains("KyroAudioShelfLimits.shared.value(.continueListening)"), "podcast shelves use the chosen limits")
        check(views.contains("KyroAudioShelfLimits.shared.value(shelf == .favoriteRadio ? .favoriteRadio : .recentRadio)"),
              "radio shelves use the chosen limits")
        let chrome = theme.components(separatedBy: "struct KyroAudioMiniChrome").last ?? ""
        check(!chrome.contains("Material") && !chrome.contains(".blur("), "mini-player polish adds no blur")
        let shelves = try source("Kyro/Home/KyroHomeShelves.swift")
        check(shelves.contains("ForEach(KyroHomeSportsHeightProbe.games(games))"), "Build 131 sports rail correction stays")
    }
}
#endif
