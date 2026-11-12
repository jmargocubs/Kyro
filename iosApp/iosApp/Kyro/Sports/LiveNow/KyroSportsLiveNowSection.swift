import SwiftUI

/// Live Now: compact, horizontally swipeable cards for live events Kyro can play. A tap runs the
/// Build 38 one-tap flow; nothing here starts a stream on its own.
struct KyroSportsLiveNowSection: View {
    let model: KyroSportsLiveNowModel
    let category: KyroSportsCategory
    /// The event the one-tap flow is searching or connecting for, if any.
    let activeGameID: KyroGameID?
    /// The selected sports are still on their first load, so an empty Live Now is not yet known.
    var isLoadingScores = false
    let play: (KyroSportsGame) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// One height for every Live Now state (cards, checking, nothing live), scaled with text size.
    /// Live Now follows the sport filter, so without it the section grew or shrank on each sport
    /// switch and moved Scores & Schedule below it.
    @ScaledMetric(relativeTo: .subheadline) private var contentHeight = KyroSportsLiveNowCard.minimumHeight

    /// About three cards across on iPhone; fewer when text is large.
    private var columns: Int {
        if dynamicTypeSize.isAccessibilitySize { return 1 }
        return dynamicTypeSize >= .xxLarge ? 2 : 3
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if model.items.isEmpty {
                KyroSportsLiveNowEmptyState(content: .init(status: model.status, liveEventCount: model.liveEventCount,
                                                           category: category, isLoadingScores: isLoadingScores),
                                            minimumHeight: contentHeight)
            } else {
                cards
            }
        }
        .accessibilityIdentifier("kyroSportsLiveNow")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Live Now")
                .font(.title3.bold())
                .foregroundStyle(KyroTheme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            KyroLiveDot()
            Spacer(minLength: 0)
            if model.isResolving, !model.items.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Checking your channels")
            }
        }
    }

    private var cards: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 8) {
                ForEach(model.items) { item in
                    let isActive = activeGameID == item.id
                    Button { play(item.game) } label: {
                        KyroSportsLiveNowCard(item: item, isConnecting: isActive, minimumHeight: contentHeight)
                    }
                    .buttonStyle(KyroSportsLiveNowCardStyle(isActive: isActive))
                    .containerRelativeFrame(.horizontal, count: columns, spacing: 8)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(KyroSportsLiveNowCard.accessibilityLabel(for: item))
                    .accessibilityHint("Plays the best stream for this game")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("kyroSportsLiveNow-\(item.game.id.stringValue)")
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollClipDisabled()
    }
}

/// One live event: league and clock, both sides with scores, and how many strong streams exist.
struct KyroSportsLiveNowCard: View {
    /// Live Now's content height at the default text size, shared with its message states.
    static let minimumHeight: CGFloat = 118

    let item: KyroSportsLiveNowModel.Item
    let isConnecting: Bool
    var minimumHeight: CGFloat = KyroSportsLiveNowCard.minimumHeight

    private var game: KyroSportsGame { item.game }
    private var isTennis: Bool { game.league == .atp || game.league == .wta }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Text(game.league.shortName)
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(KyroTheme.accentInk)
                Spacer(minLength: 2)
                HStack(spacing: 3) {
                    Circle().fill(KyroTheme.live).frame(width: 5, height: 5)
                    Text(game.statusLine)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .font(.caption2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(KyroTheme.textPrimary)
            }
            side(game.away, sets: setScores(away: true))
            side(game.home, sets: setScores(away: false))
            Spacer(minLength: 0)
            footer
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .topLeading)
    }

    private func side(_ side: KyroGameTeam, sets: String?) -> some View {
        HStack(spacing: 6) {
            if !isTennis {
                KyroSportsTeamLogo(team: side.team, size: 18)
            }
            ViewThatFits(in: .horizontal) {
                Text(name(side)).lineLimit(1)
                Text(isTennis ? name(side) : side.team.abbreviation).lineLimit(1).minimumScaleFactor(0.8)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(KyroTheme.silver)
            Spacer(minLength: 2)
            if let sets {
                Text(sets).font(.caption.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(KyroTheme.textPrimary).lineLimit(1)
            } else if let score = side.score {
                Text(String(score))
                    .font(.headline.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(KyroTheme.textPrimary)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 5) {
            if isConnecting {
                ProgressView().controlSize(.mini)
                Text("Connecting")
            } else {
                Image(systemName: "play.fill").font(.system(size: 9, weight: .bold))
                Text(KyroSportsLiveNowCard.streamCountText(item.streamCount))
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(KyroTheme.accentInk)
        .lineLimit(1)
    }

    /// Tennis players by surname; teams by nickname, falling back to the abbreviation.
    private func name(_ side: KyroGameTeam) -> String {
        if isTennis { return side.team.nickname.split(separator: " ").last.map(String.init) ?? side.team.nickname }
        return side.team.nickname
    }

    /// Tennis has no running score: each player's games per set, e.g. `6 3 2`.
    private func setScores(away: Bool) -> String? {
        guard isTennis, !game.periods.isEmpty else { return nil }
        return game.periods.map { set in
            (away ? set.awayScore : set.homeScore).map(String.init) ?? "–"
        }.joined(separator: " ")
    }

    static func streamCountText(_ count: Int) -> String {
        count == 1 ? "1 stream" : "\(count) streams"
    }

    static func accessibilityLabel(for item: KyroSportsLiveNowModel.Item) -> String {
        let game = item.game
        let isTennis = game.league == .atp || game.league == .wta
        func side(_ side: KyroGameTeam) -> String {
            guard let score = side.score, !isTennis else { return side.team.fullName }
            return "\(side.team.fullName) \(score)"
        }
        return [side(game.away), side(game.home), game.league.displayName, "live", game.statusLine,
                streamCountText(item.streamCount)].joined(separator: ", ")
    }
}

/// Static card chrome with Kyro's electric-blue selection while pressed or connecting.
struct KyroSportsLiveNowCardStyle: ButtonStyle {
    let isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        let highlighted = isActive || configuration.isPressed
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return configuration.label
            .background {
                if highlighted { shape.fill(KyroTheme.selectedFill) }
            }
            .kyroSportsCardChrome(shape)
            .overlay {
                shape.strokeBorder(highlighted ? KyroTheme.selectedBorder : KyroTheme.live.opacity(0.35),
                                   lineWidth: highlighted ? 1.5 : 1)
            }
            .contentShape(shape)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct KyroSportsLiveNowEmptyState: View {
    let content: KyroSportsLiveNowEmptyContent
    /// The same height as a row of Live Now cards, so switching sports never resizes the section.
    var minimumHeight: CGFloat = KyroSportsLiveNowCard.minimumHeight

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if content.showsProgress {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: content.symbol)
                        .font(.body)
                        .foregroundStyle(KyroTheme.textSecondary)
                }
            }
            .frame(width: 24)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(content.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(KyroTheme.textPrimary)
                if let message = content.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(KyroTheme.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .leading)
        .kyroSportsCardChrome(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("kyroSportsLiveNowEmpty")
    }
}
