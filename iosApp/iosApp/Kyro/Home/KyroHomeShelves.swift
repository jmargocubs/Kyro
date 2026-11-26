#if os(iOS)
import SwiftUI
import os

// Build 121: Kyro's six shelves sit among Silo's own Home sections
// (`KyroHomeArrangement`) instead of after the whole feed. HomeView owns one
// `KyroHomeShelfHost`; each shelf row reads it from the environment, and the
// host modifier runs the loads and the event sheet once for the page.

/// Why a shelf is or isn't on Home, with the counts behind it.
struct KyroHomeShelfDiagnostic: Equatable, Identifiable {
    enum Status: Equatable {
        case shown
        case hiddenByPreference
        /// Nothing to show yet: no favorites, no history, no provider.
        case noSource(String)
        case loading(String)
        /// Sources exist but none resolved (unmatched IDs, catalog not ready).
        case unresolved(String)
        case failed(String)
        /// Sources resolved, but nothing falls in the shelf's window.
        case emptyWindow(String)
        /// My Teams or My Leagues is on Home with its quick-add card. Games may be absent.
        case quickAdd(String)
    }

    let shelf: KyroHomeShelf
    let status: Status
    /// Favorites, history entries, or schedule events the shelf draws from.
    let sourceCount: Int
    /// Rows the shelf can show now.
    let resolvedCount: Int

    var id: KyroHomeShelf { shelf }

    var summary: String {
        let counts = "source \(sourceCount), shown \(resolvedCount)"
        switch status {
        case .shown: return "Shown · \(counts)"
        case .hiddenByPreference: return "Hidden in Customize Home"
        case .noSource(let reason): return "Hidden · \(reason)"
        case .loading(let what): return "Loading · \(what)"
        case .unresolved(let reason): return "Hidden · \(reason) · \(counts)"
        case .failed(let reason): return "Hidden · \(reason)"
        case .emptyWindow(let reason): return "Hidden · \(reason) · \(counts)"
        case .quickAdd(let reason): return "Shown · \(reason) · \(counts)"
        }
    }
}

@MainActor @Observable
final class KyroHomeShelfHost {
    /// One host for Home and Settings › Customize Home, so both edit the same
    /// arrangement and Home updates as soon as it changes.
    static let shared = KyroHomeShelfHost()

    let today = KyroHomeSportsModel()
    let followed = KyroHomeFollowedSportsModel()
    let favorites = KyroSportsFavoritesStore.shared
    @ObservationIgnored let liveTV = LiveTVService.shared
    private(set) var arrangement: KyroHomeArrangement
    private(set) var scope: String?
    /// Event details sheet, and the event to play once it closes.
    var event: KyroSportsEventSelection?
    /// Silo's sections from the latest Home load, for Customize Home opened
    /// from Settings.
    var siloSections: [KyroHomeSiloSection] = []
    private(set) var siloSectionsScope: String?
    var pendingWatch: KyroSportsGame?
    /// The selected provider's cached channels are being read from disk.
    private(set) var isRestoringLiveTV = false
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var loggedSummaries: [KyroHomeShelf: String] = [:]
    @ObservationIgnored private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.cubbiestream.kyro", category: "KyroHome")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let scope = Self.currentScope()
        self.scope = scope
        arrangement = KyroHomeArrangementStore.load(scope: scope, from: defaults)
    }

    /// Server, account and profile: each keeps its own arrangement.
    static func currentScope() -> String? {
        guard let identity = HTTPRequestIdentity.activeProfile() else { return nil }
        return [identity.serverId, identity.localAccountId ?? "", identity.profileId].joined(separator: ".")
    }

    func refreshScope() {
        let current = Self.currentScope()
        guard current != scope else { return }
        scope = current
        arrangement = KyroHomeArrangementStore.load(scope: current, from: defaults)
        siloSections = []
        siloSectionsScope = nil
    }

    func setSiloSections(_ sections: [KyroHomeSiloSection], scope: String?) {
        guard scope == self.scope else { return }
        siloSections = sections
        siloSectionsScope = scope
    }

    /// Re-reads the stored arrangement (after a settings restore).
    func reloadArrangement() {
        arrangement = KyroHomeArrangementStore.load(scope: scope, from: defaults)
    }

    func update(_ change: (inout KyroHomeArrangement) -> Void) {
        var updated = arrangement
        change(&updated)
        guard updated != arrangement else { return }
        arrangement = updated
        KyroHomeArrangementStore.save(updated, scope: scope, to: defaults)
    }

    func resetArrangement() {
        arrangement = KyroHomeArrangement()
        KyroHomeArrangementStore.save(arrangement, scope: scope, to: defaults)
    }

    private func isEnabled(_ shelf: KyroHomeShelf) -> Bool { !arrangement.hidden.contains(shelf) }
    var needsTodaySports: Bool { isEnabled(.sportsToday) || isEnabled(.upcomingSports) }
    var needsFollowedSports: Bool {
        (isEnabled(.myTeams) || isEnabled(.myLeagues)) && !favorites.preferences.relevantLeagues.isEmpty
    }
    var needsLiveTV: Bool { isEnabled(.recentLiveTV) || isEnabled(.favoriteLiveTV) }

    // MARK: Content

    func games(for shelf: KyroHomeShelf) -> [KyroSportsGame] {
        let source = shelf.isFavoriteSports ? followed.games : today.games
        return KyroHomeSportsSelection.games(source, for: shelf, favorites: favorites.preferences, now: .now)
    }

    /// Home's channel rails, from Live TV's provider-scoped SQLite preview:
    /// favorites as stored, recents most recent first.
    func channels(for shelf: KyroHomeShelf) -> [LiveTVChannel] {
        switch shelf {
        case .favoriteLiveTV:
            return liveTV.favoriteChannels.filter { liveTV.canPlay($0) }
        case .recentLiveTV:
            let order = Dictionary(uniqueKeysWithValues: recentRecords.enumerated().map { ($1.channelID, $0) })
            return liveTV.recentlyWatchedChannels
                .filter { liveTV.canPlay($0) }
                .sorted { (order[$0.id] ?? .max) < (order[$1.id] ?? .max) }
        default:
            return []
        }
    }

    private var recentRecords: [LiveTVRecentChannel] {
        guard let provider = liveTV.selectedProviderID else { return [] }
        return liveTV.recentlyWatchedRecords.filter { $0.providerID == provider }
    }

    private var favoriteIDsForProvider: Int {
        guard let provider = liveTV.selectedProviderID else { return 0 }
        let prefix = provider.uuidString + ":"
        return liveTV.favoriteChannelIDs.filter { $0.hasPrefix(prefix) }.count
    }

    // MARK: Loading

    /// Reads the selected Live TV provider's cached catalog from disk (no
    /// network), which is what builds the Home channel rails. Before Build
    /// 121 only the Live TV page did this, so Home's channel shelves stayed
    /// empty after launch until Live TV was opened.
    func restoreLiveTV() async {
        guard needsLiveTV, let provider = liveTV.selectedProviderID, !liveTV.hasCatalog(for: provider) else { return }
        isRestoringLiveTV = true
        defer { isRestoringLiveTV = false }
        await liveTV.restoreCachedState(for: provider)
    }

    func loadSports(force: Bool = false) async {
        if needsTodaySports { await today.load(force: force) }
        if needsFollowedSports {
            await followed.load(leagues: favorites.preferences.relevantLeagues, force: force)
        }
    }

    // MARK: Diagnostics

    func diagnostics() -> [KyroHomeShelfDiagnostic] {
        KyroHomeShelf.allCases.map(diagnostic(for:))
    }

    func diagnostic(for shelf: KyroHomeShelf) -> KyroHomeShelfDiagnostic {
        guard isEnabled(shelf) else {
            return .init(shelf: shelf, status: .hiddenByPreference, sourceCount: 0, resolvedCount: 0)
        }
        if shelf.isLiveTV { return liveTVDiagnostic(for: shelf) }
        return sportsDiagnostic(for: shelf)
    }

    private func liveTVDiagnostic(for shelf: KyroHomeShelf) -> KyroHomeShelfDiagnostic {
        let source = shelf == .favoriteLiveTV ? favoriteIDsForProvider : recentRecords.count
        let resolved = channels(for: shelf).count
        func make(_ status: KyroHomeShelfDiagnostic.Status) -> KyroHomeShelfDiagnostic {
            .init(shelf: shelf, status: status, sourceCount: source, resolvedCount: resolved)
        }
        if resolved > 0 { return make(.shown) }
        guard let provider = liveTV.selectedProviderID else { return make(.noSource("no Live TV provider selected")) }
        if source == 0 {
            return make(.noSource(shelf == .favoriteLiveTV ? "no favorite channels for this provider"
                                                            : "no channels watched on this provider yet"))
        }
        if isRestoringLiveTV { return make(.loading("reading the provider's saved channels")) }
        if !liveTV.hasCatalog(for: provider) { return make(.unresolved("provider channels not loaded")) }
        return make(.unresolved("saved channels not found in the current playlist"))
    }

    private func sportsDiagnostic(for shelf: KyroHomeShelf) -> KyroHomeShelfDiagnostic {
        let model: KyroHomeSportsSource = shelf.isFavoriteSports ? followed : today
        let resolved = games(for: shelf).count
        func make(_ status: KyroHomeShelfDiagnostic.Status) -> KyroHomeShelfDiagnostic {
            .init(shelf: shelf, status: status, sourceCount: model.games.count, resolvedCount: resolved)
        }
        if resolved > 0 { return make(.shown) }
        if shelf.isFavoriteSports {
            let reason: String
            if shelf == .myTeams, favorites.preferences.teams.isEmpty {
                reason = "quick add, no favorite teams yet"
            } else if shelf == .myLeagues, favorites.preferences.leagues.isEmpty {
                reason = "quick add, no favorite leagues yet"
            } else if model.isLoading && model.games.isEmpty {
                reason = "quick add, loading sports schedules"
            } else if !model.failedLeagues.isEmpty && model.games.isEmpty {
                reason = "quick add, schedules unavailable: \(model.failedLeagues.map(\.displayName).joined(separator: ", "))"
            } else if !model.hasLoaded {
                reason = "quick add, waiting for the first schedule load"
            } else if shelf == .myTeams {
                reason = "quick add, no live or upcoming games for favorite teams"
            } else {
                reason = "quick add, no live or upcoming events in favorite leagues"
            }
            return make(.quickAdd(reason))
        }
        if model.isLoading && model.games.isEmpty { return make(.loading("sports schedules")) }
        if !model.failedLeagues.isEmpty && model.games.isEmpty {
            return make(.failed("schedules unavailable: \(model.failedLeagues.map(\.displayName).joined(separator: ", "))"))
        }
        if !model.hasLoaded { return make(.loading("waiting for the first schedule load")) }
        switch shelf {
        case .upcomingSports: return make(.emptyWindow("nothing scheduled later today or tomorrow"))
        default: return make(.emptyWindow("no events today"))
        }
    }

    /// One log line per shelf whenever its summary changes.
    func logDiagnostics() {
        for item in diagnostics() where loggedSummaries[item.shelf] != item.summary {
            loggedSummaries[item.shelf] = item.summary
            logger.info("\(item.shelf.rawValue, privacy: .public): \(item.summary, privacy: .public)")
        }
    }
}

/// What Home's two sports models share for diagnostics.
@MainActor
protocol KyroHomeSportsSource: AnyObject {
    var games: [KyroSportsGame] { get }
    var isLoading: Bool { get }
    var failedLeagues: [KyroSportLeague] { get }
    var hasLoaded: Bool { get }
}

/// Sports Today and Upcoming Sports: All Sports (soccer is its own filter in
/// the Hub) for today and tomorrow. Reuses the original ESPN/Sleeper stores,
/// caches and error handling; a separate store keeps Home's day changes from
/// moving the user's Hub date or sport.
@MainActor @Observable
final class KyroHomeSportsModel: KyroHomeSportsSource {
    private let store = KyroSportsHubStore()
    private(set) var games: [KyroSportsGame] = []
    private(set) var isLoading = false
    private(set) var failedLeagues: [KyroSportLeague] = []
    private(set) var hasLoaded = false
    private var loadedAt: Date?

    func load(force: Bool = false) async {
        guard !isLoading, force || loadedAt.map({ Date.now.timeIntervalSince($0) >= 120 }) ?? true else { return }
        isLoading = true
        defer { isLoading = false }
        let clock = Date.now
        var received: [KyroSportsGame] = []
        var failed = Set<KyroSportLeague>()
        for day in [clock, Calendar.current.date(byAdding: .day, value: 1, to: clock) ?? clock] {
            guard !Task.isCancelled else { return }
            store.selectedCategory = .all
            store.selectedDay = day
            if force { await store.refresh() } else { await store.loadIfNeeded() }
            guard !Task.isCancelled else { return }
            received += store.scheduleGames
            failed.formUnion(store.unavailableLeagues)
        }
        var seen = Set<KyroGameID>()
        games = received.filter { seen.insert($0.id).inserted }
        failedLeagues = KyroSportLeague.allCases.filter(failed.contains)
        hasLoaded = true
        loadedAt = failed.isEmpty ? clock : nil
    }
}

/// My Teams and My Leagues: each relevant league's own provider window (the
/// same window the Hub loads for that sport, e.g. the NFL week), so a
/// favorite's next game shows even when it isn't today or tomorrow. Only the
/// favorites' leagues are fetched.
@MainActor @Observable
final class KyroHomeFollowedSportsModel: KyroHomeSportsSource {
    private let store = KyroSportsHubStore()
    private(set) var games: [KyroSportsGame] = []
    private(set) var isLoading = false
    private(set) var failedLeagues: [KyroSportLeague] = []
    private(set) var hasLoaded = false
    private var loaded: (leagues: [KyroSportLeague], at: Date)?

    func load(leagues: [KyroSportLeague], force: Bool = false) async {
        guard !isLoading else { return }
        if !force, let loaded, loaded.leagues == leagues, Date.now.timeIntervalSince(loaded.at) < 120 { return }
        isLoading = true
        defer { isLoading = false }
        var received: [KyroSportsGame] = []
        var failed: [KyroSportLeague] = []
        for league in leagues {
            guard !Task.isCancelled else { return }
            guard let category = KyroSportsCategory(rawValue: league.rawValue) else { continue }
            store.selectedCategory = category
            store.selectedDay = Calendar.current.startOfDay(for: .now)
            if force { await store.refresh() } else { await store.loadIfNeeded() }
            guard !Task.isCancelled else { return }
            received += store.loadedGames(for: league)
            if store.hasFailure(for: league) { failed.append(league) }
        }
        var seen = Set<KyroGameID>()
        games = received.filter { seen.insert($0.id).inserted }
        failedLeagues = failed
        hasLoaded = true
        loaded = failed.isEmpty ? (leagues, .now) : nil
    }
}

// MARK: - Page wiring

extension EnvironmentValues {
    @Entry var kyroHomeShelfHost: KyroHomeShelfHost?
}

/// Runs the shelves' loads and owns the event sheet for the Home page.
struct KyroHomeShelfHostModifier: ViewModifier {
    let host: KyroHomeShelfHost
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @State private var detailStore = KyroSportsEventDetailStore()
    @State private var isVisible = false

    private var loadKey: String {
        let favorites = host.favorites.preferences
        return [host.scope ?? "", host.needsTodaySports.description, host.needsFollowedSports.description,
                host.needsLiveTV.description, favorites.relevantLeagues.map(\.rawValue).joined(separator: ","),
                host.liveTV.selectedProviderID?.uuidString ?? ""].joined(separator: "|")
    }

    func body(content: Content) -> some View {
        content
            .environment(\.kyroHomeShelfHost, host)
            .onAppear {
                isVisible = true
                host.refreshScope()
                host.favorites.reload()
            }
            .onDisappear { isVisible = false }
            .task(id: loadKey) {
                await host.restoreLiveTV()
                await host.loadSports()
                host.logDiagnostics()
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active, isVisible else { return }
                host.favorites.reload()
                Task {
                    await host.loadSports()
                    host.logDiagnostics()
                }
            }
            .onChange(of: host.liveTV.channelCatalogRevision) { _, _ in host.logDiagnostics() }
            .onReceive(NotificationCenter.default.publisher(for: .kyroSettingsDidRestore)) { _ in
                host.favorites.reload()
                host.reloadArrangement()
            }
            .sheet(item: Binding(get: { host.event }, set: { host.event = $0 }), onDismiss: {
                guard let game = host.pendingWatch else { return }
                host.pendingWatch = nil
                if !KyroUnifiedNavigation.isActive || !KyroGlobalNavigationStore.shared.selectIfTab(.sports) {
                    router.navigate(to: .secondaryDestination(.sports))
                }
                host.liveTV.playSportsEvent(game)
            }) { selection in
                KyroHomeEventPreview(game: selection.game, detailStore: detailStore,
                    watch: { host.pendingWatch = selection.game; host.event = nil })
            }
    }
}

/// One Kyro shelf in the Home feed. Draws nothing when the shelf has nothing
/// to show, except My Teams and My Leagues, which keep their quick-add card.
struct KyroHomeShelfRow: View {
    let shelf: KyroHomeShelf
    @Environment(\.kyroHomeShelfHost) private var host
    @State private var quickAdd: KyroHomeShelf?

    var body: some View {
        if let host {
            if shelf.isLiveTV {
                channelRail(host.channels(for: shelf), host: host)
            } else {
                gameRail(host.games(for: shelf), host: host)
            }
        }
    }

    @ViewBuilder
    private func gameRail(_ games: [KyroSportsGame], host: KyroHomeShelfHost) -> some View {
        let showQuickAdd = KyroHomeQuickAdd.isAvailable(for: shelf, hidden: host.arrangement.hidden)
        if KyroHomeQuickAdd.drawsRail(gameCount: games.count, shelf: shelf, hidden: host.arrangement.hidden) {
            KyroHomeRail(title: shelf.title, sizing: .tallestCard) {
                ForEach(games) { game in
                    Button { host.event = KyroSportsEventSelection(game: game) } label: {
                        Group {
                            if game.league == .atp || game.league == .wta {
                                KyroSportsTennisMatchRow(game: game, showsLeague: true)
                            } else {
                                KyroSportsGameRow(game: game, usesCompactLayout: true)
                            }
                        }
                        .frame(width: KyroHomeSportsRailLayout.cardWidth)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu { KyroSportsFavoriteActions(game: game) }
                }
                if showQuickAdd {
                    Button { quickAdd = shelf } label: {
                        KyroHomeQuickAddCard(title: KyroHomeQuickAdd.title(for: shelf))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("kyroHomeQuickAdd-\(shelf.rawValue)")
                }
            }
            .sheet(item: $quickAdd) { selection in
                KyroHomeFavoritePicker(shelf: selection, host: host)
            }
        }
    }

    @ViewBuilder
    private func channelRail(_ channels: [LiveTVChannel], host: KyroHomeShelfHost) -> some View {
        if !channels.isEmpty {
            KyroHomeRail(title: shelf.title, sizing: .lazy) {
                ForEach(channels) { channel in
                    Button { host.liveTV.choose(channel, from: .shell) } label: {
                        VStack(spacing: 8) {
                            AsyncImage(url: channel.logoURL) { image in image.resizable().scaledToFit() } placeholder: {
                                Image(systemName: "tv").font(.largeTitle).foregroundStyle(KyroTheme.textSecondary)
                            }
                            .frame(width: 112, height: 64)
                            Text(channel.name).font(.subheadline).lineLimit(2)
                        }
                        .padding(12).frame(width: 160, height: 120)
                        .background(Color.siloSurfaceElevated, in: RoundedRectangle(cornerRadius: 14))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Play \(channel.name)")
                }
            }
        }
    }
}

/// Customize Home, near the top of the page, in the Crimson Noir accent.
struct KyroHomeCustomizeButton: View {
    @Environment(\.kyroHomeShelfHost) private var host

    var body: some View {
        if let host {
            HStack {
                Spacer()
                NavigationLink {
                    KyroHomeCustomizationView(host: host)
                } label: {
                    Label("Customize Home", systemImage: "slider.horizontal.3")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(KyroTheme.accentInk)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(KyroTheme.selectedFill, in: Capsule())
                        .overlay(Capsule().strokeBorder(KyroTheme.selectedBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityHint("Show, hide and move Silo and Kyro Home shelves")
            }
            .padding(.horizontal, SiloTheme.padding)
        }
    }
}

/// The plus card at the end of My Teams or My Leagues. Same width, corner
/// radius and Crimson Noir card fill as the event cards beside it.
private struct KyroHomeQuickAddCard: View {
    let title: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "plus")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(KyroTheme.accentInk)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
                .foregroundStyle(KyroTheme.textPrimary)
        }
        // Fills the shelf's tallest event card; never shorter than its own content.
        .frame(width: KyroHomeSportsRailLayout.cardWidth)
        .frame(minHeight: KyroHomeSportsRailLayout.quickAddMinimumHeight, maxHeight: .infinity)
        .kyroSportsCardChrome(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityLabel(title)
    }
}

/// Build 126: Home sports shelf metrics.
///
/// Before Build 126 every shelf used a `LazyHStack` inside a horizontal
/// `ScrollView`. A lazy stack takes its height from the cards it has built
/// when it is first laid out, which is the first card or two; the scroll view
/// then clips everything to that height. When the first card was a short
/// scheduled NFL card (about 106 pt), a live NBA card with its quarter header
/// row, a tennis card with set columns and the 148 pt Add Team or Add League
/// card were all cut off at the bottom.
///
/// Sports shelves now use an eager `HStack` sized to its tallest card
/// (`fixedSize` vertically). Shelves hold at most
/// `KyroHomeSportsSelection.maximumCards` events plus one quick-add card, so
/// building them all is bounded.
enum KyroHomeSportsRailLayout {
    static let cardWidth: CGFloat = 310
    static let quickAddMinimumHeight: CGFloat = 148
    /// Most cards a sports shelf builds at once: every event plus the quick-add card.
    static var maximumCards: Int { KyroHomeSportsSelection.maximumCards + 1 }
}

/// The independent UniversalHomeRail presentation, adapted to original Silo metrics.
private struct KyroHomeRail<Content: View>: View {
    enum Sizing {
        /// Channel rails: equal-height tiles, so a lazy stack measures them correctly.
        case lazy
        /// Sports rails: cards differ in height, so every card is measured and
        /// the rail is as tall as the tallest one.
        case tallestCard
    }

    let title: String
    let sizing: Sizing
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.bold()).accessibilityAddTraits(.isHeader)
                .padding(.horizontal, SiloTheme.padding)
            ScrollView(.horizontal, showsIndicators: false) {
                switch sizing {
                case .lazy:
                    LazyHStack(alignment: .top, spacing: 12, content: content)
                        .padding(.horizontal, SiloTheme.padding)
                case .tallestCard:
                    HStack(alignment: .top, spacing: 12, content: content)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, SiloTheme.padding)
                        // Room for card borders at the bottom edge of the scroll view's clip.
                        .padding(.vertical, 1)
                }
            }
        }
    }
}

/// The original event details and playback policy. Matching is event-specific;
/// browsing Home never replaces the Sports Hub's shared Live Now evidence.
private struct KyroHomeEventPreview: View {
    let game: KyroSportsGame
    let detailStore: KyroSportsEventDetailStore
    let watch: () -> Void
    @State private var canWatch = false
    private let service = LiveTVService.shared
    var body: some View {
        KyroSportsEventPreview(game: game, service: service, canWatch: canWatch,
                              watch: watch, detailStore: detailStore)
            .task(id: "\(game.id):\(service.selectedProviderID?.uuidString ?? "none"):\(service.channelCatalogRevision)") {
                canWatch = false
                guard KyroSportsPlaybackEligibility.isInProgress(game) else { return }
                let matches = await service.sportsStreamMatches(for: game)
                guard !Task.isCancelled else { return }
                canWatch = matches.matches.contains(where: \.isAutoPlayEligible)
            }
    }
}
#endif
