#if KYRO_PODCAST_HOST_TESTS
import Foundation

@main @MainActor
enum KyroBuild137HostChecks {
    private static var count = 0
    private static let current = URL(string: "https://feeds.example.com/show.xml")!
    private static let stale = URL(string: "https://old.example.com/show.xml")!

    static func main() async throws {
        try await routing()
        try contracts()
        print("Build 137: \(count) podcast opening and presentation checks passed.")
        if CommandLine.arguments.contains("--live") { try await live() }
    }

    private static func check(_ valid: Bool, _ message: String) {
        precondition(valid, message)
        count += 1
    }

    private static func routing() async throws {
        let hits = try PodcastDiscovery.decode(Data("""
        {"results":[{"collectionId":42,"collectionName":"Public Show","feedUrl":"https://old.example.com/show.xml"},
        {"trackId":43,"collectionName":"Lookup Only"},{"collectionId":43,"collectionName":"Duplicate"},
        {"collectionName":"Unknown and unusable"}]}
        """.utf8))
        check(hits.map(\.id) == ["42", "43"] && hits[1].feed == nil,
              "valid IDs remain tappable even when RSS is absent, and duplicates are removed")
        let mixed = Data("""
        {"results":[{"collectionId":42,"feedUrl":"https://feeds.example.com/wrong.xml"},
        {"trackId":43,"feedUrl":"https://feeds.example.com/show.xml"}]}
        """.utf8)
        let matched = try PodcastChartFeed.decodeFeed(mixed, appleID: "43")
        let wrong = try PodcastChartFeed.decodeFeed(mixed, appleID: "44")
        check(matched == current && wrong == nil, "lookup never falls back to a different show")

        var attempted: [URL] = []
        let rss = Data("""
        <rss version="2.0"><channel><title>Public Show</title><item><title>Episode</title><guid>one</guid>
        <enclosure url="https://feeds.example.com/audio.mp3" type="audio/mpeg"/></item></channel></rss>
        """.utf8)
        let parse: (URL, Bool) async throws -> PodcastShow = { address, directory in
            attempted.append(address)
            check(directory, "directory attribution survives URL resolution")
            guard address != stale else { throw PodcastError.invalidFeed }
            let feed = try PodcastFeed.parse(rss, at: address, showID: "42")
            check(feed.episodes.count == 1, "resolved public RSS exposes playable episodes")
            return feed.show
        }
        let recovered = try await hits[0].opening.resolve(lookup: { id in
            check(id == "42", "stale feed falls back to lookup by the selected show ID")
            return current
        }, load: parse)
        check(recovered.title == "Public Show" && attempted == [stale, current], "stale feed tries exactly one replacement")
        attempted = []
        _ = try await hits[1].opening.resolve(lookup: { _ in current }, load: parse)
        check(attempted == [current], "lookup-only results use the same feed opener as chart rows")

        do {
            _ = try await hits[1].opening.resolve(lookup: { _ in nil }, load: parse)
            check(false, "no RSS must not look like success")
        } catch PodcastError.noPublicFeed { check(true, "missing public RSS has a specific error") }
        do {
            _ = try await hits[1].opening.resolve(lookup: { _ in throw URLError(.timedOut) }, load: parse)
            check(false, "lookup transport failure must not be swallowed")
        } catch let error as URLError { check(error.code == .timedOut, "lookup failure remains distinguishable from missing RSS") }
        do {
            _ = try await hits[0].opening.resolve(lookup: { _ in stale }, load: parse)
            check(false, "invalid feed must not look like a successful show")
        } catch PodcastError.invalidFeed { check(true, "unchanged lookup keeps the feed parsing error") }

        let cancelled = Task {
            try await hits[1].opening.resolve(lookup: { _ in
                // Return a response even when cancelled. No stale result may load.
                try? await Task.sleep(for: .seconds(2))
                return current
            }, load: { _, _ in
                preconditionFailure("a cancelled destination must not start a feed load")
            })
        }
        await Task.yield()
        cancelled.cancel()
        do { _ = try await cancelled.value; check(false, "cancelled request must not produce a show") }
        catch is CancellationError { check(true, "cancelled lookup cannot present unrelated episodes") }
    }

    private static func contracts() throws {
        func read(_ path: String) throws -> String {
            try String(contentsOfFile: "iosApp/iosApp/" + path, encoding: .utf8)
        }
        let browser = try read("Kyro/Podcasts/KyroPodcastBrowser.swift")
        let discovery = try read("Kyro/Podcasts/KyroPodcastDiscoverHome.swift")
        let radio = try read("Kyro/Radio/KyroRadioViews.swift")
        let cassette = try read("Kyro/Podcasts/KyroPodcastCassette.swift")
        let settings = try read("Screens/Settings/IOSSettingsOverview.swift")
        check(browser.contains(".navigationDestination(item: $discovery.destination)") &&
              browser.contains("Opening public RSS feed") && browser.contains(".task(id: attempt)"),
              "tap pushes before network work, with local loading and retry")
        check(discovery.contains("discovery.open(result.opening)") && discovery.contains("discovery.open(entry.openingRequest)") &&
              discovery.contains("KyroPodcastOpeningPage(request: entry.openingRequest)"),
              "search, featured, popular, category and full charts use the common opener")
        check(discovery.contains("KyroPodcastShowView(initialShow: show, needsPageShelf: true)") &&
              browser.contains("await library.restore(show)") && browser.contains("if library.entries(for: show).isEmpty"),
              "Library restores saved episodes and fetches on cache miss")
        check(radio.contains("KyroAudioSearchField") && discovery.contains("KyroAudioSearchField") &&
              !radio.contains(".searchable(") && radio.contains("keyboardWillShowNotification") &&
              radio.contains(".safeAreaInset(edge: .bottom, spacing: 0)"), "inline search preserves the keyboard-aware host")
        check(radio.contains("KyroAudioMiniChrome(style: style)") && cassette.contains("KyroAudioMiniChrome(style: style)"),
              "both mini-players share the same chrome and preserve hosting")
        for group in ["Appearance", "Media & Playback", "Live TV", "Sports", "Radio & Podcasts", "Account & Server", "Backup & Data", "Advanced"] {
            check(settings.contains("= \"\(group)\""), "Settings includes \(group)")
        }
        check(settings.components(separatedBy: "SettingsBackupView()").count == 2 &&
              settings.contains("KyroSportsSettingsView(presentedAsSheet: false)") &&
              settings.contains("downloads.availability.isVisible"),
              "backup is moved, not duplicated; Sports and capability-gated downloads remain reachable")
    }

    private static func live() async throws {
        let charts = PodcastCharts(directory: nil)
        for (term, title, lookupOnly) in [("99% Invisible", "99% Invisible", false), ("The Daily", "The Daily", true)] {
            let results = try await PodcastDirectory.shared.search(term, country: "US")
            guard let hit = results.first(where: { $0.title == title && $0.appleID != nil }) else { throw PodcastError.unavailable }
            let route = lookupOnly
                ? PodcastShowOpeningRequest(title: hit.title, artwork: nil, feed: nil, appleID: hit.appleID, fromDirectory: true)
                : hit.opening
            let show = try await route.resolve(lookup: { try await charts.feed(appleID: $0, country: "US") },
                load: { address, _ in
                    let start = PodcastShow(id: PodcastAddress.fingerprint(address.absoluteString), feed: address, title: "")
                    let cached = try await PodcastFeedService.shared.load(start, cached: nil, maxAge: 0)
                    check(!cached.episodes.isEmpty, "live feed has playable episodes")
                    print("Live: \(cached.show.title) — \(cached.episodes.count) episodes; \(lookupOnly ? "Apple lookup → RSS" : "Apple search → RSS").")
                    return cached.show
                })
            check(!show.title.isEmpty, "live request opens a real podcast")
        }
    }
}
#endif
