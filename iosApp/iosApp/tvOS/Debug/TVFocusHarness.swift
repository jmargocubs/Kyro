#if os(tvOS) && DEBUG
import SwiftUI
import UIKit
import Observation

/// Debug builds only: `-kyroTVFocusHarness livetv|movies|sports` opens a real tvOS root page over
/// offline fixtures, under a stand-in top menu, so hosted UI tests can drive the focus engine with
/// `XCUIRemote` presses. Nothing here exists in Release builds and nothing leaves the device:
/// Live TV loads a fictional playlist and guide through an in-process URL protocol, and Movies
/// reads a fictional catalog staged for a fixture provider.
///
/// The stand-in menu follows the shell's ownership contract (docs/tvos-focus.md): it is one
/// always-enabled focus section whose `.userInitiated` default focus is the selected item, and no
/// page installs a directional handler to reach it. Up from a page's top row reaches it natively.
/// A test that sees focus land on a "Menu …" button without an Up at the page's top row has caught
/// a jump to the top menu.
///
/// `-kyroTVFocusHarnessNoEdgeToEdge` turns `tvEdgeToEdgeScroll` into a no-op, so the same run can
/// compare focus with and without the Build 99 scroll geometry.
///
/// `-kyroTVFocusHarnessDropdowns` gives "Menu Movies" the shell's real dropdown: a mounted
/// `TVCascadeSelector` (one library, one IPTV provider) and a closed `TVForYouDropdown`, both laid
/// over the page's top control row the way the shell's persistent panels are, and both driven by
/// `TVTopMenuPanelFocusPolicy`. `-kyroTVFocusHarnessUngatedPanels` keeps closed dropdowns in the
/// focus graph (the pre-refactor shell) so a run can compare the two.
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
                TVFocusHarnessProbe.shared.start()
                TVScreenLayout.debugDisablesEdgeToEdge =
                    CommandLine.arguments.contains("-kyroTVFocusHarnessNoEdgeToEdge")
                // Stage Movies before the page is presented, so it mounts once with its catalog
                // already stored, the way a real provider page opens. No placeholder takes focus first.
                if requested == .movies {
                    await TVFocusHarnessFixture.stage(.movie, for: TVFocusHarnessFixture.vodProvider)
                } else if requested == .series {
                    await TVFocusHarnessFixture.stage(.series, for: TVFocusHarnessFixture.vodProvider)
                }
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
    case livetv, movies, series, sports
    var id: String { rawValue }
}

private struct TVFocusHarnessShell: View {
    let page: TVFocusHarnessPage

    @State private var service = TVFocusHarnessFixture.makeLiveTVService()
    @State private var vodProvider = TVFocusHarnessFixture.vodProvider
    @State private var contentFocusRequest = 1
    @FocusState private var menuFocus: String?

    private let menuItems = ["Home", "Live TV", "Movies"]
    /// The stand-in's selected item: where Up from any page lands.
    private let selectedMenuItem = "Live TV"
    private var menuOwnsFocus: Bool { menuFocus != nil || panelEntered }

    private let dropdowns = CommandLine.arguments.contains("-kyroTVFocusHarnessDropdowns")
    private let ungatedPanels = CommandLine.arguments.contains("-kyroTVFocusHarnessUngatedPanels")
    private static let moviesPanel = "Movies"
    @State private var openPanel: String?
    @State private var panelEntered = false
    @State private var focusedBarPanel: String?
    @State private var dwellTask: Task<Void, Never>?
    @State private var lastSelection = "none"
    /// Same reachability rule as the shell's bar (`TVTopMenuReachabilityPolicy`).
    @State private var menuHoldsFocus = false
    @State private var menuClaim: String?
    /// The Movies item's frame, so the dropdown is centred under it like the shell's.
    @State private var moviesTabFrame: CGRect = .zero

    var body: some View {
        ZStack(alignment: .top) {
            Color.siloBackground.ignoresSafeArea()
            pageContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .disabled(tvPanelDisablesUnderlyingContent(isOpen: openPanel != nil, isEntered: panelEntered))
            menu
            if dropdowns { dropdownLayer }
        }
        .ignoresSafeArea(edges: [.top, .horizontal])
        .overlay(alignment: .bottomTrailing) { TVFocusHarnessJournalView() }
    }

    // MARK: Dropdowns (same contract as the shell)

    private var dropdownLayer: some View {
        let isOpen = openPanel == Self.moviesPanel
        let eligible = TVTopMenuPanelFocusPolicy.isEligible(
            Self.moviesPanel, focusedBarPanel: focusedBarPanel, openPanel: openPanel, panelEntered: panelEntered)
        let participates = TVTopMenuPanelFocusPolicy.participatesInFocus(
            Self.moviesPanel, focusedBarPanel: focusedBarPanel, openPanel: openPanel, panelEntered: panelEntered)
        return ZStack(alignment: .topLeading) {
            TVCascadeSelector(
                type: .movies,
                libraries: [TVFocusHarnessFixture.library],
                providers: TVCascadeProviderRow.rows(for: [TVFocusHarnessFixture.vodProvider]),
                currentScopeId: TVFocusHarnessFixture.library.id,
                entersPanel: isOpen && panelEntered,
                isEligible: eligible,
                focusEntryGeneration: 0,
                onCommitLibrary: { commitSelection("Library \($0.name)") },
                onCommitSection: { commitSelection($1.title) },
                onCommitProvider: { _ in commitSelection("Provider \(TVFocusHarnessFixture.vodProvider.name)") },
                onClose: closePanelToMenu,
                onPanelFocusChanged: { hasFocus in
                    if TVTopMenuPanelFocusPolicy.panelReportedFocus(hasFocus: hasFocus, panelEntered: panelEntered) == .enter {
                        panelEntered = true
                        openPanel = Self.moviesPanel
                    }
                },
                onExitToContent: { commitSelection("Content") }
            )
            .opacity(isOpen ? 1 : 0)
            .allowsHitTesting(isOpen)
            .disabled(ungatedPanels ? false : !participates)
            // Level-1 column centred under the tab, as the shell places it.
            .padding(.leading, max(SiloTheme.Skyline.safeAreaX,
                                   moviesTabFrame.midX - SiloTheme.Skyline.dropdownWidth / 2))

            // A closed dropdown that is never eligible here: it only has to sit over the row.
            TVForYouDropdown(acceptsFocus: false, focusEntryGeneration: 0, onPanelFocusChanged: { _ in },
                             onClose: {}, onExitToContent: {}, onWatchlist: {}, onFavorites: {},
                             onRecommendations: {})
                .opacity(0)
                .allowsHitTesting(false)
                .disabled(!ungatedPanels)
                .padding(.leading, 900)
        }
        .padding(.top, SiloTheme.Skyline.dropdownTopInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .bottomLeading) {
            Text("Harness selection: \(lastSelection)")
                .font(.system(size: 20))
                .accessibilityIdentifier("harness-selection")
                .padding(40)
        }
        .onExitCommand { if panelEntered { closePanelToMenu() } }
    }

    private func menuFocusChanged(_ item: String?) {
        guard dropdowns, !panelEntered, let item else { return }
        let panel = item == Self.moviesPanel ? Self.moviesPanel : nil
        focusedBarPanel = panel
        if TVTopMenuPanelFocusPolicy.closesStalePreview(openPanel: openPanel, panelEntered: panelEntered,
                                                        focusedElementPanel: panel) {
            openPanel = nil
        }
        dwellTask?.cancel()
        guard let panel else { return }
        dwellTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Int(SiloTheme.Skyline.cascadeDwellMilliseconds)))
            guard !Task.isCancelled, menuFocus == item else { return }
            openPanel = panel
        }
    }

    private func closePanelToMenu() {
        openPanel = nil
        panelEntered = false
        focusedBarPanel = nil
        menuClaim = Self.moviesPanel
        menuFocus = Self.moviesPanel
    }

    private func commitSelection(_ label: String) {
        lastSelection = label
        openPanel = nil
        panelEntered = false
        focusedBarPanel = nil
        contentFocusRequest += 1
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .livetv:
            TVLiveTVRootView(service: service, profileID: "focus-harness",
                             focusRequest: contentFocusRequest, isTopMenuFocused: menuOwnsFocus,
                             onTopMenuFocusRequest: focusMenu)
        case .movies:
            TVXtreamVODView(provider: vodProvider, kind: .movie, focusRequest: contentFocusRequest,
                            isTopMenuFocused: menuOwnsFocus)
        case .series:
            TVXtreamVODView(provider: vodProvider, kind: .series, focusRequest: contentFocusRequest,
                            isTopMenuFocused: menuOwnsFocus)
        case .sports:
            TVSportsHubView(service: service, focusRequest: contentFocusRequest,
                            isTopMenuFocused: menuOwnsFocus)
        }
    }

    private var menu: some View {
        HStack(spacing: 8) {
            ForEach(menuItems, id: \.self) { item in
                Button("Menu \(item)") {
                    contentFocusRequest += 1
                }
                .focused($menuFocus, equals: item)
                .disabled(!TVTopMenuReachabilityPolicy.acceptsFocus(item, selected: selectedMenuItem,
                                                                   barHoldsFocus: menuHoldsFocus,
                                                                   claimTarget: menuClaim))
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                    if item == Self.moviesPanel { moviesTabFrame = frame }
                }
            }
        }
        .frame(height: SiloTheme.Skyline.barHeight)
        .padding(.top, SiloTheme.Skyline.barTopInset)
        .frame(maxWidth: .infinity)
        .defaultFocus($menuFocus, selectedMenuItem, priority: .userInitiated)
        .focusSection()
        .disabled(tvTopMenuIsInert(panelEntered: panelEntered))
        .onChange(of: menuFocus) { _, item in
            if item != nil {
                menuHoldsFocus = true
                menuClaim = nil
            } else {
                recheckMenuHoldsFocus()
            }
            menuFocusChanged(item)
        }
        .onChange(of: panelEntered) { _, entered in if !entered { recheckMenuHoldsFocus() } }
    }

    private func recheckMenuHoldsFocus() {
        DispatchQueue.main.async {
            menuHoldsFocus = TVTopMenuReachabilityPolicy.barHoldsFocus(bindingIsNil: menuFocus == nil,
                                                                       panelEntered: panelEntered)
        }
    }

    /// Back from a page's top level: one explicit claim, no deferral.
    private func focusMenu() {
        menuClaim = selectedMenuItem
        menuFocus = selectedMenuItem
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

    static let library = Library(id: 9101, name: "Harness Movies", type: "movie", sortOrder: 0)

    static var vodProvider: LiveTVProvider {
        var provider = LiveTVProvider(id: UUID(uuidString: "6B1D2C9E-0F4A-4C1B-9A57-3E1F0D0C0A99")!,
                                      name: "Harness VOD", channelCount: 0, lastRefreshed: Date(), kind: .xtream)
        provider.vodEnabled = true
        provider.vodMoviesEnabled = true
        provider.vodSeriesEnabled = true
        return provider
    }

    /// Stages 120 fictional movies for the fixture provider in the shared VOD catalog store.
    static func stage(_ kind: XtreamVODKind, for provider: LiveTVProvider) async {
        let id = provider.id
        let prefix = kind == .movie ? "Harness Movie" : "Harness Series"
        let items = (1...120).map { index in
            XtreamVODItem(providerID: id, kind: kind, remoteID: index, title: "\(prefix) \(index)",
                          category: categories[index % categories.count], poster: nil, fileExtension: "mp4",
                          summary: nil, genre: nil, rating: nil)
        }
        guard let store = try? XtreamVODCatalogStore() else { return }
        await store.remove(providerID: id)
        try? await store.stage(items, generation: "harness")
        try? await store.promote(providerID: id, kind: kind, generation: "harness")
        await store.close()
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

/// A rolling record of the app's focus diagnostics and the engine's focus moves, readable from UI
/// tests through one accessibility element. The hosted job has no way to export the in-app
/// inspector, so a failing test attaches this text instead. Passive: it writes no focus state.
@MainActor @Observable
final class TVFocusHarnessProbe {
    static let shared = TVFocusHarnessProbe()
    private(set) var lines: [String] = []
    private var started = Date()
    @ObservationIgnored private var observer: NSObjectProtocol?

    func start() {
        guard observer == nil else { return }
        started = Date()
        observer = NotificationCenter.default.addObserver(
            forName: UIFocusSystem.didUpdateNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                let context = note.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext
                let next = context?.nextFocusedItem as? NSObject
                let label = (next as? UIAccessibilityIdentification)?.accessibilityIdentifier
                    ?? next?.accessibilityLabel ?? String(describing: type(of: next as Any))
                TVFocusHarnessProbe.shared.append("focus -> \(label ?? "nil")")
            }
        }
    }

    func append(_ line: String) {
        let t = Date().timeIntervalSince(started)
        lines.append(String(format: "%7.2f ", t) + line)
        if lines.count > 120 { lines.removeFirst(lines.count - 120) }
    }
}

private struct TVFocusHarnessJournalView: View {
    private let probe = TVFocusHarnessProbe.shared
    var body: some View {
        Color.clear.frame(width: 2, height: 2)
            .accessibilityElement()
            .accessibilityLabel(probe.lines.suffix(60).joined(separator: "\n"))
            .accessibilityIdentifier("harness-journal")
            .allowsHitTesting(false)
    }
}
#endif
