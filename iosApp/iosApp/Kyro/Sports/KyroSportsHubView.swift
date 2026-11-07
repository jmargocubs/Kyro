import SwiftUI
import Nuke
import NukeUI

// Phase S2A: the NFL half of the Sports Hub, backed by ESPN with Sleeper as an
// outage fallback.
//
// The page keeps S1's shell — hero, scroll reporting, shell-header runway — and
// replaces the placeholder cards with live sections. League filters are already
// present for all five target leagues, but only NFL is activated; the others
// render an explanatory empty state rather than unfinished league screens.

/// A Kyro-only fourth-tab root, shown inside the unified shell's tab bar.
struct KyroRootPageView: View {
    let page: KyroRootPage

    var body: some View {
        switch page {
        case .sports:
            KyroSportsHubView()
        case .favorites:
            KyroTabRootContainer(title: "Favorites") {
                FavoritesView(showsNavigationTitle: false)
            }
        }
    }
}

/// Hosts a page that normally lives in a navigation stack (it titles itself with the navigation
/// bar) as a tab root: it leaves the shell header's runway, adds the page title, and hides the bar.
private struct KyroTabRootContainer<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    @Environment(\.kyroShellHeader) private var shellHeader

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.largeTitle.bold())
                .foregroundStyle(KyroTheme.textPrimary)
                .padding(.horizontal, SiloTheme.padding)
                .padding(.top, SiloTheme.smallPadding)
                .padding(.bottom, SiloTheme.smallPadding)
                .accessibilityAddTraits(.isHeader)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear.frame(height: shellHeader?.runway ?? 0)
        }
        .siloPageBackground()
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// The Sports tab.
struct KyroSportsHubView: View {
    @Environment(\.kyroShellHeader) private var shellHeader
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var fallbackScrollState = PageChromeScrollState()
    @State private var store = KyroSportsHubStore()
    @State private var refreshTask: Task<Void, Never>?

    private var scrollState: PageChromeScrollState {
        shellHeader?.scrollState(for: .sports) ?? fallbackScrollState
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: SiloTheme.padding) {
                KyroSportsFeaturedEventHero(
                    game: store.featuredEvent,
                    league: store.selectedLeague
                )
                if store.selectedLeague.isAvailable {
                    KyroSportsDashboardNavigation(
                        selection: store.selectedDashboardMode,
                        action: store.selectDashboardMode
                    )
                }
                KyroSportsLeagueFilter(selection: $store.selectedLeague)
                content
            }
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, SiloTheme.padding)
            .padding(.top, SiloTheme.smallPadding)
            .padding(.bottom, SiloTheme.largePadding)
        }
        .reportsPageChromeScroll(to: scrollState)
        .siloScrollEdgeEffect()
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear.frame(height: shellHeader?.runway ?? 0)
        }
        .siloPageBackground()
        .toolbar(.hidden, for: .navigationBar)
        .accessibilityIdentifier("kyroSportsHub")
        .refreshable { await store.load(force: true) }
        .task { await store.load() }
        .onChange(of: store.selectedLeague) { _, _ in
            cancelRefreshLoop()
            Task { await store.load() }
        }
        .onChange(of: store.refreshInterval) { _, _ in
            startRefreshLoopIfNeeded()
        }
        .onDisappear { cancelRefreshLoop() }
    }

    // MARK: Sections

    @ViewBuilder
    private var content: some View {
        if !store.selectedLeague.isAvailable {
            KyroSportsUnavailableLeague(league: store.selectedLeague)
        } else {
            switch store.phase {
            case .idle, .loading:
                KyroSportsLoadingState(league: store.selectedLeague)
            case .offline:
                KyroSportsMessageState(
                    symbol: "wifi.slash",
                    title: "You're offline",
                    message: "Connect to the internet to load NFL scores and schedules.",
                    retry: { Task { await store.load(force: true) } }
                )
            case .failed(let error):
                KyroSportsMessageState(
                    symbol: "exclamationmark.triangle",
                    title: "Scores unavailable",
                    message: error.userMessage,
                    retry: { Task { await store.load(force: true) } }
                )
            case .loaded:
                if store.sections.isEmpty {
                    KyroSportsMessageState(
                        symbol: "calendar.badge.exclamationmark",
                        title: "No games to show",
                        message: "There are no NFL games in the current window.",
                        retry: { Task { await store.load(force: true) } }
                    )
                } else {
                    if store.isShowingStaleData {
                        KyroSportsStaleNotice(retry: { Task { await store.load(force: true) } })
                    }
                    if let emptyState = store.dashboardEmptyState {
                        KyroSportsDashboardEmptyStateView(state: emptyState)
                    }
                    // Keep the rows as direct children of the lazy stack. A
                    // VStack per section would eagerly build every card as
                    // soon as that section entered the lazy viewport.
                    ForEach(store.visibleSections) { section in
                        Section {
                            ForEach(section.games) { game in
                                KyroSportsGameRow(
                                    game: game,
                                    usesCompactLayout: dynamicTypeSize.isAccessibilitySize
                                )
                                .equatable()
                                // The outer stack separates sections by 16 pt;
                                // cards inside a section keep their 10 pt rhythm.
                                .padding(.top, 10 - SiloTheme.padding)
                            }
                        } header: {
                            KyroSportsSectionHeader(section: section)
                        }
                    }
                }
            }
        }
    }

    // MARK: Refresh loop

    /// Start a single coalesced refresh loop when the page wants one. Each tick
    /// re-reads `refreshInterval`, so a game going final ends the loop and a
    /// game going live tightens it, without another timer.
    private func startRefreshLoopIfNeeded() {
        guard store.shouldPoll, refreshTask == nil else { return }
        refreshTask = Task { @MainActor in
            defer { refreshTask = nil }
            while !Task.isCancelled, let interval = store.refreshInterval {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                await store.load(force: true)
            }
        }
    }

    private func cancelRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = nil
    }
}

// MARK: - League filter

private struct KyroSportsLeagueFilter: View {
    @Binding var selection: KyroSportLeague

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(KyroSportLeague.allCases) { league in
                    Button {
                        selection = league
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: league.symbolName)
                                .font(.caption)
                            Text(league.shortName)
                                .font(.subheadline.weight(.semibold))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .foregroundStyle(selection == league ? KyroTheme.accentInk : KyroTheme.textSecondary)
                        .background {
                            Capsule().fill(selection == league
                                           ? KyroTheme.selectedFill
                                           : Color.white.opacity(0.06))
                        }
                        .overlay {
                            Capsule().strokeBorder(
                                selection == league ? KyroTheme.selectedBorder : Color.white.opacity(0.10),
                                lineWidth: 1
                            )
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(league.displayName)
                    .accessibilityAddTraits(selection == league ? [.isSelected] : [])
                    .accessibilityIdentifier("kyroSportsLeague-\(league.rawValue)")
                }
            }
            .padding(.horizontal, 1)
        }
        .scrollClipDisabled()
    }
}

// MARK: - Dashboard navigation

private struct KyroSportsDashboardNavigation: View {
    let selection: KyroSportsDashboardMode
    let action: (KyroSportsDashboardMode) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(KyroSportsDashboardMode.allCases) { mode in
                Button {
                    action(mode)
                } label: {
                    Label(mode.title, systemImage: mode.symbolName)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 9)
                        .foregroundStyle(selection == mode ? KyroTheme.accentInk : KyroTheme.textSecondary)
                        .background {
                            if selection == mode {
                                Capsule().fill(KyroTheme.accent.opacity(0.18))
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == mode ? [.isSelected] : [])
                .accessibilityIdentifier("kyroSportsMode-\(mode.rawValue)")
            }
        }
        .padding(5)
        .kyroSportsCardChrome(Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("kyroSportsDashboardNavigation")
    }
}

// MARK: - Sections and rows

private struct KyroSportsSectionHeader: View {
    let section: KyroSportsGameSection

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: section.bucket.symbolName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(section.bucket == .liveNow ? KyroTheme.live : KyroTheme.accentInk)
            if !section.bucket.isDateGrouped || section.isFirstInBucket {
                Text(section.bucket.title)
                    .font(.headline)
                    .foregroundStyle(KyroTheme.textPrimary)
            }
            if section.bucket == .liveNow {
                KyroLiveDot()
            }
            Spacer(minLength: 0)
            if let day = section.localDay {
                Text(day, format: .dateTime.weekday(.wide).month(.wide).day())
                    .font(section.isFirstInBucket ? .subheadline.weight(.semibold) : .headline)
                    .foregroundStyle(section.isFirstInBucket ? KyroTheme.silver : KyroTheme.textPrimary)
            }
        }
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("kyroSportsSection-\(section.id)")
    }
}

private struct KyroSportsGameRow: View, Equatable {
    let game: KyroSportsGame
    let usesCompactLayout: Bool

    /// Records and kickoff time sit on a trailing column when the row is wide
    /// enough for them. At accessibility sizes the row goes vertical instead of
    /// squeezing the team names.
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if usesCompactLayout {
                VStack(spacing: 8) { teamLines }
                trailingColumn
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 8) { teamLines }
                    Spacer(minLength: 8)
                    trailingColumn
                }
            }
            if !game.periods.isEmpty, (game.status.isLive || game.status.isFinal) {
                KyroSportsPeriodStrip(periods: game.periods, game: game)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .kyroSportsCardChrome(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("kyroSportsGame-\(game.id.rawID)")
    }

    private var header: some View {
        HStack(spacing: 8) {
            KyroSportsStatusPill(status: game.status, detail: game.statusLine)
            Spacer(minLength: 4)
            if let broadcast = game.broadcast, !broadcast.isEmpty {
                Text(broadcast)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(KyroTheme.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    private var teamLines: some View {
        VStack(spacing: 8) {
            KyroSportsTeamLine(
                team: game.away,
                isWinner: game.winner?.team.id == game.away.team.id,
                showsScore: game.hasScore
            )
            KyroSportsTeamLine(
                team: game.home,
                isWinner: game.winner?.team.id == game.home.team.id,
                showsScore: game.hasScore
            )
        }
    }

    @ViewBuilder
    private var trailingColumn: some View {
        VStack(alignment: usesCompactLayout ? .leading : .trailing, spacing: 6) {
            if let weekLabel = game.weekLabel {
                Text(weekLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(KyroTheme.textSecondary)
            }
            if let start = game.startTime {
                Text(start, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                    .font(.caption.weight(.medium))
                    .foregroundStyle(KyroTheme.textSecondary)
                    .multilineTextAlignment(usesCompactLayout ? .leading : .trailing)
            }
            if let venue = game.venue, !venue.isEmpty {
                Text(venue)
                    .font(.caption2)
                    .foregroundStyle(KyroTheme.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(usesCompactLayout ? .leading : .trailing)
            }
        }
        .frame(minWidth: 90, alignment: usesCompactLayout ? .leading : .trailing)
    }
}

private struct KyroSportsTeamLine: View {
    let team: KyroGameTeam
    let isWinner: Bool
    let showsScore: Bool

    var body: some View {
        HStack(spacing: 10) {
            KyroSportsTeamLogo(team: team.team)
            VStack(alignment: .leading, spacing: 1) {
                Text(team.team.fullName)
                    .font(.subheadline.weight(isWinner ? .bold : .medium))
                    .foregroundStyle(isWinner ? KyroTheme.textPrimary : KyroTheme.silver)
                    // Wrap rather than truncate: "Jacksonville Jaguars" must not read "Jacksonville J…".
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let record = team.displayRecord {
                    Text(record)
                        .font(.caption2)
                        .foregroundStyle(KyroTheme.textSecondary)
                }
            }
            Spacer(minLength: 8)
            if showsScore {
                Text(team.score.map(String.init) ?? "–")
                    .font(.title3.weight(isWinner ? .bold : .semibold))
                    .monospacedDigit()
                    .foregroundStyle(isWinner ? KyroTheme.textPrimary : KyroTheme.silver)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var parts = [team.team.fullName]
        if let record = team.displayRecord { parts.append("record \(record)") }
        if showsScore, let score = team.score { parts.append("score \(score)") }
        if isWinner { parts.append("winner") }
        return parts.joined(separator: ", ")
    }
}

private struct KyroSportsTeamLogo: View {
    let team: KyroSportsTeam
    var size: CGFloat = 28
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if let request {
                // The shared artwork pipeline downsamples at decode time and
                // keeps decoded logos in memory. SwiftUI.AsyncImage decoded
                // each CDN source at its original size and offered no shared
                // decoded-image cache for rows returning to the viewport.
                LazyImage(request: request) { state in
                    if let image = state.image {
                        image.resizable().scaledToFit()
                    } else {
                        fallback
                    }
                }
                .priority(.high)
                .onDisappear(.cancel)
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var request: ImageRequest? {
        guard let url = team.logoURL else { return nil }
        return PosterImageCache.displayRequest(
            url: url,
            pointSize: CGSize(width: size, height: size),
            scale: displayScale,
            priority: .high
        )
    }

    private var fallback: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color.white.opacity(0.10))
            .overlay {
                Text(team.abbreviation)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(KyroTheme.textSecondary)
            }
    }
}

private struct KyroSportsStatusPill: View {
    let status: KyroGameStatus
    let detail: String

    private var tint: Color {
        switch status {
        case .live: KyroTheme.live
        case .final: KyroTheme.textSecondary
        case .canceled, .postponed: KyroTheme.highlight
        case .scheduled, .unknown: KyroTheme.accentInk
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            if status.isLive {
                Circle()
                    .fill(KyroTheme.live)
                    .frame(width: 6, height: 6)
            }
            Text(detail)
                .font(.caption2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(status.isLive ? .white : tint)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            Capsule().fill(status.isLive ? KyroTheme.live : tint.opacity(0.14))
        }
        .overlay {
            Capsule().strokeBorder(tint.opacity(status.isLive ? 0 : 0.35), lineWidth: 1)
        }
    }
}

private struct KyroSportsPeriodStrip: View {
    let periods: [KyroGamePeriod]
    let game: KyroSportsGame

    var body: some View {
        Grid(alignment: .trailing, horizontalSpacing: 0, verticalSpacing: 4) {
            GridRow {
                Text("")
                    .frame(width: 40, alignment: .leading)
                ForEach(periods) { period in
                    Text(period.label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(KyroTheme.textSecondary)
                        .frame(maxWidth: .infinity)
                }
                Text("T")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(KyroTheme.textSecondary)
                    .frame(width: 34)
            }
            scoreRow(for: game.away)
            scoreRow(for: game.home)
        }
        .padding(.top, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private func scoreRow(for team: KyroGameTeam) -> some View {
        GridRow {
            Text(team.team.abbreviation)
                .font(.caption2.weight(.bold))
                .foregroundStyle(KyroTheme.textSecondary)
                .frame(width: 40, alignment: .leading)
            ForEach(periods) { period in
                Text(periodScore(period, for: team))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(KyroTheme.silver)
                    .frame(maxWidth: .infinity)
            }
            Text(team.score.map(String.init) ?? "–")
                .font(.caption2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(KyroTheme.textPrimary)
                .frame(width: 34)
        }
    }

    private func periodScore(_ period: KyroGamePeriod, for team: KyroGameTeam) -> String {
        let value = team.team.id == game.home.team.id ? period.homeScore : period.awayScore
        return value.map(String.init) ?? "–"
    }

    private var accessibilityLabel: String {
        let quarters = periods.map { period in
            let home = period.homeScore.map(String.init) ?? "0"
            let away = period.awayScore.map(String.init) ?? "0"
            return "\(period.label) \(game.away.team.abbreviation) \(away), \(game.home.team.abbreviation) \(home)"
        }
        return (["Scoring by period"] + quarters).joined(separator: ". ")
    }
}

// MARK: - Live dot

private struct KyroLiveDot: View {
    // Static on purpose: a repeating animation would redraw every frame while scrolling.
    var body: some View {
        Circle()
            .fill(KyroTheme.live)
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
    }
}

// MARK: - States

private struct KyroSportsLoadingState: View {
    let league: KyroSportLeague

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(KyroTheme.accentInk)
            Text("Loading \(league.displayName)…")
                .font(.footnote)
                .foregroundStyle(KyroTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .accessibilityIdentifier("kyroSportsLoading")
    }
}

private struct KyroSportsMessageState: View {
    let symbol: String
    let title: String
    let message: String
    let retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(KyroTheme.textSecondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
                .foregroundStyle(KyroTheme.textPrimary)
            Text(message)
                .font(.footnote)
                .foregroundStyle(KyroTheme.textSecondary)
                .multilineTextAlignment(.center)
            if let retry {
                Button("Try Again", action: retry)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(KyroTheme.accentInk)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, 16)
        .kyroSportsCardChrome(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityIdentifier("kyroSportsMessage")
    }
}

private struct KyroSportsDashboardEmptyStateView: View {
    let state: KyroSportsDashboardEmptyState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: state.symbolName)
                .font(.title3)
                .foregroundStyle(KyroTheme.textSecondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(state.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(KyroTheme.textPrimary)
                Text(state.message)
                    .font(.caption)
                    .foregroundStyle(KyroTheme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .kyroSportsCardChrome(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("kyroSportsDashboardEmpty")
    }
}

private struct KyroSportsUnavailableLeague: View {
    let league: KyroSportLeague

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: league.symbolName)
                .font(.title2)
                .foregroundStyle(KyroTheme.textSecondary)
                .accessibilityHidden(true)
            Text("\(league.displayName) is coming soon")
                .font(.headline)
                .foregroundStyle(KyroTheme.textPrimary)
            Text("Kyro is starting with NFL scores and schedules. The other leagues follow in a later update.")
                .font(.footnote)
                .foregroundStyle(KyroTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, 16)
        .kyroSportsCardChrome(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityIdentifier("kyroSportsUnavailableLeague")
    }
}

private struct KyroSportsStaleNotice: View {
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.footnote)
                .foregroundStyle(KyroTheme.highlight)
                .accessibilityHidden(true)
            Text("Some scores or schedules may be out of date.")
                .font(.caption)
                .foregroundStyle(KyroTheme.textSecondary)
            Spacer(minLength: 4)
            Button("Refresh", action: retry)
                .font(.caption.weight(.semibold))
                .foregroundStyle(KyroTheme.accentInk)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(KyroTheme.highlight.opacity(0.10))
        }
        .accessibilityIdentifier("kyroSportsStaleNotice")
    }
}

// MARK: - Hero

private struct KyroSportsFeaturedEventHero: View {
    let game: KyroSportsGame?
    let league: KyroSportLeague

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(KyroTheme.activeGradient)
                        .frame(width: 44, height: 44)
                        .shadow(color: KyroTheme.accent.opacity(0.55), radius: 14)
                    Image(systemName: "trophy.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Sports")
                        .font(.title2.bold())
                        .foregroundStyle(KyroTheme.textPrimary)
                    Text("Featured Event")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(KyroTheme.accentInk)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)

                Spacer(minLength: 0)

                Text(league.shortName)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(KyroTheme.textSecondary)
            }

            if let game {
                KyroSportsFeaturedMatchup(game: game)
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "sportscourt")
                        .foregroundStyle(KyroTheme.textSecondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No featured event available")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(KyroTheme.textPrimary)
                        Text("The next verified matchup will appear here.")
                            .font(.caption)
                            .foregroundStyle(KyroTheme.textSecondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(RadialGradient(colors: [KyroTheme.depth.opacity(0.85), .clear],
                                     center: .topLeading, startRadius: 0, endRadius: 320))
        }
        .kyroSportsCardChrome(RoundedRectangle(cornerRadius: 24, style: .continuous), glow: true)
        .accessibilityIdentifier("kyroSportsFeaturedEvent")
    }
}

private struct KyroSportsFeaturedMatchup: View {
    let game: KyroSportsGame

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                KyroSportsFeaturedTeam(
                    team: game.away,
                    isWinner: game.winner?.team.id == game.away.team.id
                )
                VStack(spacing: 5) {
                    if game.status.isLive || game.status.isFinal {
                        Text(scoreLine)
                            .font(.title2.bold())
                            .monospacedDigit()
                            .foregroundStyle(KyroTheme.textPrimary)
                    } else {
                        Text("at")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(KyroTheme.textSecondary)
                    }
                    KyroSportsStatusPill(status: game.status, detail: game.statusLine)
                }
                .frame(minWidth: 72)
                KyroSportsFeaturedTeam(
                    team: game.home,
                    isWinner: game.winner?.team.id == game.home.team.id
                )
            }

            VStack(spacing: 3) {
                Text("\(game.away.team.fullName) at \(game.home.team.fullName)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(KyroTheme.textPrimary)
                    .multilineTextAlignment(.center)
                if !game.status.isLive, let start = game.startTime {
                    Text(start, format: .dateTime.weekday(.wide).month(.wide).day().hour().minute())
                        .font(.caption.weight(.medium))
                        .foregroundStyle(KyroTheme.silver)
                }
                HStack(spacing: 6) {
                    Text(game.league.displayName)
                    if let broadcast = game.broadcast, !broadcast.isEmpty {
                        Text("•")
                        Text(broadcast)
                    }
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(KyroTheme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    private var scoreLine: String {
        "\(game.away.score.map(String.init) ?? "–")–\(game.home.score.map(String.init) ?? "–")"
    }
}

private struct KyroSportsFeaturedTeam: View {
    let team: KyroGameTeam
    let isWinner: Bool

    var body: some View {
        VStack(spacing: 5) {
            KyroSportsTeamLogo(team: team.team, size: 48)
            Text(team.team.abbreviation)
                .font(.caption.weight(isWinner ? .bold : .semibold))
                .foregroundStyle(isWinner ? KyroTheme.textPrimary : KyroTheme.silver)
                .lineLimit(1)
            if let record = team.displayRecord {
                Text(record)
                    .font(.caption2)
                    .foregroundStyle(KyroTheme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Card chrome

extension View {
    /// Static glass-look chrome for surfaces that scroll inside the Sports Hub list.
    fileprivate func kyroSportsCardChrome<S: InsettableShape>(_ shape: S, glow: Bool = false) -> some View {
        modifier(KyroSportsCardChrome(shape: shape, glow: glow))
    }
}

/// `kyroGlass` is built for a few floating controls. Inside a scrolling list it is costly:
/// every card samples and blurs its backdrop through a material, and the two shadows wrap
/// that material, so the render server re-blurs the backdrop and redraws both shadows for
/// every visible card on every scroll frame. Nothing else in the app scrolls this effect.
///
/// The backdrop behind a Sports card is the near-uniform page canvas, so the blur adds
/// almost nothing visible. This version draws the same layers (tint gradient, silver rim,
/// dark drop shadow, accent glow) over a fixed base colour. With no backdrop sampling,
/// SwiftUI can draw each card once and move it while scrolling.
private struct KyroSportsCardChrome<S: InsettableShape>: ViewModifier {
    let shape: S
    let glow: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// Stand-in for `.ultraThinMaterial` over the iOS page canvas (#111111 with a faint
    /// white wash). Tune here if the static card reads lighter or darker than live glass.
    private static var staticBase: Color { Color(red: 0.086, green: 0.086, blue: 0.094) }

    func body(content: Content) -> some View {
        content.background { staticChrome }
    }

    private var staticChrome: some View {
        ZStack {
            if reduceTransparency {
                shape.fill(KyroTheme.glassOpaque)
            } else {
                shape.fill(Self.staticBase)
                shape.fill(LinearGradient(colors: [KyroTheme.glassTint, Color.black.opacity(0.38)],
                                          startPoint: .top, endPoint: .bottom))
            }
            shape.strokeBorder(KyroTheme.glassRim, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
        .shadow(color: KyroTheme.accent.opacity(glow ? 0.4 : 0.16), radius: 20)
    }
}
