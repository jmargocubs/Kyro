#if os(tvOS)
import SwiftUI
import NukeUI

/// One store pair per process, so leaving and re-entering Sports reuses the warm cache instead
/// of requesting the same days again.
@MainActor
enum TVSportsStores {
    static let hub = KyroSportsHubStore(preferences: .standard)
    static let details = KyroSportsEventDetailStore()
}

/// Kyro's native Apple TV Sports Hub. Schedules, scores, provider fallback and caching come from
/// the shared `KyroSportsHubStore`; stream matching and the one playback session come from
/// `LiveTVService`. This view only supplies a TV focus graph.
struct TVSportsHubView: View {
    @Bindable var service: LiveTVService
    let focusRequest: Int
    let isTopMenuFocused: Bool

    @State private var store = TVSportsStores.hub
    @State private var mode: TVSportsMode = .live
    @State private var detailGame: KyroSportsGame?
    @State private var focusMemory = TVSportsFocusMemory()
    @State private var lastPlayedGame: KyroSportsGame?
    @FocusState private var focus: Focus?

    fileprivate enum Focus: Hashable {
        case category(KyroSportsCategory)
        case mode(TVSportsMode)
        case day(Date)
        case game(KyroGameID)
        case refresh
        case bannerAction
    }

    /// Adaptive (Build 99): three cards across 1080p using the full width (Build 98 capped them at
    /// 520 pt, leaving about 130 pt unused), two on a narrower viewport.
    private let columns = [GridItem(.adaptive(minimum: TVSportsLayout.minimumCardWidth),
                                    spacing: TVSportsLayout.columnSpacing)]

    private var games: [KyroSportsGame] {
        TVSportsFeed.games(mode: mode, live: store.liveGames, schedule: store.scheduleGames)
    }

    private var days: [Date] {
        TVSportsFeed.days(mode: mode, browseDays: store.browseDays, now: store.clockNow, calendar: store.browseCalendar)
    }

    private var banner: TVSportsPlaybackBanner? {
        TVSportsPlaybackBanner.make(for: service.sportsPlayback.phase)
    }

    private var playerIsPresented: Bool { service.presentation.phase != .idle }

    var body: some View {
        ZStack {
            TVKyroAmbientBackdrop()
            if let game = detailGame {
                TVSportsEventDetailView(game: game, service: service, close: closeDetails)
            } else {
                feed
            }
        }
        // The one shared player cover. A verified Sports stream opens here, over the feed, and
        // Back returns to the same card.
        .modifier(LiveTVChannelCover(service: service, presenter: .shell, isEnabled: true))
        .task(id: LoadKey(category: store.selectedCategory, day: store.selectedDay)) {
            await store.loadIfNeeded()
        }
        .task(id: store.selectedCategory) { await pollScores() }
        .task(id: focusRequest) { claimEntryFocus() }
        .onAppear { service.prewarmSportsMatching() }
        .tvObserveFocus("Sports", value: focus)
        .onChange(of: detailGame == nil) { _, value in TVFocusDiagnostics.value("state", "Sports", "detailClosed", value) }
        .onChange(of: mode) { _, value in TVFocusDiagnostics.value("state", "Sports", "mode", value) }
    }

    private struct LoadKey: Hashable {
        let category: KyroSportsCategory
        let day: Date
    }

    // MARK: Feed

    private var feed: some View {
        VStack(alignment: .leading, spacing: TVScreenLayout.sectionSpacing) {
            header
            categoryRow
            modeRow
            if mode.usesDayStrip { dayRow }
            if let banner { bannerView(banner) }
            content
        }
        .padding(.horizontal, TVScreenLayout.pageHorizontalInset)
        .padding(.top, TVTopMenuLayout.contentTopInset)
        // Native entry: Down from the top menu lands on the selected mode chip,
        // the same target the shell's selection hand-off claims, instead of
        // whatever control sits under the focused tab. The feed's only
        // outside neighbour is the top menu, so this applies to that entry.
        .defaultFocus($focus, .mode(mode), priority: .userInitiated)
        .focusSection()
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Sports")
                .font(.system(size: 52, weight: .heavy))
                .foregroundStyle(Color.siloOnSurface)
            Spacer()
            if let notice = store.refreshNotice {
                Text(notice.title)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.siloSecondaryText)
                    .lineLimit(1)
            }
            // Never disabled: a disabled button loses focus, and polling runs a
            // refresh every 10-60 s. `refresh()` ignores repeat presses. Up
            // reaches the top menu natively from anywhere in the header.
            Button {
                Task { await store.refresh() }
            } label: {
                Label(store.isRefreshing ? "Refreshing" : "Refresh", systemImage: "arrow.clockwise")
                    .opacity(store.isRefreshing ? 0.6 : 1)
            }
            .accessibilityLabel("Refresh")
            .accessibilityValue(store.isRefreshing ? "Refreshing" : "")
            .buttonStyle(TVKyroChipStyle())
            .focused($focus, equals: .refresh)
        }
    }

    private var categoryRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 18) {
                ForEach(KyroSportsCategory.filterOrder) { category in
                    chip(category.shortName, systemImage: category.symbolName,
                         selected: store.selectedCategory == category) {
                        store.selectCategory(category)
                    }
                    .focused($focus, equals: .category(category))
                }
            }
            .padding(.vertical, 8)
        }
        .focusSection()
    }

    private var modeRow: some View {
        HStack(spacing: 18) {
            ForEach(TVSportsMode.allCases) { option in
                chip(option.title, systemImage: nil, selected: mode == option) { select(mode: option) }
                    .focused($focus, equals: .mode(option))
            }
            if mode == .live, !store.liveGames.isEmpty {
                Text("Select to watch. Press and hold for details.")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.siloSecondaryText)
                    .padding(.leading, 12)
            }
        }
        .focusSection()
    }

    private var dayRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(days, id: \.self) { day in
                    chip(Self.dayLabel(day, calendar: store.browseCalendar, now: store.clockNow), systemImage: nil,
                         selected: store.browseCalendar.isDate(day, inSameDayAs: store.selectedDay)) {
                        store.selectDay(day)
                    }
                    .focused($focus, equals: .day(day))
                }
            }
            .padding(.vertical, 6)
        }
        .focusSection()
    }

    private func chip(_ title: String, systemImage: String?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
        }
        .buttonStyle(TVKyroChipStyle(isSelected: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func bannerView(_ banner: TVSportsPlaybackBanner) -> some View {
        HStack(spacing: 20) {
            Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "antenna.radiowaves.left.and.right")
                .foregroundStyle(banner.isError ? KyroTheme.highlight : KyroTheme.accentInk)
            Text(banner.message)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Color.siloOnSurface)
            Spacer()
            if banner.showsCancel {
                Button("Cancel") { service.cancelSportsPlayback() }
                    .buttonStyle(TVKyroChipStyle())
                    .focused($focus, equals: .bannerAction)
            }
            if banner.showsRetry, let lastPlayedGame {
                Button("Retry") { service.playSportsEvent(lastPlayedGame) }
                    .buttonStyle(TVKyroChipStyle(isSelected: true))
                    .focused($focus, equals: .bannerAction)
            }
        }
        .padding(18)
        .background(Color.siloSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .focusSection()
    }

    // MARK: Games

    @ViewBuilder
    private var content: some View {
        let list = games
        if list.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 34) {
                    ForEach(list) { game in
                        TVSportsEventCard(
                            game: game,
                            isPlaying: service.sportsPlayback.isPlaying(game.id),
                            select: { activate(game) },
                            openDetails: { openDetails(game) }
                        )
                        .focused($focus, equals: .game(game.id))
                    }
                }
            }
            .tvEdgeToEdgeScroll(horizontalBleed: TVScreenLayout.pageHorizontalInset)
            .focusSection()
            .onChange(of: focus) { _, newFocus in
                if case .game(let id) = newFocus { focusMemory.remember(id) }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            if store.isLoadingSelectedDay || store.phase == .loading {
                ProgressView()
                Text("Loading events…")
            } else {
                Image(systemName: "sportscourt")
                    .font(.system(size: 54))
                Text(emptyMessage)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .font(.system(size: 26, weight: .semibold))
        .foregroundStyle(Color.siloSecondaryText)
        .frame(maxWidth: .infinity)
    }

    private var emptyMessage: String {
        switch mode {
        case .live: "No live events right now."
        case .upcoming: "No upcoming events for this day."
        case .recent: "No results for this day."
        }
    }

    // MARK: Actions

    private func select(mode newMode: TVSportsMode) {
        guard newMode != mode else { return }
        mode = newMode
        store.selectDay(TVSportsFeed.defaultDay(now: store.clockNow, calendar: store.browseCalendar))
    }

    /// A live event starts one-tap playback; every other event opens its details. A second select
    /// on the event already being tuned is ignored by the service, so rapid presses never stack
    /// playback sessions.
    private func activate(_ game: KyroSportsGame) {
        switch TVSportsFeed.selectionAction(for: game) {
        case .play:
            lastPlayedGame = game
            service.playSportsEvent(game)
        case .openDetails:
            openDetails(game)
        }
    }

    private func openDetails(_ game: KyroSportsGame) {
        focusMemory.remember(game.id)
        detailGame = game
    }

    private func closeDetails() {
        detailGame = nil
        restoreFocus()
    }

    private func restoreFocus() {
        TVFocusDiagnostics.record("scheduled", "Sports", "restoreAfterYield")
        Task { @MainActor in
            await Task.yield()
            if let id = focusMemory.restoreTarget(visible: games.map(\.id)) {
                TVFocusDiagnostics.value("request", "Sports", "restoreAfterYieldExecuted", Focus.game(id))
                focus = .game(id)
            }
        }
    }

    private func claimEntryFocus() {
        guard !isTopMenuFocused else { return }
        Task { @MainActor in
            await Task.yield()
            guard !isTopMenuFocused else { return }
            TVFocusDiagnostics.value("request", "Sports", "entryAfterYield", Focus.mode(mode))
            focus = .mode(mode)
        }
    }

    /// Score refresh loop. It follows the shared refresh policy, pauses while the player is up,
    /// and is keyed on the sport only, so focus changes never trigger a request.
    private func pollScores() async {
        while !Task.isCancelled {
            let delay = TVSportsPolling.delay(storeInterval: store.refreshInterval)
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard TVSportsPolling.shouldRefresh(playerIsPresented: playerIsPresented, isRefreshing: store.isRefreshing) else { continue }
            await store.refresh()
        }
    }

    static func dayLabel(_ day: Date, calendar: Calendar, now: Date) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        return day.formatted(.dateTime.weekday(.abbreviated).day())
    }
}

/// Sports feed grid geometry (Build 99).
enum TVSportsLayout {
    static let minimumCardWidth: CGFloat = 440
    static let columnSpacing: CGFloat = 34

    static func columnCount(width: CGFloat) -> Int {
        TVScreenLayout.adaptiveColumnCount(width: width, minimum: minimumCardWidth, spacing: columnSpacing)
    }
}
#endif
