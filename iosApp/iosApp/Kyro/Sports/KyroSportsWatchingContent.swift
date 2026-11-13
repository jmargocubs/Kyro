import SwiftUI

struct KyroSportsWatchingTabBar: View {
    @Binding var selection: KyroSportsWatchingTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(KyroSportsWatchingTab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 7) {
                        Text(tab.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(selection == tab ? KyroTheme.textPrimary : KyroTheme.textSecondary)
                        Capsule()
                            .fill(selection == tab ? KyroTheme.accent : .clear)
                            .frame(height: 3)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
                .accessibilityIdentifier("kyroSportsWatchingTab.\(tab.rawValue)")
            }
        }
        .padding(.horizontal, SiloTheme.padding)
        .background(Color.siloPageCanvas)
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct KyroSportsWatchingContent: View {
    let tab: KyroSportsWatchingTab
    let game: KyroSportsGame
    let detailStore: KyroSportsEventDetailStore
    let channelName: String?
    let hasOtherStreams: Bool
    let showOtherStreams: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch tab {
                case .feed:
                    EmptyView()
                case .game:
                    gameDetails
                case .stats:
                    statsContent
                case .news:
                    newsContent
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, SiloTheme.padding)
            .padding(.top, 18)
            .padding(.bottom, SiloTheme.largePadding)
        }
        .scrollIndicators(.hidden)
        // Build 61: pulling down here refreshed the Feed's schedule (the hub's action) and left
        // the box score and headlines on screen as they were. This tab refreshes its own event.
        .refreshable {
            guard tab == .game || tab == .stats || tab == .news else { return }
            await detailStore.load(for: game, force: true)
        }
        .accessibilityIdentifier("kyroSportsWatchingContent.\(tab.rawValue)")
        .task(id: detailLoadKey) {
            guard tab == .game || tab == .stats || tab == .news else { return }
            await detailStore.keepCurrent(for: game)
        }
        .task(id: supplementLoadKey) {
            guard tab == .stats else { return }
            await detailStore.loadSupplement(for: game)
        }
        .task(id: NewsLoadKey(gameID: game.id, isNewsTab: tab == .news)) {
            guard tab == .news else { return }
            await detailStore.loadSupplementalNews(for: game)
        }
        .task(id: NewsLoadKey(gameID: game.id, isNewsTab: tab == .stats && isTennis)) {
            guard tab == .stats, isTennis else { return }
            await detailStore.loadPlayerInfo(for: game)
        }
    }

    /// Restarts the supplement request only for a different event or tab, or once ESPN's details
    /// for this event have arrived. The score and clock are not part of it.
    private var supplementLoadKey: SupplementLoadKey {
        SupplementLoadKey(gameID: game.id, isStatsTab: tab == .stats,
                          hasDetails: matchingDetails != nil, isFinal: game.status.isFinal)
    }

    private struct SupplementLoadKey: Hashable {
        let gameID: KyroGameID
        let isStatsTab: Bool
        let hasDetails: Bool
        let isFinal: Bool
    }

    private var matchingSupplement: KyroSportsSupplementalStatistics? {
        guard let supplement = detailStore.supplement, supplement.gameID == game.id else { return nil }
        return supplement
    }

    private var matchingPlayerInfo: KyroTennisPlayerInfo? {
        guard let info = detailStore.playerInfo, info.gameID == game.id else { return nil }
        return info
    }

    /// Supplemental headlines minus anything ESPN's own list already shows.
    private var matchingSupplementalNews: KyroSportsSupplementalNews? {
        guard let news = detailStore.supplementalNews, news.gameID == game.id else { return nil }
        let espnURLs = Set((matchingDetails?.news ?? []).map(\.url))
        let items = news.items.filter { !espnURLs.contains($0.url) }
        return items.isEmpty ? nil : KyroSportsSupplementalNews(gameID: news.gameID, items: items)
    }

    private func supplementalNewsSection(_ news: KyroSportsSupplementalNews) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Player and tournament headlines")
                .font(.headline)
                .foregroundStyle(KyroTheme.textPrimary)
            ForEach(news.items) { item in
                Link(destination: item.url) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.headline)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(KyroTheme.textPrimary)
                            .multilineTextAlignment(.leading)
                        HStack(spacing: 6) {
                            Text(item.source).font(.caption.weight(.semibold))
                            if let date = item.publishedAt {
                                Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                            }
                            Text(item.relevance == .matchup ? "Both players" : (item.relevance == .tournament ? "Tournament" : "One player")).font(.caption)
                        }
                        .foregroundStyle(KyroTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.siloSurfaceElevated, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the article on \(item.source)")
            }
            sourceNote("Headlines name the players or the tournament but are not match reports. Links open the publisher's article.")
        }
    }

    private struct NewsLoadKey: Hashable {
        let gameID: KyroGameID
        let isNewsTab: Bool
    }

    /// The event, the tab and the kind of status. Build 59 also keyed on the clock and the score,
    /// so every scoreboard tick of a live game cancelled the running detail load and started
    /// another. A live event now refreshes on the store's own interval while the tab is open.
    private var detailLoadKey: KyroSportsEventDetailStore.LoadKey {
        KyroSportsEventDetailStore.LoadKey(game: game, tab: tab.rawValue)
    }

    private var isTennis: Bool { game.league == .atp || game.league == .wta }

    /// Build 65: says which kind of miss it was (not published yet, not tied to this match, or a
    /// source that could not be reached) instead of one fixed sentence.
    private var tennisStatsMessage: KyroTennisStatsMessage? {
        let lookup = detailStore.supplementLookup?.gameID == game.id ? detailStore.supplementLookup?.outcome : nil
        return KyroTennisStatsMessage.make(status: game.status, outcome: lookup,
                                           isLoading: detailStore.supplementLoadingGameID == game.id)
            ?? KyroTennisStatsMessage(title: "Match statistics not available yet",
                                      detail: "Serve and return statistics are added for completed matches only. Set scores are in Game.")
    }

    @ViewBuilder
    private var statsContent: some View {
        if isTennis {
            VStack(alignment: .leading, spacing: 22) {
                if let supplement = matchingSupplement {
                    KyroSportsSupplementalStatisticsView(supplement: supplement, game: game)
                } else if let message = tennisStatsMessage {
                    unavailable(title: message.title, symbol: "chart.bar.xaxis", detail: message.detail)
                }
                if let info = matchingPlayerInfo { KyroTennisPlayerInfoCard(info: info) }
            }
        } else if let details = matchingDetails, details.hasStatistics {
            VStack(alignment: .leading, spacing: 22) {
                if !details.teamStatistics.isEmpty {
                    teamStatistics(details.teamStatistics)
                }
                ForEach(details.playerBoxScores) { team in
                    playerBoxScore(team)
                }
                sourceNote("Box score from ESPN for this event. Live statistics may update after the score does.")
                if let supplement = matchingSupplement {
                    KyroSportsSupplementalStatisticsView(supplement: supplement, game: game)
                }
            }
        } else if let supplement = matchingSupplement {
            VStack(alignment: .leading, spacing: 22) {
                KyroSportsSupplementalStatisticsView(supplement: supplement, game: game)
            }
        } else {
            detailState(
                emptyTitle: game.status.isScheduled ? "Box score not available yet" : "Box score unavailable",
                emptySymbol: "chart.bar.xaxis",
                emptyDetail: game.status.isScheduled
                    ? "Team and player statistics will appear when the provider opens the event box score."
                    : "The provider returned this event without team or player statistics."
            )
        }
    }

    @ViewBuilder
    private var newsContent: some View {
        let hasESPNNews = !(matchingDetails?.news.isEmpty ?? true)
        if hasESPNNews || matchingSupplementalNews != nil {
            VStack(alignment: .leading, spacing: 22) {
                if hasESPNNews { espnNewsContent }
                if let news = matchingSupplementalNews { supplementalNewsSection(news) }
            }
        } else {
            espnNewsContent
        }
    }

    @ViewBuilder
    private var espnNewsContent: some View {
        if let details = matchingDetails, !details.news.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Related to this matchup")
                    .font(.headline)
                    .foregroundStyle(KyroTheme.textPrimary)
                ForEach(details.news) { item in
                    Link(destination: item.url) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 7) {
                                Text(item.relevance == .event ? "GAME" : (item.relevance == .matchup ? "MATCHUP" : (item.relevance == .tournament ? "TOURNAMENT" : "TEAM")))
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(game.league.accentColor)
                                Text(item.source)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(KyroTheme.textSecondary)
                                if let published = item.publishedAt {
                                    Text(published, style: .relative)
                                        .font(.caption2)
                                        .foregroundStyle(KyroTheme.textSecondary)
                                }
                                Spacer(minLength: 4)
                                Image(systemName: "arrow.up.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(KyroTheme.textSecondary)
                            }
                            Text(item.headline)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(KyroTheme.textPrimary)
                                .multilineTextAlignment(.leading)
                                .lineLimit(4)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.siloSurfaceElevated, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the article on ESPN")
                }
                sourceNote("Headlines are matched using the event's verified ESPN team identifiers. Links open the publisher's article.")
            }
        } else {
            detailState(
                emptyTitle: "No related headlines found",
                emptySymbol: "newspaper",
                emptyDetail: isTennis
                    ? "Kyro did not find a current ESPN headline tagged to either player."
                    : "Kyro did not find a current headline tagged to either team in this event."
            )
        }
    }

    private var matchingDetails: KyroSportsEventDetails? {
        guard detailStore.details?.gameID == game.id else { return nil }
        return detailStore.details
    }

    @ViewBuilder
    private func detailState(emptyTitle: String, emptySymbol: String, emptyDetail: String) -> some View {
        switch KyroSportsEventDetailStore.displayPhase(phase: detailStore.phase, hasDetailsForEvent: matchingDetails != nil) {
        case .idle, .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading event details…")
                    .font(.subheadline)
                    .foregroundStyle(KyroTheme.textSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 240)
        case .loaded:
            unavailable(title: emptyTitle, symbol: emptySymbol, detail: emptyDetail)
        case .failed(let error):
            if error == .unsupportedLeague {
                unavailable(
                    title: tab == .news ? "News unavailable from ESPN" : "Box score unavailable from ESPN",
                    symbol: tab == .news ? "newspaper" : "chart.bar.xaxis",
                    detail: "ESPN's public tennis feed provides scores and set results, but no event-detail endpoint for box scores or related articles."
                )
            } else {
                VStack(spacing: 14) {
                    ContentUnavailableView {
                        Label("Event details unavailable", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error.userMessage)
                    }
                    Button("Try Again") {
                        Task { await detailStore.load(for: game, force: true) }
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, minHeight: 240)
            }
        }
    }

    private func teamStatistics(_ teams: [KyroSportsTeamBoxScore]) -> some View {
        let away = teams.first { KyroSportsReconciler.canonicalTeam($0.abbreviation)
            == KyroSportsReconciler.canonicalTeam(game.away.team.abbreviation) }
        let home = teams.first { KyroSportsReconciler.canonicalTeam($0.abbreviation)
            == KyroSportsReconciler.canonicalTeam(game.home.team.abbreviation) }
        let labels = orderedStatisticLabels(away: away, home: home)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Team statistics")
                .font(.headline)
            HStack(spacing: 8) {
                Text(away?.abbreviation ?? game.away.team.abbreviation)
                    .frame(width: 58, alignment: .leading)
                Text("STAT").frame(maxWidth: .infinity)
                Text(home?.abbreviation ?? game.home.team.abbreviation)
                    .frame(width: 58, alignment: .trailing)
            }
            .font(.caption2.weight(.bold))
            .foregroundStyle(KyroTheme.textSecondary)
            ForEach(labels, id: \.self) { label in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(statValue(label, in: away)).frame(width: 58, alignment: .leading)
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(KyroTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                    Text(statValue(label, in: home)).frame(width: 58, alignment: .trailing)
                }
                .font(.subheadline.monospacedDigit().weight(.semibold))
                if label != labels.last { Divider() }
            }
        }
        .padding(14)
        .background(Color.siloSurfaceElevated, in: RoundedRectangle(cornerRadius: 12))
    }

    private func playerBoxScore(_ team: KyroSportsPlayerTeamBoxScore) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(team.displayName)
                .font(.headline)
            ForEach(team.groups) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(group.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(game.league.accentColor)
                    ScrollView(.horizontal) {
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                            GridRow {
                                Text("PLAYER").frame(width: 132, alignment: .leading)
                                ForEach(Array(group.labels.enumerated()), id: \.offset) { _, label in
                                    Text(label).frame(minWidth: 34, alignment: .trailing)
                                }
                            }
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(KyroTheme.textSecondary)
                            ForEach(group.athletes) { athlete in
                                GridRow {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(athlete.shortName ?? athlete.displayName)
                                            .lineLimit(1)
                                        if let position = athlete.position {
                                            Text(position).font(.caption2).foregroundStyle(KyroTheme.textSecondary)
                                        }
                                    }
                                    .frame(width: 132, alignment: .leading)
                                    ForEach(Array(group.labels.indices), id: \.self) { index in
                                        Text(index < athlete.values.count ? athlete.values[index] : "–")
                                            .monospacedDigit()
                                            .frame(minWidth: 34, alignment: .trailing)
                                    }
                                }
                                .font(.caption)
                            }
                        }
                        .padding(12)
                    }
                    .scrollIndicators(.hidden)
                    .background(Color.siloSurfaceElevated, in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    private func orderedStatisticLabels(
        away: KyroSportsTeamBoxScore?,
        home: KyroSportsTeamBoxScore?
    ) -> [String] {
        var labels: [String] = []
        for statistic in (away?.statistics ?? []) + (home?.statistics ?? []) where !labels.contains(statistic.label) {
            labels.append(statistic.label)
        }
        return labels
    }

    private func statValue(_ label: String, in team: KyroSportsTeamBoxScore?) -> String {
        team?.statistics.first { $0.label == label }?.value ?? "–"
    }

    private func sourceNote(_ text: String) -> some View {
        Label(text, systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(KyroTheme.textSecondary)
    }

    private var gameDetails: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(spacing: 14) {
                HStack(spacing: 8) {
                    Text(game.league.displayName.uppercased())
                        .font(.caption.weight(.bold))
                        .foregroundStyle(game.league.accentColor)
                    if let tournament = game.tournament {
                        Text(tournament).font(.caption.weight(.medium)).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    statusBadge
                }
                HStack(alignment: .center, spacing: 12) {
                    side(game.away)
                    Text(game.league == .atp || game.league == .wta ? "vs" : "–")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(KyroTheme.textSecondary)
                    side(game.home)
                }
                if let round = game.round ?? game.note {
                    Text(round)
                        .font(.caption)
                        .foregroundStyle(KyroTheme.textSecondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                if let situation = game.situation {
                    Text(situation)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(KyroTheme.textSecondary)
                }
                if game.league == .soccer, let details = matchingDetails, !details.matchEvents.isEmpty {
                    soccerTimeline(details.matchEvents)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(Color.siloSurfaceElevated, in: RoundedRectangle(cornerRadius: 12))

            let scoredPeriods = game.periods.filter(\.hasScore)
            if !scoredPeriods.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(game.league == .mlb ? "Innings"
                         : (game.league == .atp || game.league == .wta ? "Set scores" : "Scoring by period"))
                        .font(.subheadline.weight(.semibold))
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(scoredPeriods) { period in
                                VStack(spacing: 6) {
                                    Text(period.label).font(.caption2.weight(.semibold))
                                    HStack(spacing: 7) {
                                        Text(period.awayScore.map(String.init) ?? "–")
                                        Text("–").foregroundStyle(KyroTheme.textSecondary)
                                        Text(period.homeScore.map(String.init) ?? "–")
                                    }
                                    .font(.caption.monospacedDigit().weight(.medium))
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(Color.siloSurfaceElevated, in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                if let venue = game.venue, !venue.isEmpty {
                    Label(venue, systemImage: "mappin.and.ellipse")
                }
                if let start = game.startTime {
                    Label(game.isStartTimeTBD ? start.formatted(date: .abbreviated, time: .omitted)
                          : start.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                }
                if let channelName {
                    Label("Watching on \(channelName)", systemImage: "tv")
                }
            }
            .font(.subheadline)
            .foregroundStyle(KyroTheme.textSecondary)

            if hasOtherStreams {
                Button(action: showOtherStreams) {
                    Label("Other Streams", systemImage: "sportscourt")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("kyroSportsGameOtherStreams")
            }
        }
        .foregroundStyle(KyroTheme.textPrimary)
    }

    private func soccerTimeline(_ events: [KyroSportsMatchEvent]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Match timeline")
                .font(.subheadline.weight(.semibold))
            ForEach(events) { event in
                HStack(alignment: .top, spacing: 10) {
                    Text(event.clock ?? "–")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .frame(width: 38, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.kind).font(.caption.weight(.semibold))
                        if !event.playerNames.isEmpty {
                            Text(event.playerNames.joined(separator: ", "))
                                .font(.caption2)
                                .foregroundStyle(KyroTheme.textSecondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.siloSurfaceElevated, in: RoundedRectangle(cornerRadius: 12))
    }

    private func side(_ side: KyroGameTeam) -> some View {
        VStack(spacing: 7) {
            KyroSportsTeamLogo(team: side.team, size: 42)
            Text(side.team.abbreviation)
                .font(.caption.weight(.bold))
                .multilineTextAlignment(.center)
                .lineLimit(1)
            Text(side.team.fullName)
                .font(.caption2)
                .foregroundStyle(KyroTheme.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(minHeight: 28, alignment: .top)
            Text(side.score.map(String.init) ?? "—")
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .monospacedDigit()
            if let record = side.displayRecord {
                Text(record).font(.caption).foregroundStyle(KyroTheme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var statusBadge: some View {
        HStack(spacing: 5) {
            if game.status.isLive {
                Circle().fill(Color.red).frame(width: 6, height: 6)
                Text("LIVE")
                if let detail = game.statusDetail, !detail.isEmpty {
                    Text(detail).foregroundStyle(KyroTheme.textSecondary)
                }
            } else {
                Text(game.status.label)
            }
        }
        .font(.caption2.weight(.bold))
        .foregroundStyle(game.status.isLive ? Color.red : KyroTheme.textSecondary)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(game.status.isLive ? Color.red.opacity(0.1) : Color.primary.opacity(0.06),
                    in: Capsule())
    }

    private func unavailable(title: String, symbol: String, detail: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(detail)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }
}
