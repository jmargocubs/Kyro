import Foundation

/// A local, provider-scoped match request. It deliberately contains no network
/// source or credentials: matching is only against the configured Live TV catalog.
struct KyroSportsStreamMatchRequest: Sendable {
    let game: KyroSportsGame
    let now: Date
    let eventWindow: TimeInterval

    init(game: KyroSportsGame, now: Date = .now, eventWindow: TimeInterval = 2 * 60 * 60) {
        self.game = game
        self.now = now
        self.eventWindow = max(15 * 60, eventWindow)
    }
}

enum KyroSportsStreamMatchConfidence: Int, Comparable, Sendable {
    case low = 0
    case medium = 1
    case high = 2

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct KyroSportsStreamMatch: Identifiable, Equatable, Sendable {
    let id: String
    let channel: LiveTVChannel
    let program: EPGProgram?
    let confidence: KyroSportsStreamMatchConfidence
    let score: Int
    let reasons: [String]
    let isStale: Bool
    /// What identified the event on this channel.
    var source: Source = .guide
    /// Strong enough to try without asking: both participants identified, on time in a fresh
    /// guide or spelled out in the channel name. Playback still has to prove the stream works.
    var isAutoPlayEligible = false

    enum Source: Sendable {
        /// A guide programme names the event.
        case guide
        /// The channel's own name names the event (IPTV event channels, often without a guide).
        case channelName
        /// The viewer picked the channel from channel search.
        case manual
        /// A channel of the listed broadcaster. Never evidence that it carries this event.
        case broadcaster
    }

    var title: String { program?.title ?? channel.name }
}

/// Per-tap matching cost, for diagnostics and benchmarks. Never part of result equality.
struct KyroSportsStreamMatchDiagnostics: Equatable, Sendable {
    var catalogChannels = 0
    var guideRows = 0
    var nameCandidates = 0
    var matchDuration: TimeInterval = 0

    static func == (lhs: Self, rhs: Self) -> Bool { true }
}

struct KyroSportsStreamMatchResult: Equatable, Sendable {
    /// `.low` means no verified event match; `matches` is then empty and the
    /// sheet offers manual channel search only.
    let confidence: KyroSportsStreamMatchConfidence
    /// Event-specific candidates only. Never padded with generic channels.
    let matches: [KyroSportsStreamMatch]
    let manualSearchQuery: String
    let guideWasStale: Bool
    let indexWasCancelled: Bool
    /// Short names to seed manual channel search: teams or players, then the
    /// listed broadcaster. These are suggestions, not matches.
    var manualSearchSuggestions: [String] = []
    /// The event-specific matches strong enough to try automatically, best first, at most
    /// `KyroSportsStreamMatcher.maximumAutoPlayCandidates`. A subset of `matches`.
    var autoPlayCandidates: [KyroSportsStreamMatch] = []
    /// Channels of the listed broadcaster that no evidence ties to this event. Shown separately,
    /// never tried automatically.
    var possibleBroadcasters: [KyroSportsStreamMatch] = []
    var diagnostics = KyroSportsStreamMatchDiagnostics()
    /// Filled after automatic playback ran: which streams were tried and how they did.
    var attemptStatuses: [String: KyroSportsStreamStatus] = [:]
    /// The stream the viewer picked on the discovery screen did not play, so the screen can say
    /// so instead of describing an automatic "best stream" attempt.
    var choiceDidNotPlay = false

    var highConfidenceMatch: KyroSportsStreamMatch? {
        guard confidence == .high, matches.count == 1 else { return nil }
        return matches[0]
    }
}

/// Pure matching and scoring. Index construction happens off the main actor,
/// while this type remains usable in host tests without LiveTVService.
///
/// Evidence rules (Build 37):
/// - A candidate must name the event's participants. League, sport or a
///   generic sports channel is never enough on its own.
/// - Participant names match as whole-word phrases, not substrings, so
///   "Houston" cannot match inside "Sam Houston" and "Iowa" cannot match
///   "Iowa State".
/// - A title that pairs one participant with anyone else ("Jacksonville
///   State vs Liberty"), names a different contest, names a different
///   league, or is a replay, highlights, preview or high-school broadcast is
///   rejected outright.
/// - Time overlap supports a match; it never creates one.
/// - High confidence needs both participants, a matchup structure or two
///   strong names, a start within 30 minutes, and a fresh guide.
enum KyroSportsStreamMatcher {
    static let maximumMatches = 10
    /// Streams tried automatically for one tap before the discovery screen takes over.
    static let maximumAutoPlayCandidates = 3
    static let maximumBroadcasters = 6

    // MARK: Entry points

    static func match(
        request: KyroSportsStreamMatchRequest,
        channels: [LiveTVChannel],
        guide: EPGIndex?,
        canPlay: @escaping @Sendable (LiveTVChannel) -> Bool = { _ in true }
    ) async -> KyroSportsStreamMatchResult {
        await Task.detached(priority: .userInitiated) {
            matchSynchronously(request: request, channels: channels, guide: guide, canPlay: canPlay)
        }.value
    }

    /// Builds a throwaway index. The app keeps one per catalog revision instead
    /// (`LiveTVService.sportsStreamMatches`); tests and benchmarks use this.
    static func matchSynchronously(
        request: KyroSportsStreamMatchRequest,
        channels: [LiveTVChannel],
        guide: EPGIndex?,
        canPlay: @escaping @Sendable (LiveTVChannel) -> Bool = { _ in true }
    ) -> KyroSportsStreamMatchResult {
        guard let index = KyroSportsChannelIndex.build(channels: channels.filter(canPlay)) else {
            return emptyResult(for: request, guide: guide, cancelled: true)
        }
        let keys = guide.flatMap { index.guideKeyMap(for: $0) }
        if guide != nil, keys == nil { return emptyResult(for: request, guide: guide, cancelled: true) }
        return match(request: request, index: index, guide: guide, guideKeys: keys)
    }

    static func emptyResult(for request: KyroSportsStreamMatchRequest, guide: EPGIndex?, cancelled: Bool) -> KyroSportsStreamMatchResult {
        KyroSportsStreamMatchResult(confidence: .low, matches: [], manualSearchQuery: query(for: request.game),
                                    guideWasStale: isStale(guide, now: request.now), indexWasCancelled: cancelled,
                                    manualSearchSuggestions: manualSuggestions(for: request.game))
    }

    private static func isStale(_ guide: EPGIndex?, now: Date) -> Bool {
        guide.map { !EPGRefreshPolicy().freshness(of: $0, now: now).isUsable } ?? true
    }

    /// Matches one event against a prebuilt catalog index. Reads only the guide programmes that
    /// overlap the event and may name a participant, plus the channels whose names contain a
    /// participant word: never every channel, never the network.
    static func match(
        request: KyroSportsStreamMatchRequest,
        index: KyroSportsChannelIndex,
        guide: EPGIndex?,
        guideKeys: [String: [Int32]]?
    ) -> KyroSportsStreamMatchResult {
        let started = DispatchTime.now().uptimeNanoseconds
        let game = request.game
        let stale = isStale(guide, now: request.now)
        let context = MatchContext(game: game)
        let suggestions = manualSuggestions(for: game)
        var diagnostics = KyroSportsStreamMatchDiagnostics(catalogChannels: index.channels.count)
        func finish(_ result: KyroSportsStreamMatchResult) -> KyroSportsStreamMatchResult {
            var result = result
            diagnostics.matchDuration = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
            result.diagnostics = diagnostics
            return result
        }
        // A side without a usable name (a TBD bracket slot) cannot be matched.
        guard context.isMatchable else { return finish(emptyResult(for: request, guide: guide, cancelled: false)) }

        let interval = eventInterval(for: game, request: request)
        var best: [Int: KyroSportsStreamMatch] = [:]
        func offer(_ offset: Int, _ candidate: KyroSportsStreamMatch) {
            if candidate.score > (best[offset]?.score ?? -1) { best[offset] = candidate }
        }

        // 1. Guide programmes around the event that may name a participant.
        if let guide, let guideKeys {
            let rows = guide.windowPrograms(overlapping: interval, anchors: context.anchors)
            diagnostics.guideRows = rows.count
            for (number, row) in rows.enumerated() {
                if number.isMultiple(of: 128), Task.isCancelled {
                    return finish(emptyResult(for: request, guide: guide, cancelled: true))
                }
                guard let offsets = guideKeys[row.key] else { continue }
                for offset in offsets {
                    let channel = index.channels[Int(offset)]
                    guard let candidate = evaluate(program: row.program, channel: channel, context: context,
                                                   stale: stale, now: request.now) else { continue }
                    offer(Int(offset), candidate)
                }
            }
        }

        // 2. Event channels: the matchup in the channel's own name, guide or not.
        let named = index.offsets(containingAny: context.anchors)
        diagnostics.nameCandidates = named.count
        for (number, offset) in named.enumerated() {
            if number.isMultiple(of: 256), Task.isCancelled {
                return finish(emptyResult(for: request, guide: guide, cancelled: true))
            }
            if let candidate = evaluate(channelName: index.channels[offset], context: context, stale: stale) {
                offer(offset, candidate)
            }
        }

        let ordered = best.values.sorted(by: rankedBefore)
        let broadcasters = possibleBroadcasters(index: index, context: context, excluding: Set(best.keys), stale: stale)
        guard !ordered.isEmpty else {
            var empty = emptyResult(for: request, guide: guide, cancelled: false)
            empty.possibleBroadcasters = broadcasters
            return finish(empty)
        }

        // Auto-launch only one unambiguous programme on one channel. Shared
        // guide IDs (SD/HD/backup variants) or a second matching broadcast
        // become a picker.
        let highs = ordered.filter { $0.confidence == .high }
        let confidence: KyroSportsStreamMatchConfidence
        if !stale, ordered.count == 1, highs.count == 1 {
            confidence = .high
        } else {
            confidence = .medium
        }
        let adjusted = ordered.prefix(maximumMatches).map { match -> KyroSportsStreamMatch in
            let level: KyroSportsStreamMatchConfidence = confidence == .high ? .high
                : (match.confidence == .high ? .medium : match.confidence)
            return KyroSportsStreamMatch(id: match.id, channel: match.channel, program: match.program,
                                         confidence: level, score: match.score, reasons: match.reasons,
                                         isStale: match.isStale, source: match.source,
                                         isAutoPlayEligible: match.isAutoPlayEligible)
        }
        var result = KyroSportsStreamMatchResult(confidence: confidence, matches: Array(adjusted),
                                                 manualSearchQuery: query(for: game), guideWasStale: stale,
                                                 indexWasCancelled: false, manualSearchSuggestions: suggestions)
        result.autoPlayCandidates = Array(adjusted.filter(\.isAutoPlayEligible).prefix(maximumAutoPlayCandidates))
        result.possibleBroadcasters = broadcasters
        return finish(result)
    }

    /// Higher score first. Equal scores prefer a guide-confirmed slot, then the listed
    /// broadcaster's channel, then catalog identity, so the order never depends on hashing.
    static func rankedBefore(_ lhs: KyroSportsStreamMatch, _ rhs: KyroSportsStreamMatch) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.isAutoPlayEligible != rhs.isAutoPlayEligible { return lhs.isAutoPlayEligible }
        if (lhs.program != nil) != (rhs.program != nil) { return lhs.program != nil }
        return lhs.channel.id < rhs.channel.id
    }

    /// Channels of the listed broadcaster ("ESPN", "CBSSN") that nothing ties to this event.
    /// A lead for manual choice only: a network name is never evidence.
    static func possibleBroadcasters(index: KyroSportsChannelIndex, context: MatchContext,
                                     excluding matched: Set<Int>, stale: Bool) -> [KyroSportsStreamMatch] {
        guard !context.networkPhrases.isEmpty else { return [] }
        var found: [KyroSportsStreamMatch] = []
        // Shortest names first ("FOX" before "FOX Sports Racing 4K"), stopping once the list is
        // full: a network word can hit thousands of channels in a 40,000-channel catalog.
        let offsets = index.offsets(containingAny: context.networkPhrases.compactMap(\.first))
            .filter { !matched.contains($0) }
            .sorted {
                let left = index.channels[$0].name.utf8.count, right = index.channels[$1].name.utf8.count
                return left != right ? left < right : index.channels[$0].id < index.channels[$1].id
            }
        for offset in offsets {
            if found.count >= maximumBroadcasters { break }
            let channel = index.channels[offset]
            let tokens = phraseTokens(channel.name)
            guard context.networkPhrases.contains(where: { contains($0, in: tokens) }) else { continue }
            // A replay, highlights or other-sport channel of the network is not a lead either.
            let evidence = analyze(channel.name + " | " + channel.category, context: context)
            guard !evidence.nonEvent, !evidence.leagueConflict else { continue }
            found.append(KyroSportsStreamMatch(id: "broadcaster|\(channel.id)", channel: channel, program: nil,
                                               confidence: .low, score: 0,
                                               reasons: ["Listed broadcaster; not confirmed to carry this event"],
                                               isStale: stale, source: .broadcaster))
        }
        return found
    }

    // MARK: Context

    enum Strength: Int, Comparable {
        case weak = 1
        case strong = 2
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    struct Alias: Hashable {
        let tokens: [String]
        let isStrong: Bool
        /// School and city names collide with longer names ("Iowa" in "Iowa
        /// State", "Houston" in "Sam Houston"). A guarded alias does not match
        /// when a qualifier word touches it.
        let guarded: Bool
    }

    struct Participant {
        let displayName: String
        let aliases: [Alias]
        /// Cheap substring prefilter: at least one must occur in a text before
        /// it is tokenized.
        let anchors: [String]

        func strength(in tokens: [String]) -> Strength? {
            var best: Strength?
            for alias in aliases where KyroSportsStreamMatcher.occurs(alias, in: tokens) {
                if alias.isStrong { return .strong }
                best = .weak
            }
            return best
        }
    }

    struct MatchContext {
        let game: KyroSportsGame
        let home: Participant
        let away: Participant
        let ownLeagueTokens: Set<String>
        let otherLeaguePhrases: [[String]]
        let otherSportTokens: Set<String>
        let networkPhrases: [[String]]
        let anchors: [String]

        init(game: KyroSportsGame) {
            self.game = game
            home = KyroSportsStreamMatcher.participant(for: game.home.team, league: game.league)
            away = KyroSportsStreamMatcher.participant(for: game.away.team, league: game.league)
            ownLeagueTokens = KyroSportsStreamMatcher.leagueTokens(for: game.league)
            otherLeaguePhrases = KyroSportsStreamMatcher.otherLeaguePhrases(for: game.league)
            otherSportTokens = KyroSportsStreamMatcher.otherSportTokens(for: game.league)
            networkPhrases = KyroSportsStreamMatcher.networkPhrases(for: game.broadcast)
            anchors = Array(Set(home.anchors + away.anchors))
        }

        var isMatchable: Bool { !home.aliases.isEmpty && !away.aliases.isEmpty }

        func mayMention(_ normalizedText: String) -> Bool {
            anchors.contains { normalizedText.contains($0) }
        }
    }

    /// What one piece of text says about the event.
    struct Evidence {
        var home: Strength?
        var away: Strength?
        /// A "X vs Y" / "X at Y" segment pairs the two participants.
        var matchup = false
        /// The text pairs a participant with someone else, or names a
        /// different contest.
        var conflict = false
        /// Replay, highlights, preview, studio show or high-school broadcast.
        var nonEvent = false
        var leagueConflict = false
        var mentionsLeague = false
        var mentionsLive = false

        var bothSides: Bool { home != nil && away != nil }
        var anySide: Bool { home != nil || away != nil }
        var strongSides: Int { [home, away].filter { $0 == .strong }.count }
        var isRejected: Bool { conflict || nonEvent || leagueConflict }

        mutating func merge(_ other: Evidence) {
            home = max(home, other.home)
            away = max(away, other.away)
            matchup = matchup || other.matchup
            conflict = conflict || other.conflict
            nonEvent = nonEvent || other.nonEvent
            leagueConflict = leagueConflict || other.leagueConflict
            mentionsLeague = mentionsLeague || other.mentionsLeague
            mentionsLive = mentionsLive || other.mentionsLive
        }
    }

    // MARK: Programme scoring

    static func evaluate(
        program: EPGProgram,
        channel: LiveTVChannel,
        context: MatchContext,
        stale: Bool,
        now: Date
    ) -> KyroSportsStreamMatch? {
        let headline = normalized([program.title, program.subtitle].compactMap { $0 }.joined(separator: " | "))
        var evidence = Evidence()
        var fromSummary = false
        let headlineMentions = context.mayMention(headline)
        func analyzeHeadline() {
            evidence = analyze(program.title, context: context)
            if let subtitle = program.subtitle { evidence.merge(analyze(subtitle, context: context)) }
        }
        if headlineMentions { analyzeHeadline() }
        // A generic headline ("College Football") may carry the matchup in
        // the description. That is weaker evidence and never auto-launches,
        // and a headline naming another contest or a replay ("Iowa vs.
        // Northwestern (Replay)") vetoes whatever the description says.
        if !evidence.bothSides, !evidence.isRejected, let summary = program.summary,
           isGenericSportsHeadline(headline, context: context) {
            if !headlineMentions { analyzeHeadline() }
            guard !evidence.isRejected else { return nil }
            let lead = String(summary.prefix(280))
            if context.mayMention(normalized(lead)) {
                let summaryEvidence = analyze(lead, context: context)
                if summaryEvidence.bothSides, !summaryEvidence.isRejected {
                    evidence.merge(summaryEvidence)
                    fromSummary = true
                }
            }
        }
        guard evidence.anySide, !evidence.isRejected else { return nil }
        guard let timing = timing(of: program, game: context.game, now: now) else { return nil }
        // The channel itself can contradict its guide: a "Liberty @ Jacksonville State" event
        // channel, a replay feed, or a basketball group borrowing a football guide ID.
        let channelEvidence = channelContextEvidence(channel, context: context)
        guard !channelEvidence.isRejected else { return nil }

        let channelText = normalized(channel.name + " " + channel.category)
        let channelTokens = phraseTokensNormalized(channelText)
        let categoryTokens = Set(phraseTokens(program.category ?? ""))
        let leagueEvidence = evidence.mentionsLeague
            || !context.ownLeagueTokens.isDisjoint(with: categoryTokens)
            || !context.ownLeagueTokens.isDisjoint(with: channelTokens)
        let onListedNetwork = context.networkPhrases.contains { contains($0, in: channelTokens) }

        var reasons: [String] = []
        var score: Int
        var confidence: KyroSportsStreamMatchConfidence

        if evidence.bothSides {
            score = 60 + evidence.strongSides * 8 + (evidence.matchup ? 10 : 0)
            reasons.append(fromSummary
                ? "Both \(context.participantNoun) named in the programme description"
                : "Both \(context.participantNoun) named in the guide title")
            let identified = evidence.strongSides >= 1 && (evidence.matchup || evidence.strongSides == 2)
            confidence = identified && timing.isTight && !fromSummary ? .high : .medium
        } else {
            // One participant only. Plausible solely when the title is
            // clearly about this sport, starts on time, and names nobody else.
            let named = evidence.home != nil ? context.home : context.away
            guard [evidence.home, evidence.away].contains(.strong), timing.isTight, leagueEvidence,
                  !evidence.matchup else { return nil }
            score = 35
            confidence = .medium
            reasons.append("Only \(named.displayName) is named in the guide title")
        }
        reasons.append(timing.reason)
        if timing.isTight { score += 10 }
        if leagueEvidence { score += 5 }
        if onListedNetwork {
            score += 5
            reasons.append("Channel matches the listed broadcaster")
        }
        if evidence.mentionsLive { score += 3 }
        if stale {
            confidence = min(confidence, .medium)
            reasons.append("Guide is out of date; check before watching")
        }
        return KyroSportsStreamMatch(id: "\(channel.id)|\(program.id)", channel: channel, program: program,
                                     confidence: confidence, score: score, reasons: reasons, isStale: stale,
                                     source: .guide,
                                     isAutoPlayEligible: confidence == .high && evidence.bothSides)
    }

    /// What the channel's own name and group say, for vetoes and support only.
    static func channelContextEvidence(_ channel: LiveTVChannel, context: MatchContext) -> Evidence {
        analyze(channel.name + " | " + channel.category, context: context)
    }

    /// A channel whose name pairs both participants: an IPTV event channel such as
    /// "DAZN UK: Michigan State @ Michigan" or "NCAAF 03: SHSU @ JXST". The name identifies the
    /// event even without a guide. The group ("USA | NCAAF") supports discovery but never proves
    /// a match; a group or date for another sport, league or day vetoes it.
    static func evaluate(channelName channel: LiveTVChannel, context: MatchContext, stale: Bool) -> KyroSportsStreamMatch? {
        guard context.mayMention(normalized(channel.name)) else { return nil }
        let evidence = analyze(channel.name, context: context)
        guard evidence.bothSides, !evidence.isRejected, evidence.strongSides >= 1 else { return nil }
        let group = analyze(channel.category, context: context)
        guard !group.nonEvent, !group.leagueConflict else { return nil }
        let date = KyroSportsEventNameDate.check(channel.name, event: context.game.isStartTimeTBD ? nil : context.game.startTime)
        guard date != .conflicts else { return nil }

        var score = 50 + evidence.strongSides * 4 + (evidence.matchup ? 5 : 0)
        var reasons = ["Channel name names both \(context.participantNoun)"]
        let leagueEvidence = evidence.mentionsLeague || group.mentionsLeague
        if group.mentionsLeague, !evidence.mentionsLeague {
            reasons.append("Listed under \(channel.category)")
        }
        if leagueEvidence { score += 5 }
        switch date {
        case .matches:
            score += 5
            reasons.append("Channel name date matches the event")
        case .none, .conflicts:
            reasons.append("No guide time to confirm the event")
        }
        if context.networkPhrases.contains(where: { contains($0, in: phraseTokens(channel.name)) }) {
            score += 3
            reasons.append("Channel matches the listed broadcaster")
        }
        // Both names strong, or a clear "X vs Y" with one strong name in a channel of this
        // sport. One strong name and a weak abbreviation ("MSU @ Michigan") is a lead only.
        let eligible = evidence.strongSides == 2 || (evidence.matchup && leagueEvidence)
        return KyroSportsStreamMatch(
            id: channel.id, channel: channel, program: nil, confidence: .medium, score: score,
            reasons: reasons, isStale: stale, source: .channelName, isAutoPlayEligible: eligible)
    }

    // MARK: Text analysis

    static func analyze(_ text: String, context: MatchContext) -> Evidence {
        var evidence = Evidence()
        let segments = segments(of: text)
        let allTokens = segments.flatMap { $0 }
        for segment in segments {
            evidence.home = max(evidence.home, context.home.strength(in: segment))
            evidence.away = max(evidence.away, context.away.strength(in: segment))
            if segment == ["r"] || segment == ["rpt"] { evidence.nonEvent = true }
            for index in segment.indices where isSeparator(segment[index]) {
                guard index > segment.startIndex, index < segment.endIndex - 1 else { continue }
                let left = Array(segment[..<index])
                let right = Array(segment[(index + 1)...])
                let leftHome = context.home.strength(in: left) != nil
                let leftAway = context.away.strength(in: left) != nil
                let rightHome = context.home.strength(in: right) != nil
                let rightAway = context.away.strength(in: right) != nil
                let anyHit = leftHome || leftAway || rightHome || rightAway
                // "at" is ordinary English ("Football at Night") unless it
                // touches a participant.
                if segment[index] == "at", !anyHit { continue }
                // "Michigan State vs Michigan @ 12:00 PM ET": "at" before a time
                // or date is a kickoff annotation, not a second contest.
                if segment[index] == "at", right.first?.first?.isNumber == true { continue }
                let pairs = (leftHome && rightAway) || (leftAway && rightHome)
                // "x" is only a separator in "Team x Team" listings; elsewhere it is
                // part of a name, so it never signals a conflict.
                if segment[index] == "x" {
                    if pairs { evidence.matchup = true }
                    continue
                }
                if pairs {
                    evidence.matchup = true
                } else {
                    evidence.conflict = true
                }
            }
        }
        if allTokens.contains(where: nonEventTokens.contains)
            || nonEventPhrases.contains(where: { contains($0, in: allTokens) }) {
            evidence.nonEvent = true
        }
        evidence.mentionsLeague = !context.ownLeagueTokens.isDisjoint(with: allTokens)
        // Same schools, different sport ("College Basketball: Sam Houston vs
        // Jax State") is always a different event.
        if !context.otherSportTokens.isDisjoint(with: allTokens) {
            evidence.leagueConflict = true
        } else if !evidence.mentionsLeague,
                  context.otherLeaguePhrases.contains(where: { contains($0, in: allTokens) }) {
            evidence.leagueConflict = true
        }
        evidence.mentionsLive = allTokens.contains("live")
        return evidence
    }

    private static func isSeparator(_ token: String) -> Bool {
        token == "vs" || token == "v" || token == "versus" || token == "at" || token == "x"
    }

    /// Splits on title punctuation (`:`, `|`, parentheses, dashes, commas) so
    /// "College Football: Sam Houston at Jacksonville State (Live)" yields a
    /// matchup segment without the prefix or suffix.
    static func segments(of text: String) -> [[String]] {
        // Poll ranks ("(15) Michigan State", "#3 Michigan") would split or pad a
        // matchup segment.
        let folded = normalized(text)
            .replacingOccurrences(of: #"\(\s*#?\d{1,2}\s*\)"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"#\d{1,2}\b"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "@", with: " at ")
        let breaks: Set<Character> = [":", "|", "(", ")", "[", "]", "{", "}", "\u{2013}", "\u{2014}", ",", "/", "\u{2022}", ";", "!", "?"]
        var parts: [String] = []
        var current = ""
        for character in folded {
            if breaks.contains(character) {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        return parts
            .flatMap { $0.components(separatedBy: " - ") }
            .map(phraseTokensNormalized)
            .filter { !$0.isEmpty }
    }

    private static func isGenericSportsHeadline(_ headline: String, context: MatchContext) -> Bool {
        let tokens = Set(phraseTokensNormalized(headline))
        return !context.ownLeagueTokens.isDisjoint(with: tokens)
    }

    private static let nonEventTokens: Set<String> = [
        "replay", "replays", "rebroadcast", "encore", "highlights", "highlight", "recap", "preview",
        "previews", "pregame", "postgame", "countdown", "rewind", "reair", "condensed", "analysis", "debate"
    ]

    private static let nonEventPhrases: [[String]] = [
        ["pre", "game"], ["post", "game"], ["high", "school"], ["hs", "football"], ["in", "60"], ["all", "22"],
        ["game", "of", "the", "week", "replay"], ["full", "game", "replay"]
    ]

    // MARK: Phrase matching

    static func occurs(_ alias: Alias, in tokens: [String]) -> Bool {
        let count = alias.tokens.count
        guard count > 0, tokens.count >= count else { return false }
        var index = 0
        while index + count <= tokens.count {
            if tokens[index] == alias.tokens[0], Array(tokens[index..<(index + count)]) == alias.tokens,
               !(alias.guarded && isQualified(tokens, start: index, end: index + count)) {
                return true
            }
            index += 1
        }
        return false
    }

    static func contains(_ phrase: [String], in tokens: [String]) -> Bool {
        occurs(Alias(tokens: phrase, isStrong: true, guarded: false), in: tokens)
    }

    private static let qualifierPrefixes: Set<String> = [
        "sam", "san", "north", "south", "east", "west", "northern", "southern", "eastern", "western",
        "central", "middle", "new", "little", "coastal", "ut", "uc", "ul", "uw", "fort", "upper", "lower"
    ]

    private static let qualifierSuffixes: Set<String> = [
        "state", "st", "tech", "southern", "christian", "baptist", "international", "atlantic", "poly",
        "methodist", "wesleyan", "lutheran", "pacific"
    ]

    /// "Iowa" followed by "State", "Houston" preceded by "Sam", "Texas"
    /// followed by "A&M": the word belongs to a different school.
    private static func isQualified(_ tokens: [String], start: Int, end: Int) -> Bool {
        if start > 0, qualifierPrefixes.contains(tokens[start - 1]) { return true }
        guard end < tokens.count else { return false }
        if qualifierSuffixes.contains(tokens[end]) { return true }
        if tokens[end] == "a", end + 1 < tokens.count, tokens[end + 1] == "and" || tokens[end + 1] == "m" { return true }
        return false
    }

    // MARK: Aliases

    static func participant(for team: KyroSportsTeam, league: KyroSportLeague) -> Participant {
        var aliases: [Alias] = []
        func add(_ text: String?, strong: Bool, guarded: Bool) {
            guard let text else { return }
            let tokens = phraseTokens(text)
            guard !tokens.isEmpty, !tokens.allSatisfy(ignorableAliasTokens.contains) else { return }
            // One- or two-letter lone words ("LA", "SF") are too ambiguous.
            if tokens.count == 1, tokens[0].count < 3 { return }
            if let existing = aliases.firstIndex(where: { $0.tokens == tokens }) {
                let current = aliases[existing]
                aliases[existing] = Alias(tokens: tokens, isStrong: current.isStrong || strong,
                                          guarded: current.guarded && guarded)
                return
            }
            aliases.append(Alias(tokens: tokens, isStrong: strong, guarded: guarded))
        }

        let full = team.fullName
        if normalized(full).trimmingCharacters(in: .whitespaces) == "tbd" {
            return Participant(displayName: full, aliases: [], anchors: [])
        }
        switch league {
        case .atp, .wta:
            add(full, strong: true, guarded: false)
            for name in team.alternateNames { add(name, strong: true, guarded: false) }
            // Guides usually print surnames: "Alcaraz v Shelton".
            if let surname = phraseTokens(full).last, surname.count >= 3 {
                add(surname, strong: true, guarded: false)
            }
        case .collegeFootball:
            add(full, strong: true, guarded: false)
            add(team.location, strong: true, guarded: true)
            for name in team.alternateNames { add(name, strong: true, guarded: true) }
            if let location = team.location {
                let tokens = phraseTokens(location)
                if tokens.last == "state", tokens.count > 1 {
                    add((tokens.dropLast() + ["st"]).joined(separator: " "), strong: true, guarded: true)
                }
            }
            // Mascots repeat across schools (Gamecocks, Tigers, Bulldogs).
            add(team.nickname, strong: false, guarded: true)
            add(team.abbreviation, strong: team.abbreviation.count >= 4, guarded: false)
        case .nfl, .nba, .nhl, .mlb:
            add(full, strong: true, guarded: false)
            add(team.nickname, strong: true, guarded: false)
            for name in team.alternateNames { add(name, strong: true, guarded: false) }
            // City names are shared by every team in a market.
            add(team.location, strong: false, guarded: false)
            add(team.abbreviation, strong: false, guarded: false)
        }
        for key in [full, team.location].compactMap({ $0 }) {
            for extra in curatedAliases[phraseTokens(key).joined(separator: " ")] ?? [] {
                add(extra, strong: true, guarded: false)
            }
        }
        // The most distinctive word of each alias: "jax" for "Jax State", never "state", so a
        // guide query or name lookup does not pull every "State" programme and channel.
        let anchors = Set(aliases.compactMap { alias in
            let distinctive = alias.tokens.filter { !genericAnchorTokens.contains($0) }
            return (distinctive.isEmpty ? alias.tokens : distinctive).max(by: { $0.count < $1.count })
        }).sorted()
        let display = league == .collegeFootball ? (team.location ?? team.nickname) : team.nickname
        return Participant(displayName: display, aliases: aliases, anchors: anchors)
    }

    private static let ignorableAliasTokens: Set<String> = ["the", "of", "university", "fc", "club", "team"]

    private static let genericAnchorTokens: Set<String> = [
        "state", "st", "university", "college", "city", "north", "south", "east", "west", "new", "san", "los",
        "las", "saint", "the", "of", "fc", "and", "a", "m", "tech", "central", "northern", "southern", "eastern",
        "western"
    ]

    /// Names guides use that the provider does not send. Keyed by normalized
    /// full name or location.
    static let curatedAliases: [String: [String]] = [
        "sam houston": ["sam houston state", "sam houston st", "shsu"],
        "jacksonville state": ["jax state", "jax st", "jacksonville st", "jxst", "jvst"],
        "new york giants": ["ny giants"], "new york jets": ["ny jets"],
        "san francisco 49ers": ["sf 49ers", "niners"],
        "los angeles rams": ["la rams"], "los angeles chargers": ["la chargers"],
        "los angeles lakers": ["la lakers"], "los angeles clippers": ["la clippers"],
        "new york knicks": ["ny knicks"], "philadelphia 76ers": ["sixers"],
        "los angeles dodgers": ["la dodgers"], "los angeles angels": ["la angels"],
        "new york yankees": ["ny yankees"], "new york mets": ["ny mets"],
        "los angeles kings": ["la kings"], "new york rangers": ["ny rangers"],
        "new york islanders": ["ny islanders"], "tampa bay buccaneers": ["bucs"]
    ]

    static func leagueTokens(for league: KyroSportLeague) -> Set<String> {
        switch league {
        case .nfl: ["nfl", "football"]
        case .collegeFootball: ["ncaa", "ncaaf", "college", "cfb", "football", "fbs", "fcs"]
        case .nba: ["nba", "basketball"]
        case .nhl: ["nhl", "hockey"]
        case .mlb: ["mlb", "baseball"]
        case .atp: ["atp", "tennis"]
        case .wta: ["wta", "tennis"]
        }
    }

    /// Words that put a programme in a different competition. Ignored when
    /// the programme also names this league.
    static func otherLeaguePhrases(for league: KyroSportLeague) -> [[String]] {
        let all: [KyroSportLeague: [[String]]] = [
            .nfl: [["ncaa"], ["ncaaf"], ["college"], ["cfb"], ["ufl"], ["cfl"], ["nba"], ["nhl"], ["mlb"]],
            .collegeFootball: [["nfl"], ["ufl"], ["cfl"], ["nba"], ["nhl"], ["mlb"], ["basketball"], ["hockey"],
                               ["soccer"], ["volleyball"], ["ncaab"], ["ncaaw"], ["ncaawb"], ["cbb"], ["wbb"],
                               ["mbb"]],
            .nba: [["wnba"], ["ncaa"], ["ncaab"], ["college"], ["g", "league"], ["nfl"], ["nhl"], ["mlb"]],
            .nhl: [["ahl"], ["echl"], ["ohl"], ["whl"], ["ncaa"], ["college"], ["nfl"], ["nba"], ["mlb"]],
            .mlb: [["milb"], ["ncaa"], ["college"], ["nfl"], ["nba"], ["nhl"]],
            .atp: [["wta"], ["women"], ["womens"], ["doubles"]],
            .wta: [["atp"], ["men"], ["mens"], ["doubles"]]
        ]
        return all[league] ?? []
    }

    static func otherSportTokens(for league: KyroSportLeague) -> Set<String> {
        let football: Set<String> = ["basketball", "hockey", "baseball", "softball", "soccer", "volleyball",
                                     "lacrosse", "wrestling", "tennis", "golf"]
        switch league {
        case .nfl, .collegeFootball: return football
        case .nba: return ["football", "hockey", "baseball", "soccer", "volleyball", "tennis"]
        case .nhl: return ["football", "basketball", "baseball", "soccer", "tennis"]
        case .mlb: return ["football", "basketball", "hockey", "softball", "soccer", "tennis"]
        case .atp, .wta: return ["football", "basketball", "hockey", "baseball", "soccer", "padel", "pickleball"]
        }
    }

    /// Channel-name phrases for the ESPN broadcaster label. Ranking support
    /// only; a network never makes a match by itself.
    static func networkPhrases(for broadcast: String?) -> [[String]] {
        guard let broadcast else { return [] }
        let known: [String: [String]] = [
            "cbssn": ["cbs sports network", "cbssn", "cbs sports net"],
            "espn": ["espn"], "espn2": ["espn2", "espn 2"], "espnu": ["espnu"],
            "espnews": ["espnews"], "fs1": ["fs1", "fox sports 1"], "fs2": ["fs2", "fox sports 2"],
            "secn": ["sec network", "secn"], "accn": ["acc network", "accn"],
            "btn": ["big ten network", "btn"], "nfl net": ["nfl network"], "nba tv": ["nba tv"],
            "nhl net": ["nhl network"], "mlb net": ["mlb network"], "tnt": ["tnt"], "trutv": ["trutv"],
            "tennis channel": ["tennis channel"], "abc": ["abc"], "cbs": ["cbs"], "nbc": ["nbc"], "fox": ["fox"]
        ]
        var phrases: [[String]] = []
        for part in broadcast.split(separator: "/") {
            let key = phraseTokens(String(part)).joined(separator: " ")
            guard !key.isEmpty else { continue }
            for phrase in known[key] ?? [key] {
                let tokens = phraseTokens(phrase)
                if !tokens.isEmpty, !phrases.contains(tokens) { phrases.append(tokens) }
            }
        }
        return phrases
    }

    // MARK: Time

    struct Timing {
        let isTight: Bool
        let reason: String
    }

    /// Time supports a candidate; it never creates one. A programme must
    /// overlap the event start, and may not begin more than 90 minutes after
    /// it (that is a later replay slot).
    static func timing(of program: EPGProgram, game: KyroSportsGame, now: Date) -> Timing? {
        guard let start = game.startTime, !game.isStartTimeTBD else {
            guard program.isAiring(at: now) else { return nil }
            return Timing(isTight: game.status.isLive, reason: "Programme is airing now")
        }
        guard program.end > start.addingTimeInterval(-15 * 60),
              program.start < start.addingTimeInterval(90 * 60) else { return nil }
        let offset = program.start.timeIntervalSince(start)
        let minutes = Int(abs(offset) / 60)
        let coversStart = program.start <= start && program.end >= start.addingTimeInterval(60 * 60)
            && offset >= -60 * 60
        if abs(offset) <= 30 * 60 {
            return Timing(isTight: true, reason: minutes == 0
                          ? "Guide start matches the scheduled start"
                          : "Guide start is \(minutes) min from the scheduled start")
        }
        if coversStart {
            return Timing(isTight: true, reason: "Guide slot covers the scheduled start")
        }
        return Timing(isTight: false, reason: "Guide time is \(minutes) min from the scheduled start")
    }

    private static func eventInterval(for game: KyroSportsGame, request: KyroSportsStreamMatchRequest) -> DateInterval {
        let center = game.isStartTimeTBD ? request.now : (game.startTime ?? request.now)
        return DateInterval(start: center.addingTimeInterval(-request.eventWindow), end: center.addingTimeInterval(request.eventWindow))
    }

    // MARK: Manual search

    static func query(for game: KyroSportsGame) -> String {
        "\(game.away.team.fullName) \(game.home.team.fullName)"
    }

    static func manualSuggestions(for game: KyroSportsGame) -> [String] {
        var values: [String] = []
        func add(_ value: String?) {
            guard let value, !value.isEmpty, value.uppercased() != "TBD", !values.contains(value) else { return }
            values.append(value)
        }
        for side in [game.away, game.home] {
            switch game.league {
            case .collegeFootball: add(side.team.location ?? side.team.nickname)
            case .atp, .wta: add(side.team.nickname.split(separator: " ").last.map(String.init))
            default: add(side.team.nickname)
            }
        }
        for network in (game.broadcast ?? "").split(separator: "/") {
            add(network.trimmingCharacters(in: .whitespaces))
        }
        return values
    }

    // MARK: Normalization

    static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
            .replacingOccurrences(of: "&", with: " and ")
    }

    /// Whole-word tokens, keeping one-letter words so "Texas A&M" and
    /// "C. Alcaraz" keep their shape.
    static func phraseTokens(_ value: String) -> [String] {
        phraseTokensNormalized(normalized(value))
    }

    static func phraseTokensNormalized(_ value: String) -> [String] {
        value.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    static func tokens(_ value: String) -> [String] {
        phraseTokens(value).filter { $0.count > 1 }
    }
}

private extension KyroSportsStreamMatcher.MatchContext {
    var participantNoun: String {
        game.league == .atp || game.league == .wta ? "players" : "teams"
    }
}

private func max(_ lhs: KyroSportsStreamMatcher.Strength?, _ rhs: KyroSportsStreamMatcher.Strength?) -> KyroSportsStreamMatcher.Strength? {
    switch (lhs, rhs) {
    case let (left?, right?): return Swift.max(left, right)
    case let (left?, nil): return left
    case let (nil, right?): return right
    case (nil, nil): return nil
    }
}
