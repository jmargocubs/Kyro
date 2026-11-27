#if KYRO_STANDALONE_TESTS
import Foundation
import Observation

// Build 130 host checks: Radio state isolation (what the app-wide Now Playing
// slot and Home observe), the pushed Radio page's Now Playing bar policy, and
// source contracts for the mini-player, Home and sports shelf sizing.

/// Counts how often an observed read would have invalidated a view.
@MainActor
private final class ObservationProbe {
    private(set) var fires = 0
    private let read: @MainActor () -> Void

    init(_ read: @escaping @MainActor () -> Void) {
        self.read = read
        arm()
    }

    private func arm() {
        withObservationTracking { read() } onChange: { [weak self] in
            // onChange runs once per registration, before the write lands.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.fires += 1
                self.arm()
            }
        }
    }
}

/// The Build 128/129 shape: the machine itself observed, written through inout.
@MainActor @Observable
private final class Build129ObservedMachine {
    var machine = KyroRadioPlaybackMachine()
    var hasSession: Bool { machine.station != nil }
}

@main @MainActor
enum KyroBuild130HostChecks {
    static var count = 0
    static func check(_ condition: Bool, _ title: String) {
        precondition(condition, title)
        count += 1
    }

    static func main() throws {
        radioStateIsolation()
        pushedRadioPageBarPolicy()
        try sourceContracts()
        print("Build 130: \(count) mini-player, state isolation and Home performance checks passed.")
    }

    // MARK: State isolation

    static func radioStateIsolation() {
        // Root cause reproduced: an observed machine invalidates hasSession
        // readers on every no-op yield.
        let old = Build129ObservedMachine()
        let oldProbe = ObservationProbe { _ = old.hasSession }
        for _ in 0..<10 { _ = old.machine.yieldToOtherPlayback() }
        check(oldProbe.fires == 10, "Build 129 shape: 10 idle yields invalidated hasSession readers \(oldProbe.fires) times")

        let status = KyroRadioPlaybackStatus()
        var machine = KyroRadioPlaybackMachine()
        let session = ObservationProbe { _ = status.hasSession }
        let stationProbe = ObservationProbe { _ = status.station }
        let stateProbe = ObservationProbe { _ = status.state }
        let activeProbe = ObservationProbe { _ = status.isActive }

        // Video, Live TV and audiobooks ask radio to yield every time they
        // start, even when radio is idle. Before Build 130 each of these
        // wrote the observed machine and invalidated the whole Now Playing slot.
        for _ in 0..<10 {
            _ = machine.yieldToOtherPlayback()
            check(!status.publish(machine), "idle radio yielding publishes nothing")
        }
        check(session.fires == 0 && stateProbe.fires == 0 && stationProbe.fires == 0 && activeProbe.fires == 0,
              "idle yields invalidate no radio observer")

        let station = KyroRadioStation(id: "00000000-0000-0000-0000-000000000001", name: "WXRT",
                                       streamURL: URL(string: "https://stream.example/wxrt"), codec: "MP3")
        _ = machine.play(station)
        check(status.publish(machine), "starting a station publishes")
        check(status.hasSession && status.state == .connecting && status.isActive && status.station == station,
              "status mirrors the started station")
        check(session.fires == 1, "starting a session invalidates hasSession readers once")

        let generation = machine.generation
        machine.playerStarted(generation: generation)
        status.publish(machine)
        // AVPlayer reports .playing again after every stall; repeats change nothing.
        for _ in 0..<20 {
            machine.playerStarted(generation: generation)
            check(!status.publish(machine), "a repeated player-started event publishes nothing")
        }
        check(status.state == .playing, "status reaches playing")
        check(stateProbe.fires == 2, "state readers see connecting and playing only, not 20 repeats")
        check(session.fires == 1, "playing does not invalidate hasSession readers (the root Now Playing slot)")

        // Stalls and reconnects change state, not the session.
        _ = machine.playerFailed(generation: machine.generation)
        status.publish(machine)
        _ = machine.reconnectDue(generation: machine.generation)
        machine.playerStarted(generation: machine.generation)
        status.publish(machine)
        check(status.state == .playing, "reconnect returns to playing")
        check(session.fires == 1 && stationProbe.fires == 1,
              "a reconnect leaves hasSession and station readers untouched")

        _ = machine.pause()
        status.publish(machine)
        _ = machine.resume()
        status.publish(machine)
        check(session.fires == 1, "pause and resume keep the radio bar mounted without invalidating the slot")
        check(activeProbe.fires >= 2, "isActive readers (theme music) still see pause and resume")

        _ = machine.stop()
        check(status.publish(machine), "stopping publishes")
        check(!status.hasSession && status.station == nil && status.state == .idle && !status.isActive,
              "stop clears the session")
        check(session.fires == 2, "stopping invalidates hasSession readers once")
        check(status.publishCount < status.transitionCount,
              "instrumentation counts skipped publishes (\(status.publishCount) of \(status.transitionCount))")
    }

    // MARK: Pushed page policy

    static func pushedRadioPageBarPolicy() {
        check(KyroAudioDestination.pageHostsNowPlayingBar(isSecondaryDestination: true, shelfCoversPushedPages: false),
              "Radio pushed from More, Home or the profile menu shows its own bar")
        check(!KyroAudioDestination.pageHostsNowPlayingBar(isSecondaryDestination: false, shelfCoversPushedPages: false),
              "Radio as the fourth tab relies on the tab bar accessory (no duplicate)")
        check(!KyroAudioDestination.pageHostsNowPlayingBar(isSecondaryDestination: true, shelfCoversPushedPages: true),
              "the iPad sidebar layout's page-wide bar is not duplicated")
        check(!KyroAudioDestination.pageHostsNowPlayingBar(isSecondaryDestination: false, shelfCoversPushedPages: true),
              "a tab under the sidebar layout adds no bar")
        // Every Radio entry point either selects the tab or pushes the secondary route.
        check(KyroAudioDestination.radio.openTarget(unifiedShell: true, tabDestinations: [.home, .movies, .series, .radio, .liveTV]) == .tab,
              "Radio as the fourth tab opens the tab")
        check(KyroAudioDestination.radio.openTarget(unifiedShell: true, tabDestinations: [.home, .movies, .series, .sports, .liveTV]) == .secondaryRoute,
              "Radio from More opens the pushed route, which hosts its own bar")
        check(KyroAudioDestination.radio.openTarget(unifiedShell: false, tabDestinations: []) == .secondaryRoute,
              "legacy and iPad entry points push the route")
    }

    // MARK: Source contracts

    static func sourceContracts() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        func body(of type: String, in text: String) -> String {
            guard let start = text.range(of: type) else { return "" }
            let rest = text[start.lowerBound...]
            let end = rest.range(of: "\n}\n")?.upperBound ?? rest.endIndex
            return String(rest[..<end])
        }

        let player = try source("iosApp/iosApp/Kyro/Radio/KyroRadioPlayer.swift")
        check(player.contains("@ObservationIgnored private(set) var machine"), "the transport machine is not observed")
        check(player.contains("var hasSession: Bool { status.hasSession }")
              && player.contains("var state: KyroRadioPlaybackState { status.state }")
              && player.contains("var station: KyroRadioStation? { status.station }"),
              "views read the published status, not the machine")
        check(player.contains("status.publish(machine)"), "every transition publishes through the status")
        check(player.contains("if machine != beforeMachine { updateSystemMedia() }"),
              "no-op transitions skip the Lock Screen update")
        check(player.contains("guard next != track else { return }"), "stream metadata only writes a changed track")

        let shelf = try source("iosApp/iosApp/Control/iOS/NowPlayingShelf.swift")
        check(shelf.contains("KyroRadioPlayer.shared.hasSession"), "the app-wide slot reads only hasSession")
        check(!shelf.contains("KyroRadioPlayer.shared.state") && !shelf.contains("KyroRadioPlayer.shared.track"),
              "the app-wide slot never reads fast-changing radio state")
        check(shelf.contains("@Entry var nowPlayingShelfCoversPushedPages = false"), "page-wide bar flag exists")

        let theme = try source("iosApp/iosApp/Screens/Detail/ThemeMusic/ThemeMusicPageModifier.swift")
        check(theme.contains("KyroRadioPlayer.shared.isActive") && !theme.contains(".machine."),
              "theme music reads isActive, not the machine")

        let views = try source("iosApp/iosApp/Kyro/Radio/KyroRadioViews.swift")
        let rail = body(of: "struct KyroHomeRadioRail: View", in: views)
        check(!rail.isEmpty && !rail.contains("player.isPlaying") && !rail.contains("player.station")
              && !rail.contains("player.state"),
              "the Home radio shelf body reads no playback state")
        check(rail.contains("KyroHomeRadioPlayBadge(stationID: station.id)"), "each Home card's badge observes playback alone")
        let mini = body(of: "struct KyroRadioMiniPlayerView: View", in: views)
        check(mini.contains("decodeSize: KyroRadioMiniPlayerView.artworkDecodeSize"),
              "the radio bar decodes its logo once for both bar sizes")
        check(mini.contains("player.isShowingNowPlaying = true"), "tapping the bar opens the existing Now Playing")
        check(mini.contains("KyroRadioTransportButton"), "the bar keeps play and pause")
        check(mini.contains("KyroRadioStatusText.line(player: player)"), "the bar keeps track metadata")
        let radioView = body(of: "struct KyroRadioView: View", in: views)
        check(radioView.contains("inlineSearchRow") && radioView.contains("KyroAudioSearchField") &&
              !radioView.contains(".searchable("), "all Radio routes use inline search without a bottom search bar")
        check(radioView.contains(".safeAreaInset(edge: .bottom, spacing: 0)"),
              "the page bar is a bottom safe-area inset, which reserves scroll space")
        check(radioView.contains("KyroAudioDestination.pageHostsNowPlayingBar("), "the page follows the bar policy")
        let pageBar = body(of: "struct KyroRadioPageNowPlayingBar: View", in: views)
        check(pageBar.contains("NowPlayingShelf(style: .card)"), "the page bar is the app's single Now Playing shelf")
        check(pageBar.contains("keyboardWillShowNotification") && pageBar.contains("VStack(spacing: 0)"),
              "the page bar steps aside for the keyboard and keeps observing it")
        check(!views.contains("KyroRadioPlayer()"), "no second radio player is created")

        let content = try source("iosApp/iosApp/ContentView.swift")
        check(content.contains(".environment(\\.nowPlayingShelfCoversPushedPages, true)"),
              "the iPad sidebar layout marks its page-wide bar")
        check(content.components(separatedBy: ".modifier(KyroRadioNowPlayingPresentation())").count == 2,
              "Now Playing is presented from one place")
        check(content.contains("String(describing: destination.id)"), "More item ids carry the destination identity")

        let more = try source("iosApp/iosApp/Kyro/Shell/KyroMoreMenu.swift")
        check(more.contains("struct KyroMoreMenuContext: Equatable"), "the More menu environment value is Equatable")

        // Build 126 sports sizing must not regress (Build 125 clipping).
        let rails = try source("iosApp/iosApp/Kyro/Home/KyroHomeShelves.swift")
        check(rails.contains("KyroHomeRail(title: shelf.title, sizing: .tallestCard)"),
              "sports shelves keep tallest-card sizing")

    }
}
#endif
