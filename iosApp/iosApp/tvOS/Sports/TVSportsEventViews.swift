#if os(tvOS)
import SwiftUI
import NukeUI

// MARK: - Shared pieces

enum TVSportsFormat {
    /// "Today 7:30 PM" style start text. Never shows a clock time the provider did not give.
    static func startText(_ game: KyroSportsGame) -> String {
        guard let start = game.startTime else { return "Time TBD" }
        if game.isStartTimeTBD { return start.formatted(.dateTime.weekday(.abbreviated).month().day()) + " · Time TBD" }
        return start.formatted(.dateTime.weekday(.abbreviated).month().day().hour().minute())
    }

    static func statusText(_ game: KyroSportsGame) -> String {
        switch game.status {
        case .live: game.statusLine
        case .scheduled: startText(game)
        default: game.statusLine
        }
    }
}

struct TVSportsTeamLogo: View {
    let team: KyroSportsTeam
    var size: CGFloat = 64

    var body: some View {
        LazyImage(url: team.logoURL ?? team.flagURL) { state in
            if let image = state.image {
                image.resizable().scaledToFit()
            } else {
                Text(team.abbreviation.prefix(3))
                    .font(.system(size: size * 0.32, weight: .heavy))
                    .foregroundStyle(Color.siloSecondaryText)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Card

struct TVSportsEventCard: View {
    let game: KyroSportsGame
    let isPlaying: Bool
    let select: () -> Void
    let openDetails: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    statusBadge
                    Spacer()
                    if let label = leagueLabel {
                        Text(label)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Color.siloSecondaryText)
                    }
                }
                teamRow(game.away)
                teamRow(game.home)
                if let broadcast = game.broadcast, !broadcast.isEmpty {
                    Label(broadcast, systemImage: "tv")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.siloSecondaryText)
                        .lineLimit(1)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.siloSurface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(isPlaying ? KyroTheme.accentInk : .clear, lineWidth: 3)
            )
        }
        .buttonStyle(TVCardFocusButtonStyle(scale: 1.04))
        .contextMenu { Button("Event Details", systemImage: "info.circle", action: openDetails) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var leagueLabel: String? {
        if let tournament = game.tournament, !tournament.isEmpty { return tournament }
        return game.league.shortName
    }

    @ViewBuilder
    private var statusBadge: some View {
        if game.status.isLive {
            HStack(spacing: 8) {
                Text("LIVE")
                    .font(.system(size: 16, weight: .black))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(KyroTheme.live, in: Capsule())
                Text(TVSportsFormat.statusText(game))
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.siloOnSurface)
            }
        } else {
            Text(TVSportsFormat.statusText(game))
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(game.status.isFinal ? Color.siloSecondaryText : Color.siloOnSurface)
        }
    }

    private func teamRow(_ side: KyroGameTeam) -> some View {
        HStack(spacing: 16) {
            TVSportsTeamLogo(team: side.team, size: 56)
            Text(side.team.shortName)
                .font(.system(size: 28, weight: side.isWinner == true ? .heavy : .semibold))
                .foregroundStyle(Color.siloOnSurface)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer()
            if game.hasScore, let score = side.score {
                Text("\(score)")
                    .font(.system(size: 34, weight: .heavy).monospacedDigit())
                    .foregroundStyle(Color.siloOnSurface)
            }
        }
    }

    private var accessibilityText: String {
        let score = game.hasScore ? ", \(game.away.score ?? 0) to \(game.home.score ?? 0)" : ""
        return "\(game.away.team.fullName) at \(game.home.team.fullName)\(score), \(TVSportsFormat.statusText(game))"
    }
}

// MARK: - Details

enum TVSportsDetailTab: String, CaseIterable, Identifiable {
    case overview, stats, players, news, streams
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: "Overview"
        case .stats: "Team Stats"
        case .players: "Player Stats"
        case .news: "News"
        case .streams: "Streams"
        }
    }
}

struct TVSportsEventDetailView: View {
    let game: KyroSportsGame
    @Bindable var service: LiveTVService
    let close: () -> Void

    @State private var details = TVSportsStores.details
    @State private var tab: TVSportsDetailTab = .overview
    @State private var streamResult: KyroSportsStreamMatchResult?
    @State private var isSearchingStreams = false
    @State private var playerTeamIndex = 0
    @FocusState private var focusedTab: TVSportsDetailTab?

    private var loaded: KyroSportsEventDetails? {
        details.details?.gameID == game.id ? details.details : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            matchupHeader
            tabRow
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    switch tab {
                    case .overview: overview
                    case .stats: teamStats
                    case .players: playerStats
                    case .news: news
                    case .streams: streams
                    }
                }
                .padding(.vertical, 12)
            }
            .focusSection()
        }
        .padding(.horizontal, 72)
        .padding(.top, TVTopMenuLayout.contentTopInset)
        .padding(.bottom, 38)
        .onExitCommand(perform: close)
        // Reloads only when the event changes; a live event refreshes itself on the shared cadence
        // and stops when this screen leaves.
        .task(id: game.id) { await details.keepCurrent(for: game) }
        .task(id: game.id) { await findStreams() }
        .task { focusedTab = tab }
    }

    private var matchupHeader: some View {
        HStack(spacing: 36) {
            side(game.away)
            VStack(spacing: 8) {
                if game.hasScore {
                    Text("\(game.away.score ?? 0) – \(game.home.score ?? 0)")
                        .font(.system(size: 64, weight: .heavy).monospacedDigit())
                }
                HStack(spacing: 10) {
                    if game.status.isLive {
                        Text("LIVE").font(.system(size: 18, weight: .black))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(KyroTheme.live, in: Capsule())
                    }
                    Text(TVSportsFormat.statusText(game)).font(.system(size: 24, weight: .semibold))
                }
            }
            .foregroundStyle(Color.siloOnSurface)
            .frame(maxWidth: .infinity)
            side(game.home)
        }
        .accessibilityElement(children: .combine)
    }

    private func side(_ team: KyroGameTeam) -> some View {
        HStack(spacing: 18) {
            TVSportsTeamLogo(team: team.team, size: 96)
            VStack(alignment: .leading, spacing: 4) {
                Text(team.team.fullName).font(.system(size: 32, weight: .bold)).lineLimit(2)
                if let record = team.displayRecord {
                    Text(record).font(.system(size: 22)).foregroundStyle(Color.siloSecondaryText)
                }
            }
            .foregroundStyle(Color.siloOnSurface)
        }
    }

    private var tabRow: some View {
        HStack(spacing: 18) {
            ForEach(TVSportsDetailTab.allCases) { option in
                Button(option.title) { tab = option }
                    .font(.system(size: 24, weight: tab == option ? .bold : .medium))
                    .foregroundStyle(tab == option ? KyroTheme.accentInk : Color.siloOnSurface)
                    .focused($focusedTab, equals: option)
                    .accessibilityAddTraits(tab == option ? .isSelected : [])
            }
            Spacer()
            Button("Back", action: close).font(.system(size: 24, weight: .medium))
        }
        .focusSection()
    }

    // MARK: Tabs

    @ViewBuilder
    private var overview: some View {
        row("Status", TVSportsFormat.statusText(game))
        if let venue = game.venue, !venue.isEmpty { row("Venue", venue) }
        if let broadcast = game.broadcast, !broadcast.isEmpty { row("Broadcast", broadcast) }
        if let note = game.note, !note.isEmpty { row("Event", note) }
        if let tournament = game.tournament, !tournament.isEmpty {
            row("Tournament", [tournament, game.round].compactMap { $0 }.joined(separator: " · "))
        }
        if let situation = game.situation, !situation.isEmpty { row("Situation", situation) }
        if !game.periods.isEmpty {
            row("Scoring", game.periods.map { "\($0.label) \($0.awayScore ?? 0)-\($0.homeScore ?? 0)" }.joined(separator: "   "))
        }
        loadStateRow
    }

    @ViewBuilder
    private var teamStats: some View {
        let teams = loaded?.teamStatistics ?? []
        if teams.count >= 2 {
            let first = teams[0], second = teams[1]
            ForEach(first.statistics) { stat in
                HStack {
                    Text(stat.value).frame(width: 220, alignment: .leading)
                    Text(stat.label).frame(maxWidth: .infinity)
                    Text(second.statistics.first { $0.label == stat.label }?.value ?? "–")
                        .frame(width: 220, alignment: .trailing)
                }
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Color.siloOnSurface)
                .focusable()
            }
        } else {
            loadStateRow
        }
    }

    @ViewBuilder
    private var playerStats: some View {
        let teams = loaded?.playerBoxScores ?? []
        if teams.isEmpty {
            loadStateRow
        } else {
            let index = min(playerTeamIndex, teams.count - 1)
            HStack(spacing: 18) {
                ForEach(Array(teams.enumerated()), id: \.element.id) { offset, team in
                    Button(team.abbreviation) { playerTeamIndex = offset }
                        .font(.system(size: 22, weight: index == offset ? .bold : .medium))
                }
            }
            ForEach(teams[index].groups) { group in
                Text(group.name).font(.system(size: 28, weight: .bold)).foregroundStyle(KyroTheme.accentInk)
                    .padding(.top, 12)
                ForEach(group.athletes.prefix(15)) { athlete in
                    HStack {
                        Text(athlete.displayName).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                        Text(athlete.values.prefix(6).joined(separator: "   "))
                            .foregroundStyle(Color.siloSecondaryText)
                    }
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Color.siloOnSurface)
                    .focusable()
                }
            }
        }
    }

    @ViewBuilder
    private var news: some View {
        let items = loaded?.news ?? []
        if items.isEmpty {
            loadStateRow
        } else {
            ForEach(items.prefix(20)) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.headline).font(.system(size: 26, weight: .semibold)).lineLimit(3)
                    Text(item.source).font(.system(size: 19)).foregroundStyle(Color.siloSecondaryText)
                }
                .foregroundStyle(Color.siloOnSurface)
                .frame(maxWidth: .infinity, alignment: .leading)
                .focusable()
            }
        }
    }

    @ViewBuilder
    private var streams: some View {
        if !KyroSportsPlaybackEligibility.isInProgress(game) {
            row("Streams", "Matching streams are offered once the event is live.")
            if let broadcast = game.broadcast, !broadcast.isEmpty { row("Broadcast", broadcast) }
        } else if isSearchingStreams {
            HStack(spacing: 14) { ProgressView(); Text("Searching your Live TV channels…") }
                .font(.system(size: 24)).foregroundStyle(Color.siloSecondaryText)
        } else if let result = streamResult, !result.matches.isEmpty {
            ForEach(result.matches) { match in
                Button {
                    service.playSportsStream(match, for: game, result: result)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(match.channel.name).font(.system(size: 26, weight: .semibold))
                            if let reason = match.reasons.first {
                                Text(reason).font(.system(size: 19)).foregroundStyle(Color.siloSecondaryText)
                            }
                        }
                        Spacer()
                        Image(systemName: "play.fill")
                    }
                    .padding(20)
                    .background(Color.siloSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(TVCardFocusButtonStyle(scale: 1.02))
            }
        } else {
            row("Streams", "No channel in your Live TV provider matches this event.")
            if service.providers.isEmpty { row("Setup", "Add a provider in Live TV to find streams.") }
        }
    }

    // MARK: Helpers

    @ViewBuilder
    private var loadStateRow: some View {
        switch details.phase {
        case .loading, .idle:
            HStack(spacing: 14) { ProgressView(); Text("Loading event details…") }
                .font(.system(size: 24)).foregroundStyle(Color.siloSecondaryText).focusable()
        case .failed(let error):
            Text(error.userMessage).font(.system(size: 24)).foregroundStyle(Color.siloSecondaryText).focusable()
        case .loaded:
            if loaded?.hasStatistics == false, tab != .overview, tab != .news {
                Text("Statistics are not published for this event yet.")
                    .font(.system(size: 24)).foregroundStyle(Color.siloSecondaryText).focusable()
            } else if tab == .news, (loaded?.news ?? []).isEmpty {
                Text("No news for this event.").font(.system(size: 24)).foregroundStyle(Color.siloSecondaryText).focusable()
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 24) {
            Text(label).font(.system(size: 22, weight: .semibold)).foregroundStyle(Color.siloSecondaryText)
                .frame(width: 200, alignment: .leading)
            Text(value).font(.system(size: 26, weight: .medium)).foregroundStyle(Color.siloOnSurface)
            Spacer()
        }
        .focusable()
    }

    /// One local match pass per opened event: no network, and not repeated by focus changes.
    private func findStreams() async {
        guard KyroSportsPlaybackEligibility.isInProgress(game) else { return }
        isSearchingStreams = true
        streamResult = await service.sportsStreamMatches(for: game)
        isSearchingStreams = false
    }
}
#endif
