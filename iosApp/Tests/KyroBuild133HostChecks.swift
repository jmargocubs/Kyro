#if KYRO_PODCAST_HOST_TESTS
import Foundation
import Observation
import os

@main @MainActor
enum KyroBuild133HostChecks {
    private static var count = 0
    private static let feed = URL(string: "https://feeds.example.com/series.xml")!
    private static let id = PodcastAddress.fingerprint(feed.absoluteString)
    private static let xml = """
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" xmlns:podcast="https://podcastindex.org/namespace/1.0">
      <channel>
        <title>Signals &amp; Systems</title><description><![CDATA[<p>Show notes</p>]]></description>
        <itunes:author>Example Creator</itunes:author><itunes:image href="/cover.png"/>
        <itunes:new-feed-url>https://new.example.com/feed.xml</itunes:new-feed-url>
        <item><title>First Episode</title><guid isPermaLink="false">ep-1</guid>
          <enclosure url="/episode.mp3" type="audio/mpeg"/><description>A &amp; B</description>
          <pubDate>Tue, 21 May 2024 00:00:00 +0000</pubDate><itunes:duration>1:02:03</itunes:duration>
          <itunes:image href="/episode.png"/><itunes:season>3</itunes:season><itunes:episode>1</itunes:episode>
          <itunes:explicit>yes</itunes:explicit><podcast:chapters url="/chapters.json" type="application/json+chapters"/>
        </item>
        <item><title>Same GUID</title><guid>ep-1</guid><enclosure url="/duplicate.mp3" type="audio/mpeg"/></item>
        <item><title>Same enclosure</title><guid>other</guid><enclosure url="/episode.mp3" type="audio/mpeg"/></item>
        <item><enclosure url="/other.m4a" type="audio/mp4"/></item>
        <item><enclosure url="file:///tmp/test.mp3" type="audio/mpeg"/></item>
        <item><title>Subscriber only</title></item>
      </channel>
    </rss>
    """

    static func main() async throws {
        let parsed = try rss()
        try discoveryAndOPML(parsed)
        try await libraryAndCache(parsed)
        try playback(parsed)
        try backup(parsed)
        try playerAppearance()
        try sourceBoundaries()
        print("Build 133 podcast regressions + Build 134 appearance: \(count) host checks passed.")
        if CommandLine.arguments.contains("--live") { try await live() }
    }

    private static func require(_ value: Bool, _ message: String) {
        precondition(value, message)
        count += 1
    }

    private static func rejects(_ title: String, _ block: () throws -> Void) {
        do { try block(); require(false, title) } catch { require(true, title) }
    }

    private static func rss() throws -> PodcastFeed {
        let parsed = try PodcastFeed.parse(Data(xml.utf8), at: feed, showID: id)
        require(parsed.show.title == "Signals & Systems" && parsed.show.publisher == "Example Creator", "show identity")
        require(parsed.show.summary == "Show notes" && parsed.show.artwork?.path == "/cover.png", "description and relative artwork")
        require(parsed.migration?.host() == "new.example.com", "migration hint")
        require(parsed.episodes.count == 2, "dedupe by GUID and enclosure; reject unplayable items")
        let episode = parsed.episodes[0]
        require(episode.guid == "ep-1" && episode.id.hasPrefix(id + ":"), "stable GUID")
        require(episode.published == Date(timeIntervalSince1970: 1_716_249_600) && episode.duration == 3723, "date and duration")
        require(episode.season == 3 && episode.number == 1 && episode.explicit, "iTunes extensions")
        require(episode.chaptersURL?.path == "/chapters.json" && episode.artwork?.path == "/episode.png", "episode art and chapters")
        require(episode.summary == "A & B" && parsed.episodes[1].title == "Untitled episode", "description and missing metadata")
        rejects("truncated RSS rejected") { _ = try PodcastFeed.parse(Data(xml.dropLast(9).utf8), at: feed, showID: id) }
        rejects("non feed rejected") { _ = try PodcastFeed.parse(Data("<html><title>No</title></html>".utf8), at: feed, showID: id) }
        rejects("entities blocked") {
            let entity = "<!DOCTYPE rss [<!ENTITY x SYSTEM \"file:///etc/passwd\">]><rss><channel><title>&x;</title></channel></rss>"
            _ = try PodcastFeed.parse(Data(entity.utf8), at: feed, showID: id)
        }
        for address in ["http://localhost/a", "http://127.0.0.1/a", "http://[::1]/", "https://user:pass@example.com/feed",
                        "http://a.local/feed", "ftp://feeds.example.com/a", "http://feeds.example.com:22/a"] {
            require(PodcastAddress.url(address) == nil, "reject \(address)")
        }
        return parsed
    }

    private static func discoveryAndOPML(_ parsed: PodcastFeed) throws {
        let req = PodcastDiscovery.request(term: "  Creator & Guest ", country: "ca")!
        let items = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!.queryItems!
        require(items.contains(.init(name: "term", value: "Creator & Guest")) && items.contains(.init(name: "country", value: "CA")), "storefront and creator query")
        let json = """
        {"results":[{"feedUrl":"https://feeds.example.com/series.xml","collectionName":"Series","artistName":"Creator"},
        {"feedUrl":"https://feeds.example.com/series.xml","collectionName":"Duplicate"},
        {"collectionName":"Exclusive"},{"feedUrl":"file:///etc/passwd","collectionName":"Invalid"}]}
        """
        let matches = try PodcastDiscovery.decode(Data(json.utf8))
        require(matches.count == 1 && matches[0].feed == feed && matches[0].publisher == "Creator", "only distinct playable directory results")
        let opml = PodcastOPML.write([parsed.show, parsed.show])
        require(String(decoding: opml, as: UTF8.self).contains("Signals &amp; Systems"), "OPML XML escaping")
        let addresses = try PodcastOPML.read(opml)
        require(addresses == [feed], "OPML roundtrip deduplication")
        rejects("corrupt OPML rejected") { _ = try PodcastOPML.read(Data("<opml><body></opml>".utf8)) }
    }

    private static func libraryAndCache(_ parsed: PodcastFeed) async throws {
        let base = ProcessInfo.processInfo.environment["KYRO_TEST_TEMP"].map { URL(fileURLWithPath: $0) }!
        let defaults = UserDefaults(suiteName: "kyro.133.\(UUID())")!
        let store = KyroPodcastLibrary(defaults: defaults, base: base)
        try store.subscribe(parsed.show)
        try store.subscribe(parsed.show)
        store.importFeeds([feed, feed])
        require(store.shows.count == 1, "subscribe and OPML dedupe")
        let now = Date(timeIntervalSince1970: 1000)
        let snapshot = PodcastFeedCache(address: feed, fetched: now, etag: "\"rss-1\"", modified: nil,
                                        show: parsed.show, episodes: parsed.episodes)
        require(snapshot.isFresh(for: feed, maxAge: 1800, now: now + 600), "fresh feed skipped")
        require(!snapshot.isFresh(for: feed, maxAge: 1800, now: now + 1800), "stale feed revalidated")
        let cached = try await PodcastFeedService.shared.load(parsed.show, cached: .init(address: feed, fetched: Date(),
                                   etag: nil, modified: nil, show: parsed.show, episodes: parsed.episodes), maxAge: 10)
        require(cached.episodes == parsed.episodes, "cache-only load for a fresh snapshot")
        let disk = PodcastCacheDisk(directory: base.appendingPathComponent("Feeds"))
        try await disk.write(snapshot)
        let newStore = KyroPodcastLibrary(defaults: defaults, base: base)
        await newStore.restoreAll()
        require(newStore.entries(for: parsed.show).count == 2, "disk cache reloads offline")
        let entry = PodcastEntry(parsed.episodes[0], show: parsed.show)
        let invalidated = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = newStore.progress
        } onChange: {
            invalidated.withLock { $0 = true }
        }
        newStore.checkpoint(entry, position: 40, duration: 80, played: false, publish: false)
        require(!invalidated.withLock { $0 } && newStore.progress.isEmpty && newStore.resumePosition(for: entry.id) == 40, "private checkpoint isolated")
        let reopened = KyroPodcastLibrary(defaults: defaults, base: base)
        require(reopened.resumePosition(for: entry.id) == 40, "checkpoint resume across relaunch")
        newStore.checkpoint(entry, position: 40, duration: 80, played: false, publish: true)
        require(newStore.progress[entry.id]?.fraction == 0.5 && newStore.continuing().first == entry, "published resume card")
        newStore.mark(entry, played: true)
        require(newStore.resumePosition(for: entry.id) == 0, "played episodes replay from zero")
        newStore.unsubscribe(parsed.show)
        require(newStore.shows.isEmpty, "unsubscribe")

        let location = PodcastDownloadLocation(root: base)
        let path = location.url(for: entry.episode)
        require(path.deletingLastPathComponent().path == base.path && path.pathExtension == "mp3", "safe stable offline path")
        try Data([1, 2, 3]).write(to: path)
        let offline = try Data(contentsOf: location.existing(for: entry.episode)!)
        require(offline.count == 3, "offline lookup does not depend on network")
        var changed = entry.episode
        changed.media = URL(string: "https://feeds.example.com/stream")!
        require(location.existing(for: changed) == path, "an enclosure URL change preserves the local download")
        require(location.url(for: changed, mime: "audio/mp4").pathExtension == "m4a", "extensionless download uses MIME")
    }

    private static func playback(_ parsed: PodcastFeed) throws {
        let first = PodcastEntry(parsed.episodes[0], show: parsed.show)
        let second = PodcastEntry(parsed.episodes[1], show: parsed.show)
        var queue = PodcastQueue()
        queue.add(first, currentID: first.id)
        require(queue.entries.isEmpty, "do not queue the playing episode")
        queue.add(first, currentID: nil); queue.add(second, currentID: nil); queue.add(second, currentID: nil)
        require(queue.entries.count == 2, "queue dedupe")
        queue.move(from: 1, to: 0)
        require(queue.next() == second, "reorder controls dequeue")
        queue.remove(first.id)
        require(queue.next() == nil, "removal")
        let now = Date(timeIntervalSince1970: 100)
        let timer = PodcastSleep.make(15, now: now)
        require(!timer.shouldPause(at: now + 899) && timer.shouldPause(at: now + 900), "sleep deadline")
        require(!PodcastSleep.end.shouldPause(at: now) && PodcastSleep.end.shouldPause(at: now, ended: true), "sleep end")
        let arbiter = KyroPlaybackExclusivity()
        let owners = (0..<5).map { _ in NSObject() }
        let sources: [KyroPlaybackExclusivity.Source] = [.podcast, .radio, .video, .liveTV, .audiobook]
        var yielded: [KyroPlaybackExclusivity.Source] = []
        for (owner, source) in zip(owners, sources) { arbiter.register(owner, source: source) { yielded.append(source) } }
        require(arbiter.begin(owners[0], source: .podcast) == Array(sources.dropFirst()), "podcast yields all registered playback")
        for i in 1..<owners.count {
            yielded = []
            _ = arbiter.begin(owners[i], source: sources[i])
            require(yielded.contains(.podcast), "competing source \(sources[i]) pauses podcast")
        }
        require(PodcastCassetteMotion.spins(playing: true, seeking: false, visible: true, active: true, reduceMotion: false), "playing spins")
        require(PodcastCassetteMotion.spins(playing: false, seeking: true, visible: true, active: true, reduceMotion: false), "seeking spins")
        for (playing, visible, active, reduce) in [(false,true,true,false), (true,false,true,false), (true,true,false,false), (true,true,true,true)] {
            require(!PodcastCassetteMotion.spins(playing: playing, seeking: false, visible: visible, active: active, reduceMotion: reduce),
                    "no spin when paused, offscreen, backgrounded, or reduce motion")
        }
        let begin = PodcastCassetteMotion.tapeSizes(fraction: 0)
        let middle = PodcastCassetteMotion.tapeSizes(fraction: 0.5)
        let end = PodcastCassetteMotion.tapeSizes(fraction: 1)
        require(begin.0 == end.1 && begin.1 == end.0 && middle.0 == middle.1 && begin.0 > begin.1, "progress moves tape between reels")
    }

    private static func backup(_ parsed: PodcastFeed) throws {
        let defaults = UserDefaults(suiteName: "kyro.133.backup.\(UUID())")!
        let radio = KyroRadioPlayerAppearance(defaults: defaults)
        let library = KyroPodcastLibrary(defaults: defaults)
        var prefs = library.preferences
        require(prefs.theme == .crimsonNoir && prefs.back == 15 && prefs.forward == 30, "default preferences")
        prefs.theme = .classicWalnut
        prefs.speed = 2.5
        library.updatePreferences(prefs)
        require(KyroPodcastLibrary(defaults: defaults).preferences == prefs && radio.theme == .crimsonNoir, "independent theme persists")
        var approved = parsed.show
        approved.portableFeed = approved.feed
        try library.subscribe(approved)
        library.importFeeds([URL(string: "https://example.com/private/secret-feed?key=private-value")!])
        let entry = PodcastEntry(parsed.episodes[0], show: approved)
        library.recordStart(entry); library.toggleSaved(entry)
        library.checkpoint(entry, position: 120, duration: 3600, played: false, publish: true)
        let settings = KyroPodcastBackup.make(library: library, defaults: defaults)
        let app = SettingsBackupAppInfo(version: "1.0.133", build: "133", platform: "iOS", idiom: "phone")
        let data = try SettingsBackupCodec.encode(values: settings.compactMap { setting in
            setting.read().map { (setting.id, setting.group, $0) }
        }, app: app, now: Date())
        let text = String(decoding: data, as: UTF8.self)
        require(!text.contains("private-value") && !text.contains("episode.mp3") && !text.contains("First Episode"), "backup excludes private addresses, audio and history")
        let incoming = try SettingsBackupCodec.decode(data)
        let other = UserDefaults(suiteName: "kyro.133.restore.\(UUID())")!
        let restored = KyroPodcastLibrary(defaults: other)
        for setting in KyroPodcastBackup.make(library: restored, defaults: other) {
            if let value = incoming.groups[setting.group.rawValue]?[setting.id] {
                require(setting.validate(value), "backup validates \(setting.id)")
                try setting.write(value)
            }
        }
        require(restored.shows.count == 1 && restored.preferences == prefs && restored.saved.contains(entry.id), "restored portable subscriptions, settings and saved IDs")
        require(restored.history.isEmpty && restored.resumePosition(for: entry.id) == 120, "portable resume without history")
        let legacy = try SettingsBackupCodec.encode(values: [(id: "radio.playerTheme", group: .radio, value: .string("classicWalnut"))],
                                                     app: app, now: Date())
        let older = try SettingsBackupCodec.decode(legacy)
        require(older.groups["podcasts"] == nil && older.groups["radio"]?["radio.playerTheme"] == .string("classicWalnut"), "old backup remains readable")
        let arrangement = KyroHomeArrangement()
        require(KyroHomeShelf.allCases.filter(\.isPodcast).allSatisfy(arrangement.isHidden), "podcast home shelves opt-in")
    }

    private static func sourceBoundaries() throws {
        let base = URL(fileURLWithPath: "iosApp/iosApp")
        func source(_ path: String) throws -> String { try String(contentsOf: base.appendingPathComponent(path), encoding: .utf8) }
        let rail = try source("Kyro/Podcasts/KyroHomePodcastRail.swift")
        let shelf = try source("Control/iOS/NowPlayingShelf.swift")
        let video = try source("Screens/Player/AetherPlaybackController.swift")
        let live = try source("LiveTV/LiveTVModels.swift")
        require(!rail.contains(".clock") && !rail.contains("refreshAll") && !shelf.contains(".clock"), "Home and accessory don't read playback time")
        require(video.contains("source: .video") && live.contains("source: .liveTV"), "Silo and live player wiring")
        let home = try source("Kyro/Home/KyroHomeShelves.swift")
        require(home.contains("KyroHomeSportsHeightProbe.games(games)") && home.contains("isHeightProbe: true"), "sports tallest-card probe preserved")
        let project = try String(contentsOfFile: "iosApp/project.yml", encoding: .utf8)
        require(project.components(separatedBy: "CURRENT_PROJECT_VERSION: 135").count == 4 &&
                project.components(separatedBy: "MARKETING_VERSION: \"1.0.135\"").count == 4, "iOS app and extensions target Build 135")

        let cassette = try source("Kyro/Podcasts/KyroPodcastCassette.swift")
        let radio = try source("Kyro/Radio/KyroRadioTurntable.swift")
        let radioViews = try source("Kyro/Radio/KyroRadioViews.swift")
        let settings = try source("Kyro/Podcasts/KyroPodcastBrowser.swift")
        require(cassette.contains("select: library.selectTheme") && settings.contains("select: library.selectTheme") &&
                radio.contains("select: appearance.select"), "theme selection writes appearance directly, not playback")
        require(cassette.components(separatedBy: "player.clock").count == 3 &&
                cassette.contains("let clock = player.clock\n        let fraction") &&
                cassette.contains("let clock = player.clock\n        let value"), "clock reads stay in the reel window and timeline")
        require(cassette.contains("PodcastCassetteMotion.spins(playing:") &&
                cassette.contains("active: active, reduceMotion: reduceMotion") &&
                cassette.contains("visible: visible && dialog == nil") && !cassette.contains("TimelineView"),
                "cassette motion respects visibility, backgrounding, and Reduce Motion without a frame loop")
        require(cassette.contains("player.state == .failed") && cassette.contains("!player.isAdvancing") &&
                cassette.contains("Label(\"Buffering…\"") && cassette.contains("Tap Play to retry"),
                "podcast shows errors and buffering without showing the reels as advancing")
        require(radio.contains("case .connecting, .reconnecting: ProgressView()") &&
                radio.contains("case .failed: Image(systemName: \"arrow.clockwise\")") &&
                radio.contains("case .playing: Image(systemName: \"pause.fill\")") &&
                radio.contains("case .idle, .paused: Image(systemName: \"play.fill\")"),
                "radio retains transport affordances for all playback states")
        for action in ["action: player.toggle", "player.skip(-Double(library.preferences.back))",
                       "player.skip(Double(library.preferences.forward))", "player.seek(value)",
                       "player.updatePreferences(prefs)", "player.setSleep(minutes)", "library.toggleSaved(entry)",
                       "dialog = .queue", "dialog = .chapters", "KyroAudioOutputPicker(", "KyroCassetteVolume("] {
            require(cassette.contains(action), "cassette keeps \(action)")
        }
        require(cassette.contains("decodeSize: 46") &&
                radioViews.contains("decodeSize: KyroRadioMiniPlayerView.artworkDecodeSize") &&
                radio.contains(".task(id: station?.id) { await loadArtwork() }"),
                "theme switching does not change artwork requests or task identities")
    }

    private static func playerAppearance() throws {
        let defaults = UserDefaults(suiteName: "kyro.134.appearance.\(UUID())")!
        let appearance = KyroRadioPlayerAppearance(defaults: defaults)
        let radio = KyroRadioLibrary(defaults: defaults)
        let podcast = KyroPodcastLibrary(defaults: defaults)
        var preferred = podcast.preferences
        preferred.speed = 1.5
        preferred.forward = 45
        podcast.updatePreferences(preferred)
        require(podcast.preferences == preferred, "non-theme podcast preferences are set")

        let updated = OSAllocatedUnfairLock(initialState: [false, false])
        withObservationTracking { _ = appearance.theme } onChange: { updated.withLock { $0[0] = true } }
        withObservationTracking { _ = podcast.preferences.theme } onChange: { updated.withLock { $0[1] = true } }
        appearance.select(.modernStream)
        require(updated.withLock { $0 } == [true, false] && podcast.preferences.theme == .crimsonNoir,
                "Radio switches immediately without changing Podcast appearance")
        podcast.selectTheme(.modernStream)
        preferred.theme = .modernStream
        require(updated.withLock { $0 } == [true, true] && podcast.preferences == preferred,
                "Podcast switches immediately without changing transport preferences")
        require(KyroRadioPlayerAppearance(defaults: defaults).theme == .modernStream &&
                KyroPodcastLibrary(defaults: defaults).preferences == preferred, "Modern Stream persists in both stores")

        let radioSettings = KyroRadioBackupSettings.make(library: radio, defaults: defaults, appearance: appearance)
        let podcastSettings = KyroPodcastBackup.make(library: podcast, defaults: defaults)
        let registry = SettingsBackupRegistry(settings: radioSettings + podcastSettings, deviceIdiom: "phone")
        let scratch = URL(fileURLWithPath: ProcessInfo.processInfo.environment["KYRO_TEST_TEMP"]!)
        let applier = SettingsBackupApplier(registry: registry, journal: FileRestoreJournalStore(url: scratch.appendingPathComponent("appearance-restore.json")))

        func preview(_ values: [(id: String, group: SettingsBackupGroup, value: BackupValue)], build: Int) throws -> RestorePreview {
            let app = SettingsBackupAppInfo(version: "1.0.\(build)", build: "\(build)", platform: "iOS", idiom: "phone")
            let data = try SettingsBackupCodec.encode(values: values, app: app, now: Date())
            return SettingsBackupPlanner.preview(try SettingsBackupCodec.decode(data), registry: registry)
        }

        let appearanceEntries = registry.settings.filter { ["radio.playerTheme", "podcasts.preferences"].contains($0.id) }
        let modern = appearanceEntries.compactMap { setting in setting.read().map { (setting.id, setting.group, $0) } }
        appearance.select(.classicWalnut)
        podcast.selectTheme(.crimsonNoir)
        let modernPreview = try preview(modern, build: 134)
        require(modernPreview.totalChanges == 2 && modernPreview.groups.flatMap(\.items).allSatisfy { $0.incoming == "Modern Stream" },
                "Settings Backup recognizes and previews both Modern Stream values")
        if case .applied(let changes, _) = applier.apply(preview: modernPreview, selectedGroups: [.radio, .podcasts]) {
            require(changes.count == 2 && appearance.theme == .modernStream && podcast.preferences == preferred,
                    "Settings Backup restores both themes without dropping podcast settings")
        } else { require(false, "Modern Stream restore applies") }

        let legacyNoTheme = try preview([(id: "radio.preferences", group: .radio,
            value: KyroRadioBackupSettings.encodePreferences(KyroRadioPreferences(countryCode: "CA", countryName: "Canada")))], build: 131)
        if case .applied(let changes, _) = applier.apply(preview: legacyNoTheme, selectedGroups: [.radio, .podcasts]) {
            require(changes.map(\.id) == ["radio.preferences"] && appearance.theme == .modernStream &&
                    podcast.preferences == preferred, "older backup without theme fields leaves both choices intact")
        } else { require(false, "legacy radio preferences restore applies") }

        var legacyPodcast = preferred
        legacyPodcast.theme = .crimsonNoir
        let older = try preview([(id: "radio.playerTheme", group: .radio, value: .string("classicWalnut")),
                                 (id: "podcasts.preferences", group: .podcasts, value: KyroPodcastBackup.preferenceValue(legacyPodcast))],
                                build: 133)
        if case .applied = applier.apply(preview: older, selectedGroups: [.radio, .podcasts]) {
            require(appearance.theme == .classicWalnut && podcast.preferences == legacyPodcast,
                    "Build 133 explicit choices still restore independently")
        } else { require(false, "Build 133 themes restore applies") }
    }

    private static func live() async throws {
        let matches = try await PodcastDirectory.shared.search("Roman Mars", country: "US")
        guard let match = matches.first(where: { $0.title == "99% Invisible" }) else { throw PodcastError.unavailable }
        let show = PodcastShow(id: PodcastAddress.fingerprint(match.feed.absoluteString), feed: match.feed, title: match.title)
        let result = try await PodcastFeedService.shared.load(show, cached: nil, maxAge: 0)
        require(!result.episodes.isEmpty && result.episodes.allSatisfy { PodcastAddress.url($0.media.absoluteString) != nil }, "real public feed playable enclosures")
        print("Live: creator search returned \(matches.count) public results; \(result.show.title) parsed \(result.episodes.count) distinct episodes.")
    }
}
#endif
