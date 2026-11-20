#if os(tvOS) && DEBUG
import SwiftUI

/// Debug builds only: `-kyroTVFocusHarness livetv|movies|sports` opens a real tvOS root page over
/// offline fixtures, under a stand-in top menu, so hosted UI tests can drive the focus engine with
/// `XCUIRemote` presses. Nothing here exists in Release builds and nothing leaves the device:
/// Live TV loads a fictional playlist and guide through an in-process URL protocol, and Movies
/// reads a fictional catalog staged for a fixture provider.
///
/// The stand-in menu follows the shell's ownership contract (docs/tvos-focus.md): it is disabled
/// while content owns focus, and only the page's Up boundary hands focus back to it. A test that
/// sees focus land on a "Menu …" button without an Up at the page's top row has caught a jump to
/// the top menu.
///
/// `-kyroTVFocusHarnessNoEdgeToEdge` turns `tvEdgeToEdgeScroll` into a no-op, so the same run can
/// compare focus with and without the Build 99 scroll geometry.
struct TVFocusHarnessModifier: ViewModifier {
    static let argument = "-kyroTVFocusHarness"

    @State private var page: TVFocusHarnessPage?

    func body(content: Content) -> some View {
        content
            .fullScreenCover(item: $page) { page in
                TVFocusHarnessShell(page: page)
            }
            .task {
                guard let raw = Self.value(after: Self.argument),
                      let requested = TVFocusHarnessPage(rawValue: raw) else { return }
                TVScreenLayout.debugDisablesEdgeToEdge =
                    CommandLine.arguments.contains("-kyroTVFocusHarnessNoEdgeToEdge")
                // Let the startup splash lift first; the cover must own focus, not the splash.
                try? await Task.sleep(for: .seconds(1.5))
                page = requested
            }
    }

    static func value(after argument: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: argument), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}

enum TVFocusHarnessPage: String, Identifiable {
    case livetv, movies, sports
    var id: String { rawValue }
}

private struct TVFocusHarnessShell: View {
    let page: TVFocusHarnessPage

    @State private var service = TVFocusHarnessFixture.makeLiveTVService()
    @State private var vodProvider = TVFocusHarnessFixture.stageMovies()
    @State private var contentFocusRequest = 1
    @State private var menuSuppressed = true
    @FocusState private var menuFocus: String?

    private let menuItems = ["Home", "Live TV", "Movies"]

    var body: some View {
        ZStack(alignment: .top) {
            Color.siloBackground.ignoresSafeArea()
            pageContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            menu
        }
        .ignoresSafeArea(edges: [.top, .horizontal])
        .onChange(of: menuFocus) { _, focused in
            // Focus left the menu by a native move into the page: disable the menu again.
            if focused == nil, !menuSuppressed { menuSuppressed = true }
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .livetv:
            TVLiveTVRootView(service: service, profileID: "focus-harness",
                             focusRequest: contentFocusRequest, isTopMenuFocused: !menuSuppressed,
                             onTopMenuFocusRequest: focusMenu)
        case .movies:
            TVXtreamVODView(provider: vodProvider, kind: .movie, focusRequest: contentFocusRequest,
                            isTopMenuFocused: !menuSuppressed, onMoveUp: focusMenu)
        case .sports:
            TVSportsHubView(service: service, focusRequest: contentFocusRequest,
                            isTopMenuFocused: !menuSuppressed, onTopMenuFocusRequest: focusMenu)
        }
    }

    private var menu: some View {
        HStack(spacing: 8) {
            ForEach(menuItems, id: \.self) { item in
                Button("Menu \(item)") {
                    menuSuppressed = true
                    contentFocusRequest += 1
                }
                .focused($menuFocus, equals: item)
            }
        }
        .frame(height: SiloTheme.Skyline.barHeight)
        .padding(.top, SiloTheme.Skyline.barTopInset)
        .frame(maxWidth: .infinity)
        .focusSection()
        .disabled(menuSuppressed)
        .onMoveCommand { direction in
            guard direction == .down else { return }
            menuSuppressed = true
            contentFocusRequest += 1
        }
    }

    private func focusMenu() {
        menuSuppressed = false
        DispatchQueue.main.async { menuFocus = "Live TV" }
    }
}

/// Offline fixtures for the harness. Fictional names only.
enum TVFocusHarnessFixture {
    static let host = "focus-harness.kyro.invalid"
    static let categories = ["Sports", "News", "Movies", "Documentary", "Entertainment", "Kids", "Music",
                             "Weather", "Lifestyle", "Local", "Business", "Comedy", "History", "Science"]

    @MainActor
    static func makeLiveTVService() -> LiveTVService {
        let suite = "kyro.debug.tvFocusHarness"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KyroTVFocusHarness", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TVFocusHarnessURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let epg = EPGService(cache: EPGCacheStore(directory: directory.appendingPathComponent("guide", isDirectory: true)),
                             loader: URLSessionEPGFeedLoader(session: session))
        let service = LiveTVService(defaults: defaults, secretStore: TVFocusHarnessSecretStore(), session: session,
                                    epg: epg,
                                    channelSnapshotStore: LiveTVChannelSnapshotStore(
                                        directory: directory.appendingPathComponent("channels", isDirectory: true)))
        _ = try? service.saveConfiguration(name: "Harness TV", playlistURL: "https://\(host)/playlist.m3u",
                                           xmltvURL: "https://\(host)/guide.xml")
        return service
    }

    /// Stages 120 fictional movies for a fixture provider in the shared VOD catalog store.
    static func stageMovies() -> LiveTVProvider {
        let id = UUID(uuidString: "6B1D2C9E-0F4A-4C1B-9A57-3E1F0D0C0A99")!
        var provider = LiveTVProvider(id: id, name: "Harness VOD", channelCount: 0, lastRefreshed: Date(), kind: .xtream)
        provider.vodEnabled = true
        provider.vodMoviesEnabled = true
        let items = (1...120).map { index in
            XtreamVODItem(providerID: id, kind: .movie, remoteID: index, title: "Harness Movie \(index)",
                          category: categories[index % categories.count], poster: nil, fileExtension: "mp4",
                          summary: nil, genre: nil, rating: nil)
        }
        if let store = try? XtreamVODCatalogStore() {
            store.remove(providerID: id)
            try? store.stage(items, generation: "harness")
            try? store.promote(providerID: id, kind: .movie, generation: "harness")
        }
        return provider
    }

    static var playlist: String {
        var lines = ["#EXTM3U"]
        for index in 0..<84 {
            let category = categories[index % categories.count]
            lines.append(#"#EXTINF:-1 tvg-id="harness.\#(index)" group-title="\#(category)",Harness \#(category) \#(index)"#)
            lines.append("https://\(host)/stream/\(index).m3u8")
        }
        return lines.joined(separator: "\n")
    }

    static func guide(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss '+0000'"
        let start = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 1800).rounded(.down) * 1800 - 3600)
        var xml = "<tv>"
        for index in 0..<84 { xml += #"<channel id="harness.\#(index)"><display-name>Harness \#(index)</display-name></channel>"# }
        for index in 0..<84 {
            for slot in 0..<12 {
                let begin = start.addingTimeInterval(Double(slot) * 1800)
                xml += #"<programme channel="harness.\#(index)" start="\#(formatter.string(from: begin))" "#
                    + #"stop="\#(formatter.string(from: begin.addingTimeInterval(1800)))">"#
                    + "<title>Programme \(slot + 1)</title></programme>"
            }
        }
        return xml + "</tv>"
    }
}

private final class TVFocusHarnessSecretStore: LiveTVSecretStore {
    private var values: [String: String] = [:]
    func read(account: String) -> String? { values[account] }
    func save(_ value: String, account: String) -> Bool { values[account] = value; return true }
    func remove(account: String) -> Bool { values[account] = nil; return true }
}

private final class TVFocusHarnessURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == TVFocusHarnessFixture.host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let body: String
        switch url.lastPathComponent {
        case "playlist.m3u": body = TVFocusHarnessFixture.playlist
        case "guide.xml": body = TVFocusHarnessFixture.guide()
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        let data = Data(body.utf8)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": "\(data.count)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
#endif
