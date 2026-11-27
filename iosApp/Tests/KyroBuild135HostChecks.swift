#if KYRO_PODCAST_HOST_TESTS
import Foundation

// Build 135 host checks: Apple Podcasts chart decoding, caching and request
// bounds; Library sorting; Modern Stream theme continuity and backup
// compatibility; and source contracts for the redesign (real data only, isolated
// playback clock, vintage players kept, protected engines unchanged).
// `--live` adds two bounded requests to Apple's chart and lookup endpoints.

final class FetchLog: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    func add(_ url: URL?) { lock.lock(); if let url { urls.append(url) }; lock.unlock() }
    var all: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
}

@main @MainActor
enum KyroBuild135HostChecks {
    static var count = 0
    static func check(_ condition: Bool, _ title: String) {
        precondition(condition, title)
        count += 1
    }

    static let chartJSON = """
    {"feed":{"updated":{"label":"2026-11-26T12:28:06-07:00"},"entry":[
      {"im:name":{"label":"The Joe Rogan Experience"},"im:artist":{"label":"Joe Rogan"},
       "summary":{"label":"The official podcast of comedian Joe Rogan."},
       "im:image":[{"label":"https://is1-ssl.mzstatic.com/image/thumb/Podcasts/a.jpg/55x55bb.png"},
                   {"label":"https://is1-ssl.mzstatic.com/image/thumb/Podcasts/a.jpg/170x170bb.png"}],
       "id":{"label":"https://podcasts.apple.com/us/podcast/id360084272","attributes":{"im:id":"360084272"}},
       "category":{"attributes":{"im:id":"1303","term":"Comedy","label":"Comedy"}}},
      {"im:name":{"label":"SmartLess"},"im:artist":{"label":"Jason Bateman, Sean Hayes, Will Arnett"},
       "im:image":[{"label":"https://is1-ssl.mzstatic.com/image/thumb/Podcasts/b.jpg/170x170bb.png"}],
       "id":{"attributes":{"im:id":"1521578868"}}},
      {"im:name":{"label":"Duplicate"},"id":{"attributes":{"im:id":"360084272"}}},
      {"im:name":{"label":"  "},"id":{"attributes":{"im:id":"1"}}},
      {"im:name":{"label":"Bad id"},"id":{"attributes":{"im:id":"abc"}}}
    ]}}
    """

    static func main() async throws {
        try chartDecoding()
        try await chartCaching()
        librarySorting()
        try themeContinuity()
        try sourceContracts()
        if CommandLine.arguments.contains("--live") { try await live() }
        print("Build 135: \(count) chart, library, theme and redesign checks passed.")
    }

    // MARK: Charts

    static func chartDecoding() throws {
        let entries = try PodcastChartFeed.decode(Data(chartJSON.utf8))
        check(entries.map(\.appleID) == ["360084272", "1521578868"], "chart keeps rank order, drops duplicates, blank names and bad IDs")
        check(entries[0].title == "The Joe Rogan Experience" && entries[0].creator == "Joe Rogan"
              && entries[0].summary.hasPrefix("The official") && entries[0].genre == "Comedy", "show title, creator, summary and genre")
        check(entries[0].artwork?.absoluteString.hasSuffix("/600x600bb.jpg") == true, "chart artwork is requested at 600 px")
        check(entries[1].summary.isEmpty && entries[1].genre.isEmpty, "missing optional fields are empty, not invented")
        let single = """
        {"feed":{"entry":{"im:name":{"label":"Only"},"id":{"attributes":{"im:id":"42"}}}}}
        """
        check(try PodcastChartFeed.decode(Data(single.utf8)).map(\.appleID) == ["42"], "a one-show chart decodes")
        check(try PodcastChartFeed.decode(Data(#"{"feed":{}}"#.utf8)).isEmpty, "an empty chart is empty")

        let comedy = PodcastChartFeed.request(category: .comedy, limit: 25, country: "US").url!.absoluteString
        check(comedy == "https://itunes.apple.com/us/rss/toppodcasts/limit=25/genre=1303/json", "category chart address")
        let top = PodcastChartFeed.request(category: nil, limit: 500, country: "zz9").url!.absoluteString
        check(top == "https://itunes.apple.com/us/rss/toppodcasts/limit=100/json", "overall chart, limit capped at 100, bad storefront falls back to US")
        check(PodcastChartFeed.lookupRequest(appleID: "360084272", country: "gb")!.url!.absoluteString
              == "https://itunes.apple.com/lookup?id=360084272&entity=podcast&country=gb", "lookup address")
        check(PodcastChartFeed.lookupRequest(appleID: "1;drop", country: "us") == nil, "lookup rejects non-numeric IDs")

        let lookup = #"{"resultCount":1,"results":[{"collectionId":360084272,"feedUrl":"https://feeds.megaphone.fm/GLT1412515089"}]}"#
        check(try PodcastChartFeed.decodeFeed(Data(lookup.utf8), appleID: "360084272")?.absoluteString
              == "https://feeds.megaphone.fm/GLT1412515089", "lookup gives the public feed")
        let noFeed = #"{"resultCount":1,"results":[{"collectionId":5}]}"#
        check(try PodcastChartFeed.decodeFeed(Data(noFeed.utf8), appleID: "5") == nil, "a show without a public feed has none")

        let required: [PodcastCategory] = [.comedy, .sports, .news, .trueCrime, .religion, .society, .business,
                                           .technology, .health, .music, .history, .education, .tvFilm]
        check(Set(PodcastCategory.allCases) == Set(required), "all 13 requested categories")
        check(Set(PodcastCategory.allCases.map(\.genreID)).count == 13, "each category has its own Apple genre")
        check(PodcastCategory.religion.title == "Religion & Spirituality" && PodcastCategory.tvFilm.title == "TV & Film", "category names")
    }

    static func chartCaching() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kyro135-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = FetchLog()
        let data = Data(chartJSON.utf8)
        let charts = PodcastCharts(fetch: { request in log.add(request.url); return data }, directory: directory)
        let first = try await charts.chart(category: .comedy, limit: 25, country: "us")
        _ = try await charts.chart(category: .comedy, limit: 25, country: "us")
        check(first.entries.count == 2 && log.all.count == 1, "a fresh chart is served from cache: one request for two opens")

        // Persistent: a new process reads the disk copy without a request.
        let offline = PodcastCharts(fetch: { _ in throw URLError(.notConnectedToInternet) }, directory: directory)
        let cached = await offline.cached(category: .comedy, limit: 25, country: "us")
        check(cached?.entries.count == 2, "charts persist on disk")
        let served = try await offline.chart(category: .comedy, limit: 25, country: "us")
        let offlineRequests = await offline.requestCount
        check(served.entries.count == 2 && offlineRequests == 0, "a fresh disk copy needs no request")

        // Stale after six hours; a failed refresh falls back to the stale copy.
        let later = PodcastCharts(fetch: { _ in throw URLError(.timedOut) }, directory: directory,
                                  now: { Date().addingTimeInterval(PodcastCharts.maxAge + 60) })
        let fallback = try await later.chart(category: .comedy, limit: 25, country: "us")
        let laterRequests = await later.requestCount
        check(fallback.entries.count == 2 && laterRequests == 1, "a stale chart is refreshed once, and kept when Apple is unreachable")

        // Requests are spaced so Discover can't burst Apple's limit.
        let spaced = PodcastCharts(fetch: { request in log.add(request.url); return data }, directory: nil)
        let start = Date()
        _ = try await spaced.chart(category: .news, limit: 25, country: "us")
        _ = try await spaced.chart(category: .music, limit: 25, country: "us")
        check(Date().timeIntervalSince(start) >= PodcastCharts.spacing - 0.1, "two chart requests are at least 3.2 s apart")

        // Lookups: once per show.
        let lookupLog = FetchLog()
        let lookups = PodcastCharts(fetch: { request in
            lookupLog.add(request.url)
            return Data(#"{"results":[{"collectionId":7,"feedUrl":"https://example.com/feed.xml"}]}"#.utf8)
        }, directory: nil)
        let feed = try await lookups.feed(appleID: "7", country: "us")
        _ = try await lookups.feed(appleID: "7", country: "us")
        check(feed?.absoluteString == "https://example.com/feed.xml" && lookupLog.all.count == 1, "a feed lookup happens once per show")
    }

    // MARK: Library

    static func librarySorting() {
        func show(_ id: String, _ title: String, _ publisher: String = "") -> PodcastShow {
            PodcastShow(id: id, feed: URL(string: "https://example.com/\(id).xml")!, title: title, publisher: publisher)
        }
        let shows = [show("a", "Zebra Talk"), show("b", "apple hour", "Ann"), show("c", "Middle Ground")]
        let now = Date()
        let latest = ["a": now.addingTimeInterval(-3600), "c": now]
        check(PodcastLibrarySort.sorted(shows, by: .recentlyAdded, latest: latest).map(\.id) == ["c", "b", "a"], "recently added: newest subscription first")
        check(PodcastLibrarySort.sorted(shows, by: .alphabetical, latest: latest).map(\.id) == ["b", "c", "a"], "A–Z ignores case")
        check(PodcastLibrarySort.sorted(shows, by: .recentlyUpdated, latest: latest).map(\.id) == ["c", "a", "b"],
              "recently updated: newest episode first; shows without episodes last")
        check(PodcastLibrarySort.sorted(shows, by: .alphabetical, latest: [:], matching: "ann").map(\.id) == ["b"], "search matches creator")
    }

    // MARK: Themes

    static func themeContinuity() throws {
        check(KyroRadioPlayerTheme.allCases == [.crimsonNoir, .classicWalnut, .modernStream], "three player themes, vintage ones kept")
        check(KyroRadioPlayerTheme.modernStream.rawValue == "modernStream", "existing Modern Stream selections keep their stored value")
        check(!KyroRadioPlayerTheme.modernStream.subtitle.lowercased().contains("green"), "Modern Stream is no longer green")
        check(KyroRadioPlayerTheme.default == .crimsonNoir, "default unchanged")

        let suite = "kyro.build135.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("modernStream", forKey: KyroRadioPlayerAppearance.key)
        check(KyroRadioPlayerAppearance(defaults: defaults).theme == .modernStream, "a stored Radio Modern Stream choice loads as the redesign")

        // Podcast preferences saved by Build 134 with Modern Stream decode unchanged; older ones without a theme default.
        let saved134 = #"{"theme":"modernStream","speed":1.5,"back":15,"forward":30,"refreshHours":12,"wifiOnly":true,"removeCompleted":false,"sleepMinutes":0}"#
        let prefs = try JSONDecoder().decode(PodcastPreferences.self, from: Data(saved134.utf8))
        check(prefs.theme == .modernStream && prefs.speed == 1.5, "a stored Podcast Modern Stream choice and speed survive")
        check(PodcastPreferences().theme == .crimsonNoir, "Podcast theme default unchanged")
    }

    // MARK: Source contracts

    static func source(_ path: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("iosApp/iosApp/Kyro/" + path), encoding: .utf8)
    }

    static func sourceContracts() throws {
        let modern = try source("Podcasts/KyroModernPlayers.swift")
        let cassette = try source("Podcasts/KyroPodcastCassette.swift")
        let turntable = try source("Radio/KyroRadioTurntable.swift")
        let discover = try source("Podcasts/KyroPodcastDiscoverHome.swift")
        let browser = try source("Podcasts/KyroPodcastBrowser.swift")

        // Theme routing: Modern Stream gets the new players; vintage hardware stays.
        check(cassette.contains("if KyroPodcastLibrary.shared.preferences.theme == .modernStream {\n                        KyroPodcastModernPlayer(")
              && cassette.contains("KyroPodcastCassettePlayer(entry: entry, player: player)"), "Podcasts: Modern Stream player, cassette for vintage themes")
        check(turntable.contains("if appearance.theme == .modernStream {\n            KyroRadioModernPlayer(player: player)")
              && turntable.contains("KyroTurntableDeck(palette: palette"), "Radio: Modern Stream player, turntable for vintage themes")
        for green in ["0x52F598", "0x6BFFAA", "0x65CE9A", "0x0B2115"] {
            check(!turntable.contains(green) && !modern.contains(green) && !cassette.contains(green), "no green \(green) left")
        }

        // Modern player: real features only.
        for fake in ["Comments", "Kyro X Connect", "Join the conversation", "412"] {
            check(!modern.contains(fake) && !discover.contains(fake), "no fabricated “\(fake)”")
        }
        check(modern.contains("PodcastFeedService.shared.chapters(at: url)") && modern.contains("if !chapters.isEmpty"),
              "chapters appear only from the episode's own chapter data")
        check(modern.contains("library.preferences.back") && modern.contains("library.preferences.forward"), "skip uses configured intervals")
        check(modern.contains("PodcastPreferences.speeds") && modern.contains("PodcastPreferences.sleepOptions"), "speed and sleep timer")
        check(modern.contains("ShareLink(") && modern.contains("KyroPodcastQueueView()") && modern.contains("KyroAudioOutputPicker("),
              "share, queue and AirPlay output")
        check(modern.contains("Episode Notes") && modern.contains("entry.episode.summary"), "episode notes from the feed")
        // The playback clock is read only by the timeline row.
        let clockReaders = modern.components(separatedBy: "player.clock").count - 1
        check(clockReaders == 1 && modern.contains("private struct KyroPodcastModernTimeline"), "only the timeline observes the playback clock")
        // Radio modern player: no progress, skipping or shuffle.
        let radio = modern.components(separatedBy: "// MARK: - Radio player").last ?? ""
        for unsupported in ["KyroModernScrubber", "\"gobackward", "\"goforward", "\"shuffle\"", "\"repeat\"", "skip(", "skipSymbol"] {
            check(!radio.contains(unsupported), "live radio has no \(unsupported)")
        }
        check(radio.contains("KyroModernVolume()") && radio.contains("formatLine") && radio.contains("\"LIVE\"")
              && radio.contains("library.toggleFavorite(station)") && radio.contains("player.stop()"),
              "radio: volume, codec/bitrate, live, favorite, stop")
        check(radio.contains("case .connecting, .reconnecting: true") && radio.contains("player.play(station)"),
              "radio: connecting spinner and retry")

        // Discover: real provider data, on-demand requests, no auto carousel.
        check(discover.contains("charts.loadTop()") && discover.contains("charts.loadCategory(category)")
              && discover.contains("charts.full(selection.category)"), "charts load on appear, on category choice and on See All only")
        check(!discover.contains("Timer") && !discover.contains("TimelineView") && !discover.contains("autoreverses"),
              "no automatic carousel or timers")
        check(discover.contains("Task.sleep(for: .milliseconds(900))"), "search is debounced")
        check(discover.contains("\"Apple Podcasts Top Shows\"") && discover.contains("\"From Apple Podcasts search\""),
              "charts and search results are labelled by source")
        for shelf in ["Continue Listening", "Subscriptions", "Latest Episodes", "Browse by Category", "Popular Podcasts"] {
            check(discover.contains("\"\(shelf)\""), "Discover has \(shelf)")
        }
        check(discover.contains("if !entries.isEmpty") && discover.contains("if !shows.isEmpty"), "empty personal shelves are hidden")
        check(discover.contains("LazyHStack") && discover.contains("LazyVGrid") && discover.contains("LazyVStack"), "lazy shelves and grids")
        for library in ["Shows", "Latest", "Saved", "Downloads", "History"] {
            check(discover.contains("\"\(library)\""), "Library has \(library)")
        }
        check(discover.contains("PodcastOPML.write(library.shows)") && discover.contains("library.importFeeds(feeds)"),
              "OPML import and export stay")
        check(browser.contains("case discover = \"Discover\", library = \"Library\"") && browser.contains("KyroAudioSectionPicker(title: \"Podcast section\""),
              "the dedicated Podcasts page has Discover and Library")
        check(browser.contains("KyroRadioPageNowPlayingBar()"), "the pushed page keeps the mini-player")
    }

    // MARK: Live

    static func live() async throws {
        let charts = PodcastCharts(directory: nil)
        let chart = try await charts.chart(category: .comedy, limit: 5, country: "us")
        check(!chart.entries.isEmpty && chart.entries.allSatisfy { !$0.title.isEmpty }, "live: Apple Comedy chart has shows")
        let first = chart.entries[0]
        let feed = try await charts.feed(appleID: first.appleID, country: "us")
        check(feed != nil, "live: lookup finds \(first.title)'s public feed")
        let liveRequests = await charts.requestCount
        check(liveRequests == 2, "live: two requests in total")
        print("Live: Comedy #1 \(first.title) by \(first.creator) → \(feed?.host() ?? "-")")
    }
}
#endif
