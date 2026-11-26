#if KYRO_STANDALONE_TESTS
import Foundation

/// Records every request a fake Radio Browser receives and answers from a script.
private final class FakeRadioBrowser: @unchecked Sendable {
    typealias Reply = (status: Int, body: Data)
    private let lock = NSLock()
    private var log: [URLRequest] = []
    var respond: @Sendable (URLRequest) async throws -> Reply

    init(_ respond: @escaping @Sendable (URLRequest) async throws -> Reply) { self.respond = respond }

    var requests: [URLRequest] { lock.withLock { log } }
    var hosts: [String] { requests.compactMap { $0.url?.host } }
    var paths: [String] { requests.compactMap { $0.url?.path } }

    var transport: KyroRadioBrowserClient.Transport {
        { [self] request in
            lock.withLock { log.append(request) }
            let reply = try await respond(request)
            return (reply.body, HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!)
        }
    }
}

/// Holds a request until released.
private actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var opened = false
    func wait() async { if opened { return }; await withCheckedContinuation { waiters.append($0) } }
    func open() { opened = true; waiters.forEach { $0.resume() }; waiters = [] }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

private final class Owner {}

/// Fixtures, usable from fake transports off the main actor.
private enum RadioFixture {
    /// A station row in the live API's shape (fields as returned on 2026-11-25).
    static func row(_ uuid: String, name: String, url: String = "https://stream.example.org/live",
                    resolved: String? = nil, codec: String = "MP3", hls: Int = 0, tags: String = "news,talk",
                    state: String = "Chicago, Illinois") -> String {
        """
        {"changeuuid":"bf2372f1-af6e-420d-a02a-2983ffc7b8d1","stationuuid":"\(uuid)","serveruuid":null,"name":"\(name)",
         "url":"\(url)","url_resolved":"\(resolved ?? url)","homepage":"https://example.org/","favicon":"https://example.org/logo.png",
         "tags":"\(tags)","country":"The United States Of America","countrycode":"US","iso_3166_2":null,"state":"\(state)",
         "language":"english","languagecodes":"en","votes":62,"lastchangetime_iso8601":"2026-03-30T15:43:00Z","codec":"\(codec)",
         "bitrate":192,"hls":\(hls),"lastcheckok":1,"clickcount":20,"clicktrend":20,"ssl_error":0,"geo_lat":41.8,"geo_long":-87.6,
         "has_extended_info":false}
        """
    }

    static func uuid(_ n: Int) -> String { String(format: "aa9282e9-1821-4b22-8b25-%012d", n) }

    static func page(_ range: Range<Int>, codec: (Int) -> String = { _ in "MP3" }) -> Data {
        Data(("[" + range.map { row(uuid($0), name: "Station \($0)", codec: codec($0)) }.joined(separator: ",") + "]").utf8)
    }

    static let servers = Data(#"[{"ip":"1.1.1.1","name":"de1.api.radio-browser.info"},{"ip":"::1","name":"de1.api.radio-browser.info"},{"ip":"2.2.2.2","name":"nl1.api.radio-browser.info"},{"ip":"3.3.3.3","name":"evil.example.com"}]"#.utf8)

    static func suite() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "kyro.build128.\(UUID())")!
        return defaults
    }

    fileprivate static func client(_ fake: FakeRadioBrowser, defaults: UserDefaults? = nil, cache: URL? = nil,
                       clock: Clock = Clock()) -> KyroRadioBrowserClient {
        KyroRadioBrowserClient(transport: fake.transport, defaults: defaults ?? suite(), cacheDirectory: cache,
                               userAgent: "KyroX/1.0.128", now: { clock.now }, shuffle: { $0 })
    }

}

@main @MainActor
enum KyroBuild128HostChecks {
    static var count = 0
    static func check(_ condition: Bool, _ title: String) { precondition(condition, title); count += 1 }

    /// Names the step an unexpected error came from.
    static func step(_ name: String, _ body: () async throws -> Void) async throws {
        do { try await body() } catch { print("Build 128 step \(name) threw \(error)"); throw error }
    }

    static func main() async throws {
        setvbuf(stdout, nil, _IONBF, 0)
        decoding()
        queries()
        try await step("failover", failover)
        try await step("coalescingAndCancellation", coalescingAndCancellation)
        try await step("caching", caching)
        try await step("discoverPagination", discoverPagination)
        library()
        backup()
        machine()
        exclusivity()
        home()
        print("Build 128: \(count) Radio host checks passed (fixtures shaped from live Radio Browser responses).")
        if let index = CommandLine.arguments.firstIndex(of: "--live-sample") {
            let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            let stations = try KyroRadioBrowserClient.decodeStations(data)
            check(!stations.isEmpty, "live Radio Browser sample decodes through the production path")
            print("Live sample: \(stations.count) stations; first \(stations[0].name) [\(stations[0].formatLine ?? "")] playable=\(stations[0].isPlayable)")
        }
    }

    // MARK: Decoding

    static func decoding() {
        let json = "[" + [
            RadioFixture.row(RadioFixture.uuid(1), name: "011.fm – House of Hair", url: "http://listen.example.org/a", resolved: "https://listen.example.org/a"),
            RadioFixture.row("not-a-uuid", name: "Bad ID"),
            RadioFixture.row(RadioFixture.uuid(2), name: "   "),
            RadioFixture.row(RadioFixture.uuid(3), name: "FTP only", url: "ftp://example.org/stream"),
            #"{"stationuuid":"\#(RadioFixture.uuid(4))","name":"Sparse","url":"https://s.example.org/live"}"#,
            #"{"stationuuid": 7}"#,
            RadioFixture.row(RadioFixture.uuid(1), name: "Duplicate"),
            RadioFixture.row(RadioFixture.uuid(5), name: "Ogg station", codec: "OGG"),
            RadioFixture.row(RadioFixture.uuid(6), name: "BBC HLS", codec: "UNKNOWN", hls: 1),
        ].joined(separator: ",") + "]"
        let stations = try! KyroRadioBrowserClient.decodeStations(Data(json.utf8))
        check(stations.map(\.name) == ["011.fm – House of Hair", "Sparse", "Ogg station", "BBC HLS"],
              "decode keeps valid rows, skips bad IDs, blank names, non-http streams, malformed rows and duplicates")
        let first = stations[0]
        check(first.id == RadioFixture.uuid(1) && first.countryCode == "US" && first.state == "Chicago, Illinois" && first.tags == ["news", "talk"],
              "stable UUID, location and tags decode")
        check(first.playbackCandidates.map(\.absoluteString) == ["https://listen.example.org/a", "http://listen.example.org/a"],
              "https stream preferred over http")
        check(first.formatLine == "MP3 · 192 kbps", "format line")
        check(stations[1].lastCheckOK && stations[1].tags.isEmpty && stations[1].isPlayable, "sparse row decodes with defaults")
        check(!stations[2].isPlayable && stations[3].isPlayable, "Ogg is unsupported; HLS of unknown codec is playable")
        check(KyroRadioStation.webURL("javascript:alert(1)") == nil && KyroRadioStation.webURL("file:///etc/hosts") == nil,
              "only http(s) URLs accepted")
        check(KyroRadioTrack(streamTitle: "Bon Jovi - Livin' on a Prayer", stationName: "X")
              == KyroRadioTrack(title: "Livin' on a Prayer", artist: "Bon Jovi"), "ICY StreamTitle splits artist and title")
        check(KyroRadioTrack(streamTitle: "WGN 720", stationName: "wgn 720") == nil
              && KyroRadioTrack(streamTitle: "  ", stationName: "X") == nil
              && KyroRadioTrack(streamTitle: "https://ads.example.org", stationName: "X") == nil,
              "station name, empty and link metadata are not shown as a song")
        check(KyroRadioTrack(streamTitle: "Morning Show", stationName: "X") == KyroRadioTrack(title: "Morning Show", artist: nil),
              "title without artist stays a title")
        let pls = Data("[playlist]\nNumberOfEntries=2\nFile1=https://a.example.org/stream\nTitle1=A\nFile2=http://b.example.org/s\n".utf8)
        check(KyroRadioPlaylist.entries(pls).map(\.absoluteString) == ["https://a.example.org/stream", "http://b.example.org/s"],
              ".pls entries parsed")
        let m3u = Data("#EXTM3U\n#EXTINF:-1,Station\nhttp://c.example.org/live\nrtsp://d.example.org/x\n".utf8)
        check(KyroRadioPlaylist.entries(m3u).map(\.absoluteString) == ["http://c.example.org/live"], ".m3u entries parsed, non-http dropped")
        check(KyroRadioPlaylist.isPlaylist(URL(string: "http://x.org/a.pls")!) && !KyroRadioPlaylist.isPlaylist(URL(string: "http://x.org/a.m3u8")!),
              "HLS .m3u8 is a stream, not a playlist")
        let facets = try! JSONDecoder().decode(KyroRadioLossyArray<KyroRadioFacet.Payload>.self,
            from: Data(#"[{"name":"The United States Of America","iso_3166_1":"US","stationcount":7148},{"name":"Bad","iso_3166_1":"USA","stationcount":3}]"#.utf8))
        check(facets.elements.compactMap { KyroRadioFacet(payload: $0, kind: .country) }.map(\.value) == ["US"], "country facet uses ISO code")
    }

    static func queries() {
        func items(_ query: KyroRadioQuery, offset: Int = 0) -> [String: String] {
            Dictionary(uniqueKeysWithValues: query.queryItems(offset: offset).map { ($0.name, $0.value ?? "") })
        }
        let illinois = items(.illinois())
        check(illinois["countrycode"] == "US" && illinois["state"] == "Illinois" && illinois["hidebroken"] == "true"
              && illinois["order"] == "clickcount" && illinois["reverse"] == "true" && illinois["limit"] == "40",
              "Illinois discovery without location permission, broken stations hidden, popular first")
        check(items(.worldwide())["countrycode"] == nil, "worldwide has no country filter")
        var search = KyroRadioQuery.unitedStates()
        search.text = "  WGN  "
        check(items(search)["name"] == "WGN", "call sign searched by name")
        search.field = .genre
        search.text = "Jazz"
        check(items(search)["tag"] == "jazz" && items(search)["name"] == nil, "genre search uses tag")
        search.field = .location
        search.text = "Chicago"
        check(items(search)["state"] == "Chicago", "location search uses state")
        var language = KyroRadioQuery(language: "spanish")
        language.text = String(repeating: "a", count: 500)
        check(items(language)["language"] == "spanish" && items(language)["name"]?.count == 100, "language filter; search text bounded")
        check(items(.worldwide(), offset: 80)["offset"] == "80", "pagination offset")
    }

    // MARK: Client

    static func failover() async throws {
        let fake = FakeRadioBrowser { request in
            switch (request.url!.host!, request.url!.path) {
            case ("all.api.radio-browser.info", "/json/servers"): return (200, RadioFixture.servers)
            case ("de1.api.radio-browser.info", _): return (503, Data())
            case ("nl1.api.radio-browser.info", _): return (200, RadioFixture.page(0..<3))
            default: return (404, Data())
            }
        }
        let api = RadioFixture.client(fake)
        let stations = try await api.stations(.unitedStates(), offset: 0)
        check(stations.count == 3, "results after failover")
        check(fake.hosts == ["all.api.radio-browser.info", "de1.api.radio-browser.info", "nl1.api.radio-browser.info"],
              "mirrors discovered, unknown hosts rejected, failed mirror skipped to the next")
        check(fake.requests.allSatisfy { $0.value(forHTTPHeaderField: "User-Agent") == "KyroX/1.0.128" }, "identifying User-Agent on every request")
        check(fake.requests.allSatisfy { $0.url?.scheme == "https" && $0.timeoutInterval <= 12 }, "https with a bounded timeout")
        _ = try await api.stations(.illinois(), offset: 0)
        check(fake.hosts.last == "nl1.api.radio-browser.info" && fake.hosts.filter { $0 == "de1.api.radio-browser.info" }.count == 1,
              "working mirror preferred; failed mirror rests")

        let limited = FakeRadioBrowser { request in
            switch request.url!.host! {
            case "all.api.radio-browser.info" where request.url!.path == "/json/servers": return (200, RadioFixture.servers)
            case "de1.api.radio-browser.info": return (429, Data())
            default: return (200, RadioFixture.page(0..<1))
            }
        }
        _ = try await RadioFixture.client(limited).stations(.worldwide(), offset: 0)
        check(limited.hosts.suffix(2) == ["de1.api.radio-browser.info", "nl1.api.radio-browser.info"], "rate-limited mirror fails over")

        let notFound = FakeRadioBrowser { request in
            request.url!.path == "/json/servers" ? (200, RadioFixture.servers) : (404, Data())
        }
        do {
            _ = try await RadioFixture.client(notFound).stations(.worldwide(), offset: 0)
            check(false, "404 must fail")
        } catch {
            check(error as? KyroRadioBrowserError == .badResponse && notFound.requests.count == 2, "client error is not retried on every mirror")
        }

        let noDiscovery = FakeRadioBrowser { request in
            request.url!.path == "/json/servers" ? (500, Data()) : (200, RadioFixture.page(0..<2))
        }
        let fallback = try await RadioFixture.client(noDiscovery).stations(.worldwide(), offset: 0)
        check(fallback.count == 2 && noDiscovery.hosts == ["all.api.radio-browser.info", "all.api.radio-browser.info"],
              "without a mirror list, the round-robin host is used")

        let offline = FakeRadioBrowser { _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await RadioFixture.client(offline).stations(.worldwide(), offset: 0)
            check(false, "offline must fail")
        } catch {
            check(error as? KyroRadioBrowserError == .unavailable && offline.requests.count <= 1 + KyroRadioBrowserClient.maxAttempts,
                  "offline fails clearly within the attempt bound")
        }

        let huge = FakeRadioBrowser { request in
            request.url!.path == "/json/servers" ? (200, RadioFixture.servers) : (200, Data(count: KyroRadioBrowserClient.maxResponseBytes + 1))
        }
        do {
            _ = try await RadioFixture.client(huge).stations(.worldwide(), offset: 0)
            check(false, "oversized response must fail")
        } catch {
            check(error as? KyroRadioBrowserError == .badResponse, "response size is bounded")
        }

        let clock = Clock()
        let clicks = FakeRadioBrowser { request in
            request.url!.path == "/json/servers" ? (200, RadioFixture.servers) : (200, Data(#"{"ok":true}"#.utf8))
        }
        let clickClient = RadioFixture.client(clicks, clock: clock)
        await clickClient.reportClick(RadioFixture.uuid(9))
        await clickClient.reportClick(RadioFixture.uuid(9))
        check(clicks.paths.filter { $0.hasPrefix("/json/url/") } == ["/json/url/\(RadioFixture.uuid(9))"], "click reported once per station per day")
        clock.advance(86_401)
        await clickClient.reportClick(RadioFixture.uuid(9))
        await clickClient.reportClick("not-a-station")
        check(clicks.paths.filter { $0.hasPrefix("/json/url/") }.count == 2, "click reported again next day; invalid IDs never sent")

        let playlist = FakeRadioBrowser { _ in (200, Data("[playlist]\nFile1=https://real.example.org/stream\n".utf8)) }
        let resolved = try await RadioFixture.client(playlist).resolvePlaylist(URL(string: "https://station.example.org/listen.pls")!)
        check(resolved.absoluteString == "https://real.example.org/stream", "playlist resolved to its stream")
    }

    static func coalescingAndCancellation() async throws {
        let gate = Gate()
        let fake = FakeRadioBrowser { request in
            if request.url!.path == "/json/servers" { return (200, RadioFixture.servers) }
            await gate.wait()
            return (200, RadioFixture.page(0..<2))
        }
        let api = RadioFixture.client(fake)
        async let first = api.stations(.illinois(), offset: 0)
        async let second = api.stations(.illinois(), offset: 0)
        try await Task.sleep(nanoseconds: 50_000_000)
        await gate.open()
        let (a, b) = try await (first, second)
        check(a == b && fake.paths.filter { $0 == "/json/stations/search" }.count == 1, "identical concurrent requests coalesce into one")

        let slowGate = Gate()
        let slow = FakeRadioBrowser { request in
            if request.url!.path == "/json/servers" { return (200, RadioFixture.servers) }
            await slowGate.wait()
            try Task.checkCancellation()
            return (200, RadioFixture.page(0..<2))
        }
        let slowClient = RadioFixture.client(slow)
        let abandoned = Task { try await slowClient.stations(.worldwide(), offset: 0) }
        try await Task.sleep(nanoseconds: 50_000_000)
        abandoned.cancel()
        await slowGate.open()
        let outcome = await abandoned.result
        if case .failure(let error) = outcome {
            check(error is CancellationError, "a superseded request is cancelled")
        } else {
            check(false, "cancelled request must not deliver results")
        }
    }

    static func caching() async throws {
        let clock = Clock()
        let fake = FakeRadioBrowser { request in
            switch request.url!.path {
            case "/json/servers": return (200, RadioFixture.servers)
            case "/json/tags": return (200, Data(#"[{"name":"pop","stationcount":5218},{"name":"jazz","stationcount":900}]"#.utf8))
            default: return (200, RadioFixture.page(0..<2))
            }
        }
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("kyro-radio-\(UUID())")
        defer { try? FileManager.default.removeItem(at: cache) }
        let defaults = RadioFixture.suite()
        let api = RadioFixture.client(fake, defaults: defaults, cache: cache, clock: clock)
        _ = try await api.stations(.unitedStates(), offset: 0)
        _ = try await api.stations(.unitedStates(), offset: 0)
        check(fake.paths.filter { $0 == "/json/stations/search" }.count == 1, "repeat search served from memory cache")
        clock.advance(KyroRadioBrowserClient.responseLifetime + 1)
        _ = try await api.stations(.unitedStates(), offset: 0)
        check(fake.paths.filter { $0 == "/json/stations/search" }.count == 2, "expired search refetched")
        let tags = try await api.facets(.tag)
        check(tags.map(\.title) == ["Pop", "Jazz"], "genres decode")
        // A new launch, offline: genres come from the disk cache, even stale.
        clock.advance(KyroRadioBrowserClient.facetLifetime * 2)
        let offline = FakeRadioBrowser { _ in throw URLError(.notConnectedToInternet) }
        let relaunched = RadioFixture.client(offline, defaults: defaults, cache: cache, clock: clock)
        check(try await relaunched.facets(.tag).count == 2, "saved genres survive offline relaunch")
        // The saved mirror list is past its one-day lifetime: discovery is tried
        // first, then the saved mirrors are still used.
        check(offline.paths.first == "/json/servers" && offline.hosts.dropFirst().first == "de1.api.radio-browser.info",
              "mirror list persisted across launches and refreshed when old")
    }

    static func discoverPagination() async throws {
        let fake = FakeRadioBrowser { request in
            if request.url!.path == "/json/servers" { return (200, RadioFixture.servers) }
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
            let offset = Int(items.first { $0.name == "offset" }!.value!)!
            let state = items.first { $0.name == "state" }?.value
            if state == "Nowhere" { return (200, Data("[]".utf8)) }
            // 40 + 40 + 5 stations; every tenth is Ogg (hidden).
            let end = min(offset + 40, 85)
            return (200, RadioFixture.page(offset..<end, codec: { $0 % 10 == 0 ? "OGG" : "MP3" }))
        }
        let model = KyroRadioDiscoverModel(client: RadioFixture.client(fake), debounceNanoseconds: 0)
        model.loadIfNeeded(.unitedStates())
        await model.waitForLoad()
        check(model.phase == .loaded && model.stations.count == 36 && model.canLoadMore, "first page, unsupported formats hidden")
        model.loadMore()
        await model.waitForLoad()
        model.loadMore()
        await model.waitForLoad()
        check(model.stations.count == 76 && !model.canLoadMore && Set(model.stations.map(\.id)).count == 76,
              "pages append without duplicates and stop at the end")
        model.update(KyroRadioQuery(countryCode: "US", state: "Nowhere"))
        await model.waitForLoad()
        check(model.phase == .loaded && model.stations.isEmpty && !model.canLoadMore, "empty result state")

        let gate = Gate()
        let racing = FakeRadioBrowser { request in
            if request.url!.path == "/json/servers" { return (200, RadioFixture.servers) }
            if request.url!.query?.contains("Old") == true { await gate.wait() }
            return (200, RadioFixture.page(0..<2))
        }
        let stale = KyroRadioDiscoverModel(client: RadioFixture.client(racing), debounceNanoseconds: 0)
        var old = KyroRadioQuery(); old.text = "Old"
        stale.update(old)
        try await Task.sleep(nanoseconds: 30_000_000)
        var new = KyroRadioQuery(); new.text = "New"
        stale.update(new)
        await stale.waitForLoad()
        await gate.open()
        try await Task.sleep(nanoseconds: 30_000_000)
        check(stale.query.text == "New" && stale.phase == .loaded && stale.stations.count == 2, "a late response for an old query is dropped")

        let failing = KyroRadioDiscoverModel(client: RadioFixture.client(FakeRadioBrowser { _ in throw URLError(.timedOut) }), debounceNanoseconds: 0)
        failing.loadIfNeeded(.worldwide())
        await failing.waitForLoad()
        if case .failed(let message) = failing.phase {
            check(message.contains("Check your connection"), "error state with a retryable message")
        } else { check(false, "failure must show an error") }
    }

    // MARK: Library

    static func library() {
        let defaults = RadioFixture.suite()
        let clock = Clock()
        let lib = KyroRadioLibrary(defaults: defaults, now: { clock.now })
        let stations = try! KyroRadioBrowserClient.decodeStations(RadioFixture.page(0..<60))
        check(lib.favorites.isEmpty && lib.preferences.countryCode == "US", "defaults: no favorites, United States")
        lib.setFavorite(stations[1], true); clock.advance(1)
        lib.setFavorite(stations[0], true); clock.advance(1)
        lib.setFavorite(stations[0], true)
        check(lib.favorites.map(\.id) == [stations[0].id, stations[1].id], "no duplicate favorites; newest first")
        let reopened = KyroRadioLibrary(defaults: defaults)
        check(reopened.favorites.map(\.station) == [stations[0], stations[1]], "favorites persist with full details for offline use")
        check(reopened.favorites(matching: "station 1", sort: .name).map(\.id) == [stations[1].id], "Library search")
        lib.setFavorite(KyroRadioStation(id: RadioFixture.uuid(99), name: "Alpha", streamURL: URL(string: "https://a.org")), true)
        check(lib.favorites(matching: "", sort: .name).first?.station.name == "Alpha"
              && lib.favorites(matching: "", sort: .recentlyAdded).first?.station.name == "Alpha", "sorting by name and recently added")
        lib.toggleFavorite(stations[1])
        check(!lib.isFavorite(stations[1].id), "unfavorite")

        for station in stations { lib.recordPlay(station); clock.advance(1) }
        lib.recordPlay(stations[10])
        check(lib.history.count == KyroRadioLibrary.maxHistory && lib.history.first?.id == stations[10].id
              && Set(lib.history.map(\.id)).count == lib.history.count, "history bounded, most recent first, no repeats")
        check(KyroRadioLibrary(defaults: defaults).history.count == KyroRadioLibrary.maxHistory, "history persists")
        lib.removeFromHistory(stations[10].id)
        check(!lib.history.contains { $0.id == stations[10].id }, "remove one history entry")
        lib.clearHistory()
        check(lib.history.isEmpty && KyroRadioLibrary(defaults: defaults).history.isEmpty, "clear history")

        var renamed = stations[0]
        renamed.name = "Renamed"
        lib.refreshDetails([renamed])
        check(lib.favorites.first { $0.id == renamed.id }?.station.name == "Renamed", "fresh details update saved favorites")
        lib.updatePreferences { $0 = KyroRadioPreferences(countryCode: "usa", countryName: "X", state: "Illinois", language: "English") }
        check(lib.preferences.countryCode == nil && lib.preferences.state == nil && lib.preferences.language == "english",
              "invalid country code falls back to worldwide")
        defaults.set(Data("garbage".utf8), forKey: KyroRadioLibrary.favoritesKey)
        check(KyroRadioLibrary(defaults: defaults).favorites.isEmpty, "corrupt storage reads as empty, never crashes")
    }

    // MARK: Backup

    static func backup() {
        let defaults = RadioFixture.suite()
        let lib = KyroRadioLibrary(defaults: defaults)
        let full = KyroRadioStation(id: RadioFixture.uuid(1), name: "WGN 720 ..// https://x", streamURL: URL(string: "http://98.82.2.45/wgn"))
        lib.setFavorite(full, true)
        lib.setFavorite(KyroRadioStation(id: RadioFixture.uuid(2), name: "Jazz", streamURL: URL(string: "https://j.org/live")), true)
        lib.recordPlay(full)
        lib.updatePreferences { $0 = KyroRadioPreferences(countryCode: "US", countryName: "United States", state: "Illinois", language: nil) }
        var scope: String? = "s.a.p1"
        let settings = KyroRadioBackupSettings.make(library: lib, defaults: defaults, scope: { scope })
        func setting(_ id: String) -> BackupSetting { settings.first { $0.id == id }! }
        check(settings.map(\.id) == ["radio.favorites", "radio.preferences", "radio.homeShelves", "radio.playerTheme"]
              && settings.allSatisfy { $0.group == .radio && !SettingsBackupSafety.isSensitiveName($0.id) },
              "radio backup entries in their own group; no history entry")
        let favorites = setting("radio.favorites").read()!
        check(!SettingsBackupSafety.isSuspiciousValue(favorites), "favorites backup has no links, paths or control characters")
        check(favorites == .array([.array([.string("\(RadioFixture.uuid(2))|Jazz"), .string("\(RadioFixture.uuid(1))|WGN 720 .// https x")])]),
              "favorites back up as ID and portable name, newest first")
        let prefs = setting("radio.preferences").read()!
        check(!SettingsBackupSafety.isSuspiciousValue(prefs) && setting("radio.preferences").validate(prefs), "preferences portable")
        if case .record(let fields) = prefs { check(!fields.keys.contains(where: SettingsBackupSafety.isSensitiveName), "no sensitive field names") }

        // Restore onto another device that already has one of the stations.
        let other = RadioFixture.suite()
        let target = KyroRadioLibrary(defaults: other)
        target.setFavorite(KyroRadioStation(id: RadioFixture.uuid(2), name: "Jazz", streamURL: URL(string: "https://j.org/live")), true)
        let restoreSettings = KyroRadioBackupSettings.make(library: target, defaults: other, scope: { scope })
        try! restoreSettings[0].write(favorites)
        try! restoreSettings[1].write(prefs)
        check(target.favorites.map(\.id) == [RadioFixture.uuid(2), RadioFixture.uuid(1)], "restored favorites keep backup order")
        check(target.favorites[0].station.playbackCandidates.count == 1 && target.favorites[1].station.playbackCandidates.isEmpty
              && target.stationsNeedingDetails == [RadioFixture.uuid(1)], "known stations keep details; others fetch details by ID later")
        check(target.history.isEmpty && target.preferences.state == "Illinois", "history not restored; preferences restored")
        check(!setting("radio.favorites").validate(.array([.array([.string("bad|x")])]))
              && !setting("radio.favorites").validate(.array([.array([.string("\(RadioFixture.uuid(1))|a"), .string("\(RadioFixture.uuid(1))|b")])]))
              && !setting("radio.preferences").validate(.record(["country": .string("USA")])),
              "invalid IDs, duplicates and unknown shapes rejected")
        let many = (0..<300).map { KyroRadioSavedStation(station: KyroRadioStation(id: RadioFixture.uuid($0), name: "S\($0)", streamURL: nil), date: Date()) }
        let capped = KyroRadioBackupSettings.encodeFavorites(many)
        check(KyroRadioBackupSettings.favorites(capped)?.count == KyroRadioBackupSettings.maxBackupFavorites
              && setting("radio.favorites").validate(capped), "backup holds the newest 200 favorites in pages of 64")

        // Home shelf visibility travels separately from the v3 arrangement.
        let shelves = setting("radio.homeShelves")
        check(shelves.read() == .record(["favorites": .bool(false), "recent": .bool(false)]), "radio shelves start off")
        try! shelves.write(.record(["favorites": .bool(true), "recent": .bool(false)]))
        check(KyroHomeArrangementStore.load(scope: scope, from: defaults).shownOptIn == [.favoriteRadio], "radio shelf visibility restored")
        let home = KyroHomeBackupSettings.make(defaults: defaults, scope: { scope }).first { $0.id == "home.localShelves" }!
        var arrangement = KyroHomeArrangementStore.load(scope: scope, from: defaults)
        arrangement.setOrder(arrangement.allEntries(for: []))
        KyroHomeArrangementStore.save(arrangement, scope: scope, to: defaults)
        let exported = home.read()!
        if case .record(let fields) = exported, case .array(let pages) = fields["order"] {
            let tokens = pages.flatMap { if case .array(let m) = $0 { return m } else { return [] } }
            check(!tokens.contains(.string("kyro:favoriteRadio")) && tokens.contains(.string("kyro:myTeams")),
                  "v3 order omits radio tokens so Build 127 can still restore it")
        } else { check(false, "v3 arrangement shape") }
        try! home.write(exported)
        check(KyroHomeArrangementStore.load(scope: scope, from: defaults).shownOptIn == [.favoriteRadio],
              "restoring the arrangement keeps radio shelf visibility")
        scope = nil
    }

    // MARK: Playback

    static func machine() {
        let station = KyroRadioStation(id: RadioFixture.uuid(1), name: "Two Streams", streamURL: URL(string: "http://a.org/s"),
                                       resolvedURL: URL(string: "https://a.org/s"), codec: "AAC")
        var m = KyroRadioPlaybackMachine()
        var effects = m.play(station)
        check(effects == [.recordStart, .load(candidate: 0, generation: 1)] && m.state == .connecting, "tap starts connecting")
        m.playerStarted(generation: 0)
        check(m.state == .connecting, "stale start ignored")
        effects = m.playerFailed(generation: 1)
        check(effects == [.load(candidate: 1, generation: 2)] && m.state == .connecting, "second stream address tried first")
        m.playerStarted(generation: 2)
        check(m.state == .playing, "playing")
        effects = m.pause()
        check(effects == [.pausePlayer] && m.state == .paused, "pause")
        effects = m.resume()
        check(effects == [.load(candidate: 0, generation: 4)] && m.state == .connecting, "resume reconnects at the live edge")
        m.playerStarted(generation: 4)
        for attempt in 1...KyroRadioPlaybackMachine.maxReconnectAttempts {
            effects = m.playerFailed(generation: m.generation)
            check(m.state == .reconnecting(attempt: attempt)
                  && effects.last == .scheduleReconnect(delay: pow(2, Double(attempt - 1)), generation: m.generation),
                  "bounded reconnect \(attempt) with backoff")
            effects = m.reconnectDue(generation: m.generation)
            check(effects == [.load(candidate: 0, generation: m.generation)], "reconnect loads again")
        }
        effects = m.playerFailed(generation: m.generation)
        check(m.state == .failed(.streamFailed) && effects == [.stopPlayer], "clear failure after the last attempt")
        check(m.reconnectDue(generation: m.generation).isEmpty, "no reconnect after failure")
        effects = m.resume()
        m.playerStarted(generation: m.generation)
        check(m.state == .playing, "retry after failure")
        _ = m.interruptionBegan()
        check(m.state == .paused && m.resumesAfterInterruption, "interruption pauses")
        _ = m.interruptionEnded(shouldResume: true)
        check(m.state == .connecting, "resumes after interruption when the system allows")
        m.playerStarted(generation: m.generation)
        _ = m.pause()
        check(m.interruptionEnded(shouldResume: true).isEmpty && m.state == .paused, "listener's pause is not undone by an interruption end")
        _ = m.resume(); m.playerStarted(generation: m.generation)
        _ = m.outputRouteLost()
        check(m.state == .paused, "headphones unplugged pause")
        _ = m.resume(); m.playerStarted(generation: m.generation)
        _ = m.yieldToOtherPlayback()
        check(m.state == .paused && !m.isActive, "radio pauses when other playback starts")
        check(m.stop() == [.stopPlayer] && m.state == .idle && m.station == nil, "stop clears the session")
        var unsupported = KyroRadioPlaybackMachine()
        _ = unsupported.play(KyroRadioStation(id: RadioFixture.uuid(2), name: "Ogg", streamURL: URL(string: "https://o.org"), codec: "OGG"))
        check(unsupported.state == .failed(.unsupportedFormat), "unsupported format is a clear error")
        var noStream = KyroRadioPlaybackMachine()
        _ = noStream.play(KyroRadioStation(id: RadioFixture.uuid(3), name: "Restored", streamURL: nil))
        check(noStream.state == .failed(.noStream), "missing stream is a clear error")
    }

    static func exclusivity() {
        let coordinator = KyroPlaybackExclusivity()
        let radio = Owner(), video = Owner(), live = Owner(), book = Owner()
        var yielded: [String] = []
        coordinator.register(radio, source: .radio) { yielded.append("radio") }
        coordinator.register(video, source: .video) { yielded.append("video") }
        coordinator.register(live, source: .liveTV) { yielded.append("liveTV") }
        coordinator.register(book, source: .audiobook) { yielded.append("audiobook") }
        coordinator.begin(video, source: .video)
        check(yielded == ["radio"], "video start pauses radio only; video and Live TV keep their own rules")
        yielded = []
        coordinator.begin(live, source: .liveTV)
        coordinator.begin(book, source: .audiobook)
        check(yielded == ["radio", "radio"], "Live TV and audiobook starts pause radio")
        yielded = []
        coordinator.begin(radio, source: .radio)
        check(Set(yielded) == ["video", "liveTV", "audiobook"] && !yielded.contains("radio"), "radio start pauses every other player")
        yielded = []
        var temporary: Owner? = Owner()
        coordinator.register(temporary!, source: .video) { yielded.append("gone") }
        temporary = nil
        coordinator.begin(radio, source: .radio)
        check(!yielded.contains("gone"), "released players are forgotten")
    }

    // MARK: Home

    static func home() {
        let fresh = KyroHomeArrangement()
        check(fresh.isHidden(.favoriteRadio) && fresh.isHidden(.recentRadio) && !fresh.isHidden(.myTeams),
              "radio shelves off by default")
        check(!fresh.entries(for: []).contains(.kyro(.favoriteRadio)) && fresh.allEntries(for: []).contains(.kyro(.recentRadio)),
              "radio shelves listed in Customize Home but not drawn")
        let saved127 = Data(#"{"tokens":["silo:cw","kyro:myTeams","kyro:sportsToday"],"hidden":["upcomingSports"],"hiddenSilo":[]}"#.utf8)
        var decoded = try! JSONDecoder().decode(KyroHomeArrangement.self, from: saved127)
        check(decoded.hidden == [.upcomingSports] && decoded.isHidden(.favoriteRadio)
              && decoded.entries(for: [.init(id: "cw", type: "continue_watching")]).prefix(3)
                 == [.silo("cw"), .kyro(.myTeams), .kyro(.sportsToday)],
              "a Build 127 arrangement keeps its order and visibility; radio stays off")
        decoded.setHidden(.recentRadio, false)
        check(!decoded.isHidden(.recentRadio) && decoded.hidden == [.upcomingSports], "turning a radio shelf on")
        let roundTrip = try! JSONDecoder().decode(KyroHomeArrangement.self, from: JSONEncoder().encode(decoded))
        check(roundTrip == decoded, "radio visibility persists")
        let future = Data(#"{"hidden":["myTeams","someFutureShelf"]}"#.utf8)
        check((try? JSONDecoder().decode(KyroHomeArrangement.self, from: future))?.hidden == [.myTeams],
              "an unknown shelf name no longer discards the arrangement")
        var reset = decoded
        reset = KyroHomeArrangement()
        check(reset.isDefault && reset.isHidden(.recentRadio), "reset turns radio shelves off again")
    }
}
#endif
