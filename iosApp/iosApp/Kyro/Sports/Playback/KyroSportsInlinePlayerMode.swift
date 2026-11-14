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

/// Build 67: the strip under the inline player, in every mode where the frame shows. Build 66
/// drew it only once a stream played, so the Feed dropped about 50 points when a connection
/// finished. Now it names the event from the tap on, with the connection status in the stream's
/// place, at the same height.
struct KyroSportsInlineStrip: Equatable {
    enum Stream: Equatable {
        /// "Finding a stream", "Connecting · Stream 2 of 3".
        case finding(String)
        case playing(name: String?, location: KyroSportsInlineInfo.Location)
    }

    let game: KyroSportsGame
    let isTennis: Bool
    let isLive: Bool
    let league: String
    let statusLine: String
    /// "5" and "2", or nil for tennis and games without a score.
    let awayScore: String?
    let homeScore: String?
    let stream: Stream
    let showsPlaybackActions: Bool
    let hasOtherStreams: Bool

    var accessibilityMatchup: String {
        guard let awayScore, let homeScore else { return game.inlineMatchupTitle }
        return "\(game.away.team.fullName) \(awayScore), \(game.home.team.fullName) \(homeScore)"
    }

    /// - Parameters:
    ///   - current: the pinned event with its latest score and status.
    ///   - games: the hub's games, to name an event still being searched (no context exists yet).
    static func make(mode: KyroSportsInlinePlayerMode, phase: KyroSportsPlaybackCoordinator.Phase,
                     context: KyroSportsPlaybackContext?, current: KyroSportsGame?,
                     games: [KyroSportsGame]) -> KyroSportsInlineStrip? {
        if let info = KyroSportsInlineInfo(mode: mode, context: context, current: current), let context {
            let game = current.flatMap { $0.id == context.game.id ? $0 : nil } ?? context.game
            return KyroSportsInlineStrip(game: game, stream: .playing(name: info.channelName, location: info.location),
                                         showsPlaybackActions: info.showsPlaybackActions,
                                         hasOtherStreams: info.hasOtherStreams)
        }
        guard mode == .finding else { return nil }
        let game: KyroSportsGame?
        let status: String
        switch phase {
        case .searching(let id):
            game = current.flatMap { $0.id == id ? $0 : nil } ?? games.first { $0.id == id }
            status = "Finding a stream"
        case .connecting(_, let attempt, let total):
            game = context.map { context in current.flatMap { $0.id == context.game.id ? $0 : nil } ?? context.game }
            status = total > 1 ? "Connecting · Stream \(attempt) of \(total)" : "Connecting"
        case .idle, .presented, .exhausted, .unavailable:
            return nil
        }
        guard let game else { return nil }
        return KyroSportsInlineStrip(game: game, stream: .finding(status), showsPlaybackActions: false,
                                     hasOtherStreams: false)
    }

    private init(game: KyroSportsGame, stream: Stream, showsPlaybackActions: Bool, hasOtherStreams: Bool) {
        self.game = game
        isTennis = game.league == .atp || game.league == .wta
        isLive = game.status.isLive
        league = game.league.shortName
        statusLine = game.statusLine
        let scored = game.hasScore && !isTennis
        awayScore = scored ? game.away.score.map(String.init) ?? "–" : nil
        homeScore = scored ? game.home.score.map(String.init) ?? "–" : nil
        self.stream = stream
        self.showsPlaybackActions = showsPlaybackActions
        self.hasOtherStreams = hasOtherStreams
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
