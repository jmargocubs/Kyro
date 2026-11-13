import SwiftUI

// Build 65: the supplemental statistics and Players views, shared by the pinned event's Stats tab
// and Event Details. Build 63/64 drew them only in the Stats tab, which exists only while a live
// stream plays, so a completed ATP or WTA match (opened from the schedule, in Event Details) never
// had a place to show them. Device test of Build 64, 2026-11-12.

struct KyroSportsSupplementalStatisticsView: View {
    let supplement: KyroSportsSupplementalStatistics
    let game: KyroSportsGame

    private var isTennis: Bool { game.league == .atp || game.league == .wta }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(isTennis ? "Match statistics" : "Additional match statistics")
                .font(.headline)
            if !supplement.facts.isEmpty {
                Text(supplement.facts.joined(separator: "  ·  "))
                    .font(.caption)
                    .foregroundStyle(KyroTheme.textSecondary)
            }
            rows(supplement.rows, showsHeader: true)
            ForEach(supplement.sections) { section in
                Text(section.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(game.league.accentColor)
                    .padding(.top, 6)
                rows(section.rows, showsHeader: false)
            }
            KyroSportsSourceNote(text: "Source: \(supplement.providerName). \(supplement.note)")
        }
        .padding(14)
        .background(Color.siloSurfaceElevated, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("kyroSportsSupplementalStatistics")
    }

    private func rows(_ rows: [KyroSportsSupplementalStatistics.Row], showsHeader: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsHeader {
                HStack(spacing: 8) {
                    Text(isTennis ? game.away.team.shortName : game.away.team.abbreviation)
                        .lineLimit(1).frame(width: 78, alignment: .leading)
                    Text("STAT").frame(maxWidth: .infinity)
                    Text(isTennis ? game.home.team.shortName : game.home.team.abbreviation)
                        .lineLimit(1).frame(width: 78, alignment: .trailing)
                }
                .font(.caption2.weight(.bold))
                .foregroundStyle(KyroTheme.textSecondary)
            }
            ForEach(rows) { row in
                if let group = row.group, row.id == rows.first(where: { $0.group == group })?.id {
                    Text(group.uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(game.league.accentColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, row.id == rows.first?.id ? 0 : 6)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.away).frame(width: 78, alignment: .leading)
                    Text(row.label)
                        .font(.caption)
                        .foregroundStyle(KyroTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                    Text(row.home).frame(width: 78, alignment: .trailing)
                }
                .font(.subheadline.monospacedDigit().weight(.semibold))
                if row.id != rows.last?.id { Divider() }
            }
        }
    }
}

/// Historical context for the two players, labelled so it is never read as a statistic of the
/// match on screen. Every field is optional: a player without a ranking still shows a name, country
/// and form.
struct KyroTennisPlayerInfoCard: View {
    let info: KyroTennisPlayerInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Players").font(.headline)
            HStack(alignment: .top, spacing: 12) {
                column(info.away, alignment: .leading)
                column(info.home, alignment: .trailing)
            }
            Divider()
            HStack {
                Text("\(info.awayHeadToHeadWins)").frame(width: 78, alignment: .leading)
                Text(info.meetings > 0 ? "HEAD TO HEAD" : "FIRST MEETING")
                    .font(.caption2.weight(.bold)).foregroundStyle(KyroTheme.textSecondary)
                    .frame(maxWidth: .infinity)
                Text("\(info.homeHeadToHeadWins)").frame(width: 78, alignment: .trailing)
            }
            .font(.subheadline.monospacedDigit().weight(.semibold))
            .opacity(info.meetings > 0 ? 1 : 0.6)
            KyroSportsSourceNote(text: "Earlier results and rankings from \(info.providerName), not statistics from this match. Head to head counts the meetings it lists.")
        }
        .padding(14)
        .background(Color.siloSurfaceElevated, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("kyroTennisPlayerInfo")
    }

    private func column(_ player: KyroTennisPlayerInfo.Player, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            Text(player.name).font(.subheadline.weight(.semibold)).lineLimit(2)
            Text(player.rank.map { "Rank #\($0)" } ?? "No ranking listed")
                .font(.caption.weight(.semibold))
                .foregroundStyle(player.rank == nil ? KyroTheme.textSecondary : KyroTheme.textPrimary)
            let detail = [player.points.map { "\($0) pts" }, player.country].compactMap { $0 }.joined(separator: "  ·  ")
            if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(KyroTheme.textSecondary) }
            if player.recent.isEmpty {
                Text("No recent results listed").font(.caption2).foregroundStyle(KyroTheme.textSecondary)
            } else {
                HStack(spacing: 3) {
                    ForEach(player.recent) { result in
                        Text(result.won ? "W" : "L")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(result.won ? Color.green : Color.red)
                            .accessibilityLabel("\(result.won ? "Won" : "Lost"): \(result.summary)")
                    }
                }
                Text("Last \(player.recent.count), newest first").font(.caption2).foregroundStyle(KyroTheme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .top))
    }
}

struct KyroSportsSourceNote: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(KyroTheme.textSecondary)
    }
}

/// Statistics and Players for one tennis match, for Event Details. Loads only while shown, through
/// the same cached, rate-limited providers as the Stats tab.
struct KyroTennisMatchContextSection: View {
    let game: KyroSportsGame
    let store: KyroSportsEventDetailStore

    private var supplement: KyroSportsSupplementalStatistics? {
        guard let supplement = store.supplement, supplement.gameID == game.id else { return nil }
        return supplement
    }

    private var playerInfo: KyroTennisPlayerInfo? {
        guard let info = store.playerInfo, info.gameID == game.id else { return nil }
        return info
    }

    private var message: KyroTennisStatsMessage? {
        let outcome = store.supplementLookup?.gameID == game.id ? store.supplementLookup?.outcome : nil
        return KyroTennisStatsMessage.make(status: game.status, outcome: outcome,
                                           isLoading: store.supplementLoadingGameID == game.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let supplement {
                KyroSportsSupplementalStatisticsView(supplement: supplement, game: game)
            } else if let message {
                VStack(alignment: .leading, spacing: 4) {
                    Text(message.title).font(.headline).foregroundStyle(KyroTheme.textPrimary)
                    Text(message.detail).font(.footnote).foregroundStyle(KyroTheme.textSecondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("kyroTennisStatsMessage")
            }
            if let playerInfo {
                KyroTennisPlayerInfoCard(info: playerInfo)
            } else if store.playerInfoLoadingGameID == game.id {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading rankings and recent results…").font(.footnote).foregroundStyle(KyroTheme.textSecondary)
                }
            } else if store.playerInfoLookedUpGameID == game.id {
                Text("Rankings and recent results were not found for these players. theScore covers ATP and WTA tour events, not Challenger, WTA 125 or ITF.")
                    .font(.footnote)
                    .foregroundStyle(KyroTheme.textSecondary)
            }
        }
        .task(id: KyroTennisMatchContextKey(gameID: game.id, isFinal: game.status.isFinal)) {
            await store.loadSupplement(for: game)
        }
        .task(id: game.id) {
            await store.loadPlayerInfo(for: game)
        }
        .accessibilityIdentifier("kyroTennisMatchContext")
    }
}

private struct KyroTennisMatchContextKey: Hashable {
    let gameID: KyroGameID
    let isFinal: Bool
}
