import SwiftUI

/// Other streams for the Sports Hub event the Live TV player is showing. Switching goes through
/// the player's own channel-switch route; the list is the one found when the event was tapped,
/// so nothing is searched again.
struct KyroSportsOtherStreamsSheet: View {
    let coordinator: KyroSportsPlaybackCoordinator
    let select: (KyroSportsStreamMatch) -> Void
    let dismiss: () -> Void
    /// What the guide shows now on rows without a matched listing. Loaded once, off the main actor.
    @State private var currentProgrammes: [String: EPGProgram] = [:]

    var body: some View {
        NavigationStack {
            List {
                if let context = coordinator.context {
                    Section {
                        KyroSportsStreamEventHeader(game: context.game)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    }
                    KyroSportsStreamSectionsView(
                        sections: KyroSportsStreamSection.make(
                            matches: context.alternatives, broadcasters: context.broadcasters,
                            status: { context.status(of: $0) }, currentChannelID: context.currentChannelID,
                            currentProgrammes: currentProgrammes),
                        select: { channelID in
                            if let match = context.match(for: channelID) { select(match) }
                        }
                    )
                    Section {
                    } footer: {
                        Text("“Played” means the stream started in this session. Kyro can't check what a stream is showing.")
                    }
                } else {
                    Text("This game's streams are no longer available.")
                        .foregroundStyle(KyroTheme.textSecondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(KyroTheme.background)
            .navigationTitle("Other Streams")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: dismiss) } }
            .task {
                guard let context = coordinator.context else { return }
                let channels = (context.alternatives + context.broadcasters).filter { $0.program == nil }.map(\.channel)
                currentProgrammes = await LiveTVService.shared.sportsCurrentProgrammes(for: channels)
            }
        }
        .accessibilityIdentifier("kyroSportsOtherStreams")
    }
}

/// The event a stream list belongs to: matchup, league and live state, kept short.
struct KyroSportsStreamEventHeader: View {
    let game: KyroSportsGame
    var notice: String?

    private var isTennis: Bool { game.league == .atp || game.league == .wta }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(game.league.shortName)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(KyroTheme.accentInk)
                if game.status.isLive {
                    HStack(spacing: 4) {
                        Circle().fill(KyroTheme.live).frame(width: 6, height: 6)
                        Text(game.statusLine)
                    }
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(KyroTheme.textPrimary)
                } else {
                    Text(game.statusLine).font(.caption2.weight(.semibold)).foregroundStyle(KyroTheme.textSecondary)
                }
                Spacer(minLength: 0)
                if game.hasScore, !isTennis {
                    Text("\(game.away.score.map(String.init) ?? "–")–\(game.home.score.map(String.init) ?? "–")")
                        .font(.subheadline.weight(.bold)).monospacedDigit()
                        .foregroundStyle(KyroTheme.textPrimary)
                }
            }
            Text("\(game.away.team.fullName) \(isTennis ? "vs" : "at") \(game.home.team.fullName)")
                .font(.headline)
                .foregroundStyle(KyroTheme.textPrimary)
                .lineLimit(2)
            if let notice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(KyroTheme.silver)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("kyroSportsStreamEvent")
    }
}
