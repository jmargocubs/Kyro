#if KYRO_STANDALONE_TESTS
import AppKit
import Foundation
import SwiftUI

// Build 131 host checks: Home sports rails build only a few height-probe cards eagerly and the
// visible cards lazily, with the same rail and card heights as Build 126's eager rail (no Build
// 125 clipping). Layout is checked with SwiftUI on the Mac (same layout engine), using stand-in
// cards whose height varies the way sports cards do; timings are Mac host numbers, not iPhone.

// MARK: Stand-in cards

private struct StandInCard: View, Identifiable {
    let id: Int
    var wrapped: String? = nil
    var periods = 0
    var fills = false

    var body: some View {
        if fills {
            Text("Add Teams").frame(width: 310).frame(minHeight: 148, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text("NFL").font(.caption2.bold()); Text("NFL Week 12").font(.caption2); Spacer(); Text("CBS").font(.caption2) }
                if let wrapped { Text(wrapped).font(.caption2).lineLimit(2) }
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 6) {
                    if periods > 0 {
                        GridRow { Color.clear.frame(height: 1); ForEach(0..<periods, id: \.self) { Text("Q\($0 + 1)").frame(width: 24) }; Text("T") }
                    }
                    ForEach(0..<2, id: \.self) { _ in
                        GridRow {
                            HStack(spacing: 10) {
                                Circle().frame(width: 26, height: 26)
                                ViewThatFits(in: .horizontal) {
                                    HStack { Text("Team \(id)").lineLimit(1); Text("8-2").font(.caption) }
                                    Text("Team \(id)").lineLimit(1).minimumScaleFactor(0.75)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            ForEach(0..<periods, id: \.self) { _ in Text("7").font(.caption).frame(width: 24) }
                            Text("21").font(.title3.bold()).frame(width: 40, alignment: .trailing)
                        }
                    }
                }
            }
            .padding(10)
            .frame(width: 310, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(.gray))
        }
    }
}

private final class Frames { var cards: [Int: CGFloat] = [:]; var rail: CGFloat = 0 }

private struct Measured: ViewModifier {
    let id: Int
    let frames: Frames
    func body(content: Content) -> some View {
        content.background(GeometryReader { proxy in Color.clear.onAppear { frames.cards[id] = proxy.size.height } })
    }
}

/// Builds 126–130.
private struct EagerRail: View {
    let cards: [StandInCard]
    let frames: Frames
    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) { ForEach(cards) { $0.modifier(Measured(id: $0.id, frames: frames)) } }
                .fixedSize(horizontal: false, vertical: true)
        }
        .background(GeometryReader { proxy in Color.clear.onAppear { frames.rail = proxy.size.height } })
    }
}

/// Build 125.
private struct LazyRail: View {
    let cards: [StandInCard]
    let frames: Frames
    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 12) { ForEach(cards) { $0.modifier(Measured(id: $0.id, frames: frames)) } }
        }
        .background(GeometryReader { proxy in Color.clear.onAppear { frames.rail = proxy.size.height } })
    }
}

/// Build 131: the same structure as `KyroHomeRail.tallestCard`.
private struct ProbedRail: View {
    let cards: [StandInCard]
    let probes: [StandInCard]
    let frames: Frames
    var body: some View {
        ScrollView(.horizontal) {
            ZStack(alignment: .topLeading) {
                HStack(alignment: .top, spacing: 12) { ForEach(probes) { $0 } }
                    .fixedSize()
                    .frame(width: 0, alignment: .topLeading)
                    .hidden()
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
                LazyHStack(alignment: .top, spacing: 12) { ForEach(cards) { $0.modifier(Measured(id: $0.id, frames: frames)) } }
            }
        }
        .background(GeometryReader { proxy in Color.clear.onAppear { frames.rail = proxy.size.height } })
    }
}

// MARK: Checks

@main @MainActor
enum KyroBuild131HostChecks {
    static var count = 0
    static func check(_ condition: Bool, _ title: String) {
        precondition(condition, title)
        count += 1
    }

    static func main() throws {
        heightProbeSelection()
        railLayoutMatchesEagerRail()
        try sourceContracts()
        print("Build 131: \(count) Home rail sizing, probe selection and diagnostics checks passed.")
    }

    // MARK: Probe selection

    static func heightProbeSelection() {
        let bears = KyroSportsTeam(id: "b", league: .nfl, abbreviation: "CHI", nickname: "Bears", location: "Chicago")
        let lions = KyroSportsTeam(id: "l", league: .nfl, abbreviation: "DET", nickname: "Lions", location: "Detroit")
        let swiatek = KyroSportsTeam(id: "s", league: .wta, abbreviation: "SWI", nickname: "Swiatek", location: "")
        let sabalenka = KyroSportsTeam(id: "a", league: .wta, abbreviation: "SAB", nickname: "Sabalenka", location: "")
        var next = 0
        func game(_ league: KyroSportLeague = .nfl, _ status: KyroGameStatus = .scheduled, note: String? = nil,
                  tournament: String? = nil, scored: Bool = false, periods: Int = 0) -> KyroSportsGame {
            next += 1
            let tennis = league == .wta
            return KyroSportsGame(
                id: .init(provider: "fixture", league: league, rawID: "\(next)"), league: league,
                week: tennis ? nil : 12, startTime: .now, status: status,
                home: .init(team: tennis ? swiatek : lions, score: scored ? 21 : nil),
                away: .init(team: tennis ? sabalenka : bears, score: scored ? 17 : nil),
                periods: (0..<periods).map { KyroGamePeriod(id: "\($0)", label: "Q\($0 + 1)", homeScore: 7, awayScore: 3) },
                broadcast: tennis ? nil : "CBS", note: note, tournament: tournament)
        }

        // 40 cards: 36 plain scheduled cards, then the tall ones at the end (the Build 125 case).
        var games = (0..<36).map { _ in game() }
        let shortNote = game(note: "Bowl")
        let longNote = game(note: "Thanksgiving Classic · Championship game at the Superdome in New Orleans, Louisiana")
        let liveScored = game(.nfl, .live, scored: true, periods: 4)
        let tennis = game(.wta, tournament: "WTA Finals", scored: true)
        games += [shortNote, longNote, liveScored, tennis]

        let probes = KyroHomeSportsHeightProbe.games(games)
        let ids = Set(probes.map(\.id))
        check(probes.count < 10, "a 40-card rail builds \(probes.count) probe cards, not 40")
        check(ids.contains(longNote.id), "the longest wrapped line in a group is measured")
        check(ids.contains(liveScored.id), "a live card with a period row is measured")
        check(ids.contains(tennis.id), "a tennis card is measured")
        check(ids.contains(games[0].id), "plain cards are measured")
        check(probes.map(\.id) == games.filter { ids.contains($0.id) }.map(\.id), "probes keep rail order")
        check(KyroHomeSportsHeightProbe.games([]).isEmpty, "an empty rail has no probes")
        check(KyroHomeSportsHeightProbe.games([games[0]]).map(\.id) == [games[0].id], "a one-card rail probes that card")
        // Every group (distinct set of drawn lines) has at least one probe.
        let shapes = Set(games.map { "\($0.status)|\(KyroHomeSportsHeightProbe.isTennis($0))|\(!KyroHomeSportsHeightProbe.wrappedLine($0).isEmpty)|\($0.hasScore)|\(!$0.periods.isEmpty)" })
        let probeShapes = Set(probes.map { "\($0.status)|\(KyroHomeSportsHeightProbe.isTennis($0))|\(!KyroHomeSportsHeightProbe.wrappedLine($0).isEmpty)|\($0.hasScore)|\(!$0.periods.isEmpty)" })
        check(shapes == probeShapes, "every card shape has a probe (\(shapes.count) shapes)")
        check(KyroHomeSportsHeightProbe.wrappedLine(tennis) == "WTA Finals", "tennis wraps its tournament line")
    }

    // MARK: Layout

    static func host<V: View>(_ view: V) -> Double {
        let start = CFAbsoluteTimeGetCurrent()
        // Home's feed: a vertical scroll view and lazy stack, at iPhone width.
        let root = ScrollView { LazyVStack(alignment: .leading) { view } }.frame(width: 430, height: 900, alignment: .topLeading)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: 430, height: 900)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.001))
        hosting.layoutSubtreeIfNeeded()
        return (CFAbsoluteTimeGetCurrent() - start) * 1000
    }

    static func railLayoutMatchesEagerRail() {
        var cards = (0..<39).map { StandInCard(id: $0) }
        cards.append(StandInCard(id: 39, wrapped: "Thanksgiving Classic · Championship game at the Superdome in New Orleans, Louisiana", periods: 4))
        cards.append(StandInCard(id: 40, fills: true))
        let probes = [cards[0], cards[39], cards[40]].map { StandInCard(id: 1000 + $0.id, wrapped: $0.wrapped, periods: $0.periods, fills: $0.fills) }

        let tallest = Frames(); _ = host(EagerRail(cards: [cards[39]], frames: tallest))
        let tallestHeight = tallest.cards[39] ?? 0

        let lazy = Frames(); _ = host(LazyRail(cards: cards, frames: lazy))
        check(lazy.rail + 0.5 < tallestHeight,
              String(format: "reproduced Build 125: a lazy rail is %.0f pt, its tallest card %.0f pt", lazy.rail, tallestHeight))

        let eager = Frames(); _ = host(EagerRail(cards: cards, frames: eager))
        let probed = Frames(); _ = host(ProbedRail(cards: cards, probes: probes, frames: probed))
        check(eager.cards.count == cards.count, "Builds 126–130 build every card (\(eager.cards.count))")
        check(probed.cards.count < 5, "Build 131 builds only visible cards (\(probed.cards.count))")
        check(abs(probed.rail - eager.rail) < 0.5 && probed.rail + 0.5 >= tallestHeight,
              String(format: "rail height unchanged: %.0f pt (eager %.0f, tallest card %.0f)", probed.rail, eager.rail, tallestHeight))
        check(probed.cards.allSatisfy { abs($0.value - (eager.cards[$0.key] ?? -1)) < 0.5 }, "visible cards keep their eager heights")

        // The quick-add card still fills the rail.
        let short = [cards[40], cards[0], cards[39]]
        let eagerShort = Frames(); _ = host(EagerRail(cards: short, frames: eagerShort))
        let probedShort = Frames(); _ = host(ProbedRail(cards: short, probes: probes, frames: probedShort))
        check(abs((probedShort.cards[40] ?? -1) - (eagerShort.cards[40] ?? -2)) < 0.5,
              String(format: "quick-add card fills the rail: %.0f pt (eager %.0f)", probedShort.cards[40] ?? -1, eagerShort.cards[40] ?? -1))

        // Mac host timing of a 41-card rail entering the feed (build + layout, median of 15).
        func median(_ run: () -> Double) -> Double { let runs = (0..<15).map { _ in run() }.sorted(); return runs[7] }
        _ = host(EagerRail(cards: cards, frames: Frames())); _ = host(ProbedRail(cards: cards, probes: probes, frames: Frames()))
        let eagerMS = median { host(EagerRail(cards: cards, frames: Frames())) }
        let probedMS = median { host(ProbedRail(cards: cards, probes: probes, frames: Frames())) }
        print(String(format: "Mac host, 41-card rail: eager %.1f ms, probed lazy %.1f ms (%.1fx less)", eagerMS, probedMS, eagerMS / probedMS))
        check(probedMS < eagerMS / 2, "the probed rail costs well under half the eager rail on the host")
    }

    // MARK: Source contracts

    static func sourceContracts() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        func source(_ path: String) throws -> String { try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }

        let shelves = try source("iosApp/iosApp/Kyro/Home/KyroHomeShelves.swift")
        check(shelves.contains("KyroHomeRail(title: shelf.title, sizing: .tallestCard)"), "sports rails keep tallest-card sizing")
        check(shelves.contains("ForEach(KyroHomeSportsHeightProbe.games(games))"), "sports rails probe their height from representative cards")
        check(shelves.contains("LazyHStack(alignment: .top, spacing: 12, content: content)")
              && !shelves.contains("HStack(alignment: .top, spacing: 12, content: content)\n                        .fixedSize(horizontal: false, vertical: true)"),
              "visible sports cards are lazy; the eager all-card HStack is gone")
        check(shelves.contains(".frame(width: 0, alignment: .topLeading)") && shelves.contains(".hidden()"),
              "the probe takes no width and is never drawn")
        check(shelves.contains("KyroHomeQuickAddCard(title: KyroHomeQuickAdd.title(for: shelf))\n                }\n            }\n            .sheet"),
              "the quick-add card is part of the probe too")
        check(shelves.contains(".frame(minHeight: KyroHomeSportsRailLayout.quickAddMinimumHeight, maxHeight: .infinity)"),
              "the quick-add card still fills the rail")
        check(shelves.contains("KyroSportsGameRow(game: game, usesCompactLayout: true)")
              && shelves.contains("KyroSportsTennisMatchRow(game: game, showsLeague: true)"),
              "cards are the same Sports Hub rows as before")
        check(shelves.contains(".contextMenu { KyroSportsFavoriteActions(game: game) }")
              && shelves.contains("host.event = KyroSportsEventSelection(game: game)"),
              "cards keep their tap and context menu")

        let diagnostics = try source("iosApp/iosApp/LiveTV/KyroPerformanceDiagnostics.swift")
        check(diagnostics.contains("case homeSportsCardBuild") && diagnostics.contains("case shellBody"),
              "opt-in Home scrolling counters exist")
        check(diagnostics.contains("guard isEnabled else { return }"), "diagnostics stay off unless enabled")
        let home = try source("iosApp/iosApp/Screens/Home/HomeView.swift")
        check(home.contains("KyroPerformanceDiagnostics.section(\"Home\")"), "frame pacing reports Home on its own")

        // Build 130 corrections stay.
        let views = try source("iosApp/iosApp/Kyro/Radio/KyroRadioViews.swift")
        check(views.contains("KyroRadioPageNowPlayingBar()"), "the Radio page mini-player stays")
        let player = try source("iosApp/iosApp/Kyro/Radio/KyroRadioPlayer.swift")
        check(player.contains("@ObservationIgnored private(set) var machine"), "radio state isolation stays")

        let project = try source("iosApp/project.yml")
        check(project.components(separatedBy: "CURRENT_PROJECT_VERSION: 131").count == 4, "app and extensions target Build 131")
        check(project.components(separatedBy: "MARKETING_VERSION: \"1.0.131\"").count == 4, "version 1.0.131")
    }
}
#endif
