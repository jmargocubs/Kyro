import SwiftUI

/// The sheet keeps an event snapshot so changing filters never replaces it with another event.
struct KyroSportsEventSelection: Identifiable {
    let game: KyroSportsGame
    var id: KyroGameID { game.id }
}

enum KyroSportsEventPreviewPolicy {
    enum Mode: Equatable {
        case upcoming, live, completed, interrupted, unknown
    }

    static func mode(for status: KyroGameStatus) -> Mode {
        switch status {
        case .scheduled: .upcoming
        case .live: .live
        case .final: .completed
        case .postponed, .canceled, .suspended: .interrupted
        case .unknown: .unknown
        }
    }

    /// A sports-network name is never a scheduled broadcast. Require a fresh guide listing
    /// that names both participants and passed the existing event/time evidence checks.
    static func expectedBroadcasts(from result: KyroSportsStreamMatchResult) -> [KyroSportsStreamMatch] {
        result.matches.filter {
            guard case .guide = $0.source else { return false }
            return $0.program != nil && !$0.isStale && $0.isAutoPlayEligible
        }
    }

    static func liveStreams(from result: KyroSportsStreamMatchResult) -> [KyroSportsStreamMatch] {
        result.matches.filter(\.isAutoPlayEligible)
    }
}

private struct KyroSportsPreviewMatchKey: Equatable {
    let gameID: KyroGameID
    let signature: String
    let revision: KyroSportsLiveNowRevision?
    let mode: KyroSportsEventPreviewPolicy.Mode
}

/// Informational event details. Its only background operation is one cancelable, indexed,
/// local metadata match for a scheduled or live event. It never opens a player or a catalog.
struct KyroSportsEventPreview: View {
    let game: KyroSportsGame
    let service: LiveTVService
    let canWatch: Bool
    let watch: () -> Void
    /// Build 65: statistics and Players for a tennis singles match. Separate from the pinned event's
    /// store, so opening details never replaces what the Stats tab shows.
    var detailStore: KyroSportsEventDetailStore? = nil

    private var showsTennisContext: Bool {
        (game.league == .atp || game.league == .wta) && game.isSingles
            && (mode == .completed || mode == .live || mode == .upcoming)
    }

    @Environment(\.dismiss) private var dismiss
    @State private var matches: [KyroSportsStreamMatch] = []
    @State private var isChecking = false

    private var mode: KyroSportsEventPreviewPolicy.Mode {
        KyroSportsEventPreviewPolicy.mode(for: game.status)
    }

    private var matchKey: KyroSportsPreviewMatchKey {
        let revision: KyroSportsLiveNowRevision?
        if case .ready(let current) = service.liveNowAvailability { revision = current }
        else { revision = nil }
        return KyroSportsPreviewMatchKey(gameID: game.id,
                                         signature: KyroSportsPlaybackEligibility.signature(of: game),
                                         revision: revision, mode: mode)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    identity
                    matchup
                    eventFacts
                    if mode == .upcoming || mode == .live { broadcasts }
                    if mode == .completed || mode == .live { results }
                    if showsTennisContext, let detailStore {
                        KyroTennisMatchContextSection(game: game, store: detailStore)
                    }
                    if mode == .live && canWatch {
                        Button(action: watch) {
                            Label("Watch Live", systemImage: "play.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 48)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(KyroTheme.accent)
                        .accessibilityIdentifier("kyroSportsPreviewWatch")
                    }
                }
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(20)
            }
            .background(KyroTheme.background)
            .navigationTitle("Event Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .task(id: matchKey) {
            matches = []
            isChecking = false
            let key = matchKey
            guard (mode == .upcoming || mode == .live), let revision = key.revision else { return }
            isChecking = true
            let result = await service.liveNowMatches(for: game, now: .now)
            guard !Task.isCancelled, matchKey == key,
                  case .ready(let current) = service.liveNowAvailability,
                  current == revision else { return }
            if let result {
                matches = mode == .upcoming
                    ? KyroSportsEventPreviewPolicy.expectedBroadcasts(from: result)
                    : KyroSportsEventPreviewPolicy.liveStreams(from: result)
            }
            isChecking = false
        }
        .accessibilityIdentifier("kyroSportsEventPreview")
    }

    private var identity: some View {
        HStack(spacing: 12) {
            Image(systemName: game.league.symbolName)
                .font(.title2.weight(.semibold))
                .foregroundStyle(game.league.accentColor)
                .frame(width: 48, height: 48)
                .background(game.league.accentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 14))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(game.league.displayName).font(.headline).foregroundStyle(KyroTheme.textPrimary)
                if let context = [game.tournament, game.round].compactMap({ $0 }).first {
                    Text(context).font(.subheadline).foregroundStyle(KyroTheme.textSecondary)
                }
            }
            Spacer(minLength: 0)
            KyroSportsStatusPill(status: game.status, detail: game.statusLine)
        }
    }

    private var matchup: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let note = game.note, !note.isEmpty {
                Text(note).font(.subheadline.weight(.semibold)).foregroundStyle(game.league.accentColor)
            }
            Text("\(game.away.team.fullName) \(game.league == .atp || game.league == .wta ? "vs" : "at") \(game.home.team.fullName)")
                .font(.title.bold())
                .foregroundStyle(KyroTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 12) {
                side(game.away)
                Text("–").font(.title2).foregroundStyle(KyroTheme.textSecondary)
                side(game.home)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .kyroSportsCardChrome(RoundedRectangle(cornerRadius: 20))
    }

    private func side(_ team: KyroGameTeam) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            KyroSportsTeamLogo(team: team.team, size: 44)
            Text(team.team.nickname)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(KyroTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let rank = team.rank { Text("No. \(rank)").font(.caption).foregroundStyle(KyroTheme.textSecondary) }
            if mode == .live || mode == .completed, let score = team.score {
                Text(String(score)).font(.title2.bold()).monospacedDigit().foregroundStyle(KyroTheme.textPrimary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var eventFacts: some View {
        VStack(alignment: .leading, spacing: 11) {
            if let start = game.startTime {
                Label(game.isStartTimeTBD
                      ? "\(start.formatted(.dateTime.weekday(.wide).month(.wide).day())) · Time TBD"
                      : start.formatted(.dateTime.weekday(.wide).month(.wide).day().hour().minute()),
                      systemImage: "calendar")
            } else {
                Label("Start time unavailable", systemImage: "calendar")
            }
            if let venue = game.venue, !venue.isEmpty { Label(venue, systemImage: "mappin.and.ellipse") }
            if let tournament = game.tournament, !tournament.isEmpty {
                Label([tournament, game.round].compactMap { $0 }.joined(separator: " · "), systemImage: "trophy")
            }
            if let situation = game.situation, mode == .live { Label(situation, systemImage: "sportscourt") }
            if mode == .interrupted || mode == .unknown {
                Text("Event status: \(game.status.label). Check the schedule for updates.")
                    .font(.subheadline).foregroundStyle(KyroTheme.textSecondary)
            }
        }
        .font(.subheadline)
        .foregroundStyle(KyroTheme.silver)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var broadcasts: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(mode == .upcoming ? "Expected Broadcasts" : "Matched Streams")
                .font(.title3.bold()).foregroundStyle(KyroTheme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            if isChecking {
                ProgressView("Checking your guide…")
            } else if matches.isEmpty {
                Text(mode == .upcoming
                     ? "No event-specific guide listing is available yet."
                     : "No strong event-specific stream is available right now.")
                    .font(.subheadline).foregroundStyle(KyroTheme.textSecondary)
            } else {
                ForEach(matches) { match in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "tv")
                            .foregroundStyle(game.league.accentColor)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(match.channel.name).font(.subheadline.weight(.semibold))
                                .foregroundStyle(KyroTheme.textPrimary).lineLimit(2)
                            if let program = match.program {
                                Text(program.title).font(.caption).foregroundStyle(KyroTheme.textSecondary)
                            }
                            Text(mode == .upcoming ? "Scheduled in guide · tentative" : "Event metadata match · stream not verified")
                                .font(.caption2).foregroundStyle(KyroTheme.textSecondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(mode == .completed ? "Result" : "Score & Status")
                .font(.title3.bold()).foregroundStyle(KyroTheme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text("\(game.away.team.nickname) \(game.away.score.map(String.init) ?? "–") · \(game.home.team.nickname) \(game.home.score.map(String.init) ?? "–")")
                .font(.headline).monospacedDigit().foregroundStyle(KyroTheme.textPrimary)
            Text(game.statusLine).font(.subheadline).foregroundStyle(KyroTheme.textSecondary)
            if !game.periods.isEmpty {
                ForEach(game.periods) { period in
                    Text("\(period.label): \(period.awayScore.map(String.init) ?? "–")–\(period.homeScore.map(String.init) ?? "–")")
                        .font(.caption).monospacedDigit().foregroundStyle(KyroTheme.textSecondary)
                }
            }
        }
    }
}
