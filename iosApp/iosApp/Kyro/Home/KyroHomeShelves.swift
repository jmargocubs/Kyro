#if os(iOS)
import SwiftUI

/// Additions below the untouched Silo feed. No server sections are mapped,
/// replaced or allowed into these device-local customization preferences.
struct KyroHomeShelves: View {
    @AppStorage(KyroHomePreferences.key) private var stored = Data()
    @State private var sports = KyroHomeSportsModel()
    @State private var favorites = KyroSportsFavoritesStore.shared
    @State private var event: KyroSportsEventSelection?
    @State private var detailStore = KyroSportsEventDetailStore()
    @State private var pendingWatch: KyroSportsGame?
    @State private var isVisible = false
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    private let liveTV = LiveTVService.shared
    private var preferences: KyroHomePreferences { .init(data: stored) }
    private var needsSports: Bool { preferences.enabled.contains { $0 != .recentLiveTV && $0 != .favoriteLiveTV } }

    var body: some View {
        VStack(alignment: .leading, spacing: HomeFeedMetrics.sectionSpacing) {
            HStack {
                Text("Kyro Home").font(.headline)
                Spacer()
                NavigationLink("Sports Hub") {
                    KyroSportsHubView(isSecondaryDestination: true)
                        .environment(\.kyroShellHeader, nil)
                }
                .font(.subheadline)
                NavigationLink { KyroHomeCustomizationView() } label: {
                    Label("Customize", systemImage: "slider.horizontal.3").font(.subheadline)
                }
            }
            .padding(.horizontal, SiloTheme.padding)
            ForEach(preferences.enabled) { shelf in
                if shelf == .recentLiveTV {
                    channelRail(shelf, channels: liveTV.recentlyWatchedChannels)
                } else if shelf == .favoriteLiveTV {
                    channelRail(shelf, channels: liveTV.favoriteChannels)
                } else {
                    let games = KyroHomeSportsSelection.games(sports.games, for: shelf,
                        favorites: favorites.preferences, now: sports.now)
                    if !games.isEmpty {
                        KyroHomeRail(title: shelf.title) {
                            ForEach(games) { game in
                                Button { event = KyroSportsEventSelection(game: game) } label: {
                                    Group {
                                        if game.league == .atp || game.league == .wta {
                                            KyroSportsTennisMatchRow(game: game, showsLeague: true)
                                        } else {
                                            KyroSportsGameRow(game: game, usesCompactLayout: true)
                                        }
                                    }
                                    .frame(width: 310)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .contextMenu { KyroSportsFavoriteActions(game: game) }
                            }
                        }
                    }
                }
            }
            if needsSports && sports.isLoading && sports.games.isEmpty {
                ProgressView("Loading sports…").padding(.horizontal, SiloTheme.padding)
            } else if needsSports && sports.hasFailure {
                HStack {
                    Text("Some sports schedules are unavailable.").font(.footnote)
                    Button("Retry") { Task { await sports.load(force: true) } }
                }
                .padding(.horizontal, SiloTheme.padding)
            }
        }
        .onAppear { isVisible = true; favorites.reload() }
        .onDisappear { isVisible = false }
        .task(id: needsSports) { if needsSports { await sports.load() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && isVisible && needsSports { Task { await sports.load() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .kyroSettingsDidRestore)) { _ in favorites.reload() }
        .sheet(item: $event, onDismiss: {
            guard let game = pendingWatch else { return }
            pendingWatch = nil
            if !KyroUnifiedNavigation.isActive || !KyroGlobalNavigationStore.shared.selectIfTab(.sports) {
                router.navigate(to: .secondaryDestination(.sports))
            }
            liveTV.playSportsEvent(game)
        }) { selection in
            KyroHomeEventPreview(game: selection.game, detailStore: detailStore,
                watch: { pendingWatch = selection.game; event = nil })
        }
    }

    @ViewBuilder
    private func channelRail(_ shelf: KyroHomeShelf, channels: [LiveTVChannel]) -> some View {
        let playable = channels.filter { liveTV.canPlay($0) }
        if !playable.isEmpty {
            KyroHomeRail(title: shelf.title) {
                ForEach(playable) { channel in
                    Button { liveTV.choose(channel, from: .shell) } label: {
                        VStack(spacing: 8) {
                            AsyncImage(url: channel.logoURL) { image in image.resizable().scaledToFit() } placeholder: {
                                Image(systemName: "tv").font(.largeTitle)
                            }
                            .frame(width: 112, height: 64)
                            Text(channel.name).font(.subheadline).lineLimit(2)
                        }
                        .padding(12).frame(width: 160, height: 120)
                        .background(Color.siloSurface, in: RoundedRectangle(cornerRadius: 14))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Play \(channel.name)")
                }
            }
        }
    }
}

/// The independent UniversalHomeRail presentation, adapted to original Silo metrics.
private struct KyroHomeRail<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.bold()).accessibilityAddTraits(.isHeader)
                .padding(.horizontal, SiloTheme.padding)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12, content: content)
                    .padding(.horizontal, SiloTheme.padding)
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

@MainActor @Observable
final class KyroHomeSportsModel {
    private let store = KyroSportsHubStore()
    private(set) var games: [KyroSportsGame] = []
    private(set) var isLoading = false
    private(set) var hasFailure = false
    private(set) var now = Date.now
    private var loadedAt: Date?

    /// Reuses original ESPN/Sleeper stores, caches and error handling. A separate
    /// view model keeps Home's two-day window from changing the user's Hub date/league.
    func load(force: Bool = false) async {
        guard !isLoading, force || loadedAt.map({ Date.now.timeIntervalSince($0) >= 120 }) ?? true else { return }
        isLoading = true
        defer { isLoading = false }
        let clock = Date.now
        var received: [KyroSportsGame] = []
        var failed = false
        for day in [clock, Calendar.current.date(byAdding: .day, value: 1, to: clock) ?? clock] {
            guard !Task.isCancelled else { return }
            store.selectedCategory = .all
            store.selectedDay = day
            if force { await store.refresh() } else { await store.loadIfNeeded() }
            guard !Task.isCancelled else { return }
            received += store.scheduleGames
            failed = failed || !store.unavailableLeagues.isEmpty || store.isShowingStaleData
            switch store.phase {
            case .failed, .offline: failed = true
            default: break
            }
        }
        var seen = Set<KyroGameID>()
        games = received.filter { seen.insert($0.id).inserted }
        now = clock
        hasFailure = failed
        loadedAt = failed ? nil : clock
    }
}
#endif
