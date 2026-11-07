import Foundation

enum ESPNMapping {
    static let providerName = "espn"

    static func path(for league: KyroSportLeague) -> String {
        switch league {
        case .nfl: "/apis/site/v2/sports/football/nfl/scoreboard"
        case .nba: "/apis/site/v2/sports/basketball/nba/scoreboard"
        case .mlb: "/apis/site/v2/sports/baseball/mlb/scoreboard"
        case .nhl: "/apis/site/v2/sports/hockey/nhl/scoreboard"
        case .collegeFootball: "/apis/site/v2/sports/football/college-football/scoreboard"
        }
    }

    static func game(
        from event: ESPNScoreboardResponse.Event,
        league: KyroSportLeague
    ) -> KyroSportsGame? {
        guard let competition = event.competitions?.first else { return nil }
        let rawID = nonempty(event.id) ?? nonempty(competition.id)
        guard let rawID else { return nil }

        let competitors = competition.competitors ?? []
        guard let homeWire = competitors.first(where: { $0.homeAway?.lowercased() == "home" }),
              let awayWire = competitors.first(where: { $0.homeAway?.lowercased() == "away" }),
              let homeTeam = team(from: homeWire, league: league),
              let awayTeam = team(from: awayWire, league: league) else {
            return nil
        }

        let wireStatus = competition.status ?? event.status
        let status = status(from: wireStatus)
        let includesScore = status.isLive || status.isFinal || status == .postponed
        let home = KyroGameTeam(
            team: homeTeam,
            score: includesScore ? integer(from: homeWire.score?.stringValue) : nil,
            record: overallRecord(from: homeWire.records ?? []),
            rank: pollRank(from: homeWire.curatedRank)
        )
        let away = KyroGameTeam(
            team: awayTeam,
            score: includesScore ? integer(from: awayWire.score?.stringValue) : nil,
            record: overallRecord(from: awayWire.records ?? []),
            rank: pollRank(from: awayWire.curatedRank)
        )

        return KyroSportsGame(
            id: KyroGameID(provider: providerName, league: league, rawID: rawID),
            league: league,
            season: event.season?.year,
            seasonType: seasonType(from: event.season),
            week: event.week?.number,
            startTime: startDate(competition.date ?? event.date),
            status: status,
            statusDetail: statusDetail(from: wireStatus, status: status),
            home: home,
            away: away,
            periods: periods(
                league: league,
                home: homeWire.linescores ?? [],
                away: awayWire.linescores ?? [],
                status: status
            ),
            venue: nonempty(competition.venue?.fullName),
            broadcast: broadcast(from: competition.broadcasts ?? [])
        )
    }

    static func status(from wire: ESPNScoreboardResponse.Status?) -> KyroGameStatus {
        guard let type = wire?.type else { return .unknown("") }
        let name = type.name?.uppercased() ?? ""
        let description = type.description?.uppercased() ?? ""
        let state = type.state?.lowercased()

        if name.contains("CANCEL") || description.contains("CANCEL") { return .canceled }
        if name.contains("POSTPON") || description.contains("POSTPON") { return .postponed }
        if type.completed == true || state == "post" || name.contains("FINAL") { return .final }
        if state == "in" || name.contains("IN_PROGRESS") { return .live }
        if state == "pre" || name.contains("SCHEDULED") { return .scheduled }
        return .unknown(type.name ?? type.description ?? "")
    }

    static func seasonType(from season: ESPNScoreboardResponse.Season?) -> KyroSportsSeasonType {
        switch season?.type {
        case 1: .preseason
        case 2: .regular
        case 3: .postseason
        default:
            switch season?.slug?.lowercased() {
            case "preseason": .preseason
            case "regular-season", "regular": .regular
            case "post-season", "postseason": .postseason
            default: .unknown
            }
        }
    }

    static func startDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        if let date = isoFormatter.date(from: value) { return date }
        return isoFormatterWithFractionalSeconds.date(from: value)
    }

    private static func team(
        from competitor: ESPNScoreboardResponse.Competitor,
        league: KyroSportLeague
    ) -> KyroSportsTeam? {
        guard let wire = competitor.team,
              let providerID = nonempty(wire.id) ?? nonempty(competitor.id),
              let abbreviation = nonempty(wire.abbreviation)?.uppercased() else {
            return nil
        }
        let location = nonempty(wire.location)
        let nickname = nonempty(wire.name)
            ?? nonempty(wire.shortDisplayName)
            ?? nonempty(wire.displayName)
            ?? abbreviation
        return KyroSportsTeam(
            id: "\(providerName).\(league.rawValue).\(providerID)",
            league: league,
            abbreviation: abbreviation,
            nickname: nickname,
            location: location,
            logoURL: nonempty(wire.logo).flatMap(URL.init(string:)),
            primaryColorHex: nonempty(wire.color)
        )
    }

    private static func statusDetail(
        from wire: ESPNScoreboardResponse.Status?,
        status: KyroGameStatus
    ) -> String? {
        switch status {
        case .scheduled: return nil
        case .canceled: return "Canceled"
        case .postponed: return "Postponed"
        case .live:
            return nonempty(wire?.type?.shortDetail)
                ?? nonempty(wire?.type?.detail)
                ?? clockDetail(from: wire)
                ?? "Live"
        case .final:
            return nonempty(wire?.type?.shortDetail)
                ?? nonempty(wire?.type?.detail)
                ?? "Final"
        case .unknown:
            return nonempty(wire?.type?.shortDetail) ?? nonempty(wire?.type?.description)
        }
    }

    private static func clockDetail(from status: ESPNScoreboardResponse.Status?) -> String? {
        guard let period = status?.period else { return nonempty(status?.displayClock) }
        let clock = nonempty(status?.displayClock)
        return clock.map { "P\(period) \($0)" } ?? "P\(period)"
    }

    private static func periods(
        league: KyroSportLeague,
        home: [ESPNScoreboardResponse.LineScore],
        away: [ESPNScoreboardResponse.LineScore],
        status: KyroGameStatus
    ) -> [KyroGamePeriod] {
        guard status.isLive || status.isFinal || status == .postponed else { return [] }
        var homeByPeriod: [Int: Int?] = [:]
        for line in home {
            guard let period = line.period else { continue }
            homeByPeriod[period] = integer(from: line.value, display: line.displayValue)
        }
        var awayByPeriod: [Int: Int?] = [:]
        for line in away {
            guard let period = line.period else { continue }
            awayByPeriod[period] = integer(from: line.value, display: line.displayValue)
        }
        return Set(homeByPeriod.keys).union(awayByPeriod.keys).sorted().map { period in
            KyroGamePeriod(
                id: periodID(league: league, period: period),
                label: periodLabel(league: league, period: period),
                homeScore: homeByPeriod[period] ?? nil,
                awayScore: awayByPeriod[period] ?? nil
            )
        }
    }

    private static func periodID(league: KyroSportLeague, period: Int) -> String {
        switch league {
        case .mlb: "inning\(period)"
        case .nhl: period <= 3 ? "p\(period)" : period == 4 ? "ot" : "so"
        case .nfl, .nba, .collegeFootball: period <= 4 ? "q\(period)" : "ot\(period - 4)"
        }
    }

    private static func periodLabel(league: KyroSportLeague, period: Int) -> String {
        switch league {
        case .mlb: return String(period)
        case .nhl: return period <= 3 ? "P\(period)" : period == 4 ? "OT" : "SO"
        case .nfl, .collegeFootball:
            return period <= 4 ? "Q\(period)" : period == 5 ? "OT" : "\(period - 4)OT"
        case .nba:
            return period <= 4 ? "Q\(period)" : period == 5 ? "OT" : "\(period - 4)OT"
        }
    }

    private static func overallRecord(from records: [ESPNScoreboardResponse.Record]) -> String? {
        records.first {
            let type = $0.type?.lowercased()
            let name = $0.name?.lowercased()
            return type == "total" || type == "ytd" || name == "overall" || name == "ytd"
        }.flatMap { nonempty($0.summary) }
    }

    private static func pollRank(from rank: ESPNScoreboardResponse.Rank?) -> Int? {
        guard let current = rank?.current, (1...25).contains(current) else { return nil }
        return current
    }

    private static func broadcast(from broadcasts: [ESPNScoreboardResponse.Broadcast]) -> String? {
        broadcasts.lazy.compactMap { broadcast in
            let names = (broadcast.names ?? []).compactMap(nonempty)
            return names.isEmpty ? nil : names.joined(separator: ", ")
        }.first
    }

    private static func integer(from value: String?) -> Int? {
        guard let value, let number = Double(value), number.isFinite,
              number.rounded() == number else { return nil }
        return Int(number)
    }

    private static func integer(from value: Double?, display: String?) -> Int? {
        if let value, value.isFinite, value.rounded() == value { return Int(value) }
        return integer(from: display)
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let isoFormatterWithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
