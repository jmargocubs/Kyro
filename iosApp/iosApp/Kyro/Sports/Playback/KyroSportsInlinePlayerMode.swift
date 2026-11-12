import Foundation

/// What Sports Hub's inline player shows. Derived from the one Sports Hub coordinator and the one
/// Live TV presentation, so the inline player owns no playback state of its own.
enum KyroSportsInlinePlayerMode: Equatable {
    /// Nothing is playing or being found for an event.
    case hidden
    /// Discovery or an attempt is running. The frame holds its place with the status.
    case finding
    /// The verified stream shows in the inline surface.
    case playing(LiveTVChannel)
    /// The same stream is on the full-screen player or in Picture in Picture. The frame stays,
    /// so the feed does not jump, but hosts no surface: one surface shows the stream at a time.
    case elsewhere(LiveTVChannel, isPictureInPicture: Bool)

    static func make(sports: KyroSportsPlaybackCoordinator.Phase,
                     presentation: LiveTVPresentation.Phase) -> Self {
        switch sports {
        case .searching, .connecting:
            return .finding
        case .idle, .exhausted, .unavailable:
            return .hidden
        case .presented:
            switch presentation {
            case .inline(let channel): return .playing(channel)
            case .presented(let channel, _), .restoring(let channel, _):
                return .elsewhere(channel, isPictureInPicture: false)
            case .pictureInPicture(let channel): return .elsewhere(channel, isPictureInPicture: true)
            case .idle: return .hidden
            }
        }
    }

    var isVisible: Bool { self != .hidden }
}

/// The matchup and stream line beneath the inline player. The video carries only controls; this
/// strip says what is on and where it comes from. Pure, so what shows in each mode is testable.
struct KyroSportsInlineInfo: Equatable {
    let matchup: String
    let league: String
    let statusLine: String
    let isLive: Bool
    /// "102–98", or nil for tennis and games without a score.
    let score: String?
    /// The stream on screen, or nil while one is still being found.
    let channelName: String?
    /// Where the stream is when it is not inline, for the strip's status.
    let location: Location
    /// Picture in Picture and Other Streams act on the inline stream only.
    let showsPlaybackActions: Bool
    let hasOtherStreams: Bool

    enum Location: Equatable {
        case inline
        case fullScreen
        case pictureInPicture
    }

    /// - Parameter current: the same event with a newer score and status. The context holds the
    ///   snapshot taken when the stream started; another event's copy is ignored.
    init?(mode: KyroSportsInlinePlayerMode, context: KyroSportsPlaybackContext?, current: KyroSportsGame? = nil) {
        guard let context else { return nil }
        let game = current.flatMap { $0.id == context.game.id ? $0 : nil } ?? context.game
        let channel: LiveTVChannel
        switch mode {
        case .hidden, .finding: return nil
        case .playing(let playing):
            channel = playing
            location = .inline
        case .elsewhere(let playing, let isPictureInPicture):
            channel = playing
            location = isPictureInPicture ? .pictureInPicture : .fullScreen
        }
        let isTennis = game.league == .atp || game.league == .wta
        matchup = game.inlineMatchupTitle
        league = game.league.shortName
        statusLine = game.statusLine
        isLive = game.status.isLive
        score = game.hasScore && !isTennis
            ? "\(game.away.score.map(String.init) ?? "–")–\(game.home.score.map(String.init) ?? "–")" : nil
        channelName = LiveTVChannel.displayName(channel.name)
        showsPlaybackActions = location == .inline
        hasOtherStreams = context.alternatives.count + context.broadcasters.count > 1
    }
}

extension KyroSportsGame {
    /// "Spartans at Wolverines", or "Sinner vs Alcaraz" for tennis.
    var inlineMatchupTitle: String {
        let joiner = league == .atp || league == .wta ? "vs" : "at"
        return "\(away.team.nickname) \(joiner) \(home.team.nickname)"
    }
}

extension LiveTVChannel {
    /// A catalog name with runs of whitespace collapsed, for one-line display.
    static func displayName(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
