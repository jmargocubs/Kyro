#if KYRO_STANDALONE_TESTS
import Foundation

@main @MainActor
enum KyroBuild141HostChecks {
    private static var checks = 0
    private static func check(_ result: Bool, _ name: String) {
        precondition(result, name)
        checks += 1
    }

    static func main() throws {
        artwork()
        playback()
        try navigation()
        floatingPills()
        try wiring()
        print("Build 141: \(checks) artwork, transport, navigation, backup and wiring checks passed.")
    }

    private static func artwork() {
        let styles = [KyroMusicSourceArtwork.style(for: nil)] + KyroMusicCollection.allCases.map {
            KyroMusicSourceArtwork.style(for: $0)
        }
        check(Set(styles.map(\.symbol)).count == 6, "each source has a distinct symbol")
        check(Set(styles.map(\.highlight)).count == 6 && Set(styles.map(\.accent)).count == 6,
              "all cards have independent local palettes")
        check(styles.first?.symbol == "radio", "Internet Radio uses a recognizable radio")
        let sirius = KyroMusicSourceArtwork.style(for: .siriusXM).highlight
        check(sirius & 255 > (sirius >> 16) & 255, "SiriusXM uses blue")
    }

    private static func playback() {
        let source = URL(string: "https://music.example/live/7.ts")!
        let provider = UUID()
        var station = KyroRadioStation(id: "station-7", name: "Live jazz", streamURL: source)
        station.iptv = .init(providerID: provider, providerName: "Fixtures", channelID: station.id,
                             collection: .siriusXM, category: "Jazz", guideID: nil)
        var machine = KyroRadioPlaybackMachine()
        let selected = machine.play(station)
        check(selected == [.recordStart, .load(candidate: 0, generation: 1)], "uses original provider stream")
        machine.playerStarted(generation: 1)
        let paused = machine.pause()
        check(paused == [.pausePlayer] && machine.state == .paused && machine.station == station &&
              machine.retainsAudioForSystemTransport && !machine.isActive, "pause retains metadata and transport, but does not fetch")
        check(machine.playerFailed(generation: 1).isEmpty, "old audio callbacks cannot evict a paused station")
        let resumed = machine.resume()
        check(resumed == [.load(candidate: 0, generation: 3)] && machine.station == station, "play reconnects same station")
        let toggledPause = machine.togglePlayPause()
        let toggledPlay = machine.togglePlayPause()
        check(toggledPause == [.pausePlayer] && toggledPlay == [.load(candidate: 0, generation: 5)], "toggle pauses and reconnects")
        let stopped = machine.stop()
        check(stopped == [.stopPlayer] && machine.station == nil && !machine.retainsAudioForSystemTransport,
              "explicit stop clears station and does not retain system audio")

        let arbitration = KyroPlaybackExclusivity()
        let radio = NSObject(), podcast = NSObject()
        var yielded: [String] = []
        arbitration.register(radio, source: .radio) { yielded.append("radio") }
        arbitration.register(podcast, source: .podcast) { yielded.append("podcast") }
        arbitration.begin(radio, source: .radio)
        arbitration.begin(podcast, source: .podcast)
        check(yielded == ["podcast", "radio"], "Radio and Podcasts still yield in both directions")
    }

    private static func navigation() throws {
        let suite = UserDefaults(suiteName: "kyro.141.\(UUID())")!
        suite.set(Data(#"{"schemaVersion":1,"style":"thumbFan","autoCollapse":false,"fourthTab":"podcasts"}"#.utf8),
                  forKey: KyroGlobalNavigationStore.defaultsKey)
        let store = KyroGlobalNavigationStore(defaults: suite)
        check(KyroPrimaryTabs.standard.all == [.home, .movies, .series, .sports, .liveTV], "existing default preserved")
        check(store.tabDestinations == [.home, .movies, .series, .podcasts, .liveTV] &&
              store.preferences.style == .thumbFan && !store.preferences.autoCollapse, "legacy fourth tab and pill settings retained")
        check(store.selectIfTab(.podcasts), "legacy selected tab is reachable")
        store.preferences.primaryTabs.remove(.movies)
        store.preferences.primaryTabs.add(.radio)
        store.preferences.primaryTabs.move(.radio, by: -1)
        check(store.tabDestinations == [.home, .series, .podcasts, .radio, .liveTV], "Radio and Podcasts share the bar in chosen order")
        check(store.selectedDestination == .podcasts, "reordering keeps the selected tab")
        store.preferences.primaryTabs.add(.favorites)
        store.preferences.primaryTabs.add(.radio)
        check(store.tabDestinations.count == 5 && !store.tabDestinations.contains(.favorites), "cannot exceed capacity or repeat a tab")
        let more = KyroGlobalDestination.moreDestinations(primary: store.tabDestinations)
        check(more == [.movies, .sports, .forYou, .favorites], "unpinned destinations remain reachable exactly once")
        check(KyroGlobalDestination.moreDestinations(primary: [.home]) == KyroGlobalDestination.primaryChoices,
              "all supported destinations are accessible even when only Home is pinned")
        let reloaded = KyroGlobalNavigationStore(defaults: suite)
        check(reloaded.tabDestinations == store.tabDestinations, "order persists across a reload")
        reloaded.preferences.primaryTabs.remove(.liveTV)
        check(!reloaded.selectIfTab(.liveTV) && KyroGlobalDestination.moreDestinations(primary: reloaded.tabDestinations).contains(.liveTV),
              "unpinned Live TV is not selected as a nonexistent tab")
        check(KyroPrimaryTabs([.home]) == nil && KyroPrimaryTabs([.radio, .radio]) == nil, "reject invalid model identities")

        let setting = KyroPrimaryTabsBackup.setting(store: reloaded)
        let value = setting.read()!
        let app = SettingsBackupAppInfo(version: "1.0.141", build: "141", platform: "iOS", idiom: "phone")
        let bytes = try SettingsBackupCodec.makeUnifiedDocument(
            groups: ["navigation": [setting.id: value]], scope: nil, app: app, now: Date())
        let incoming = try SettingsBackupCodec.decode(bytes)
        check(incoming.groups["navigation"]?[setting.id] == value, "ordered backup round trip")
        let old = setting.normalize(.string("radio"))
        try setting.write(old)
        check(reloaded.tabDestinations == [.home, .movies, .series, .radio, .liveTV] && setting.read() == old,
              "legacy backups normalize to the old layout, with read-after-write verification")
        try setting.write(value)
        check(setting.read() == value, "a rollback can restore the complete former arrangement")
        check(!setting.validate(.array([.string("radio"), .string("radio")])) &&
              !setting.validate(.array([.string("unknown")])), "bad backups cannot corrupt the layout")
        reloaded.preferences.primaryTabs = .standard
        check(reloaded.tabDestinations == KyroPrimaryTabs.standard.all && reloaded.preferences.style == .thumbFan,
              "reset affects tabs, not pill settings")
    }

    private static func wiring() throws {
        func read(_ path: String) throws -> String {
            try String(contentsOfFile: "iosApp/iosApp/" + path, encoding: .utf8)
        }
        let player = try read("Kyro/Radio/KyroRadioPlayer.swift")
        let arbiter = try read("Screens/Player/AetherVideoNowPlayingCoordinator.swift")
        let sources = try read("Kyro/Radio/KyroIPTVMusic.swift")
        let content = try read("ContentView.swift")
        let props = try Data(contentsOf: URL(fileURLWithPath: "iosApp/iosApp/Info.plist"))
        let plist = try PropertyListSerialization.propertyList(from: props, format: nil) as? [String: Any]
        check((plist?["UIBackgroundModes"] as? [String])?.contains("audio") == true &&
              player.contains("session.setCategory(.playback"), "iOS audio background mode and audio session configured")
        check(player.contains("add(center.pauseCommand) { $0.pause() }") &&
              player.contains("add(center.playCommand) { $0.resume() }") &&
              player.contains("add(center.togglePlayPauseCommand)"), "distinct remote pause, play and toggle")
        check(player.contains("center.stopCommand.isEnabled = false") &&
              player.contains("center.changePlaybackPositionCommand.isEnabled = false") &&
              player.contains("center.skipForwardCommand.isEnabled = false") &&
              player.contains("center.skipBackwardCommand.isEnabled = false"), "no destructive or invalid live commands advertised")
        check(player.contains("case .pausePlayer:\n            tearDownPlayer()\n        case .stopPlayer:") &&
              player.contains("self.commandBinding == binding") && player.contains("isCurrentClaimant(self)"),
              "paused transport is retained and stale queued events cannot route after ownership changes")
        check(arbiter.contains("if !isCurrentClaimant(owner)") && arbiter.contains("next.restore()"),
              "suspended owner cannot disable a current owner's commands")
        check(sources.contains("KyroMusicSourceCover(style: .style(for: collection))") &&
              sources.contains("size: 132") && sources.contains("library.providerNames(collection)"),
              "offline cover replaces art only and keeps sizing and provider labels")
        check(content.contains("KyroGlobalDestination.moreDestinations(primary: kyroNavigation.tabDestinations)") &&
              content.contains("case .favorites: .favorites") &&
              content.contains("case .liveTV: .liveTV"),
              "More has a pushed route for every unpinned destination")
        check(content.contains("LiveTVView(service: .shared, isPushedFromShell: true)") &&
              content.contains(".modifier(NowPlayingShelfAttachment"), "unpinned Live TV has a back path and the shared accessory remains")
    }

    private static func floatingPills() {
        let bounds = CGRect(x: 0, y: 0, width: 393, height: 760)
        let geometry = KyroNavigationGeometry(bounds: bounds)
        for edge in KyroNavigationEdge.allCases {
            let anchor = KyroNavigationAnchor.default(for: edge)
            let dock = geometry.dockLayout(for: anchor, itemCount: 5)
            let fan = geometry.fanLayout(for: anchor, itemCount: 5)
            check(dock.itemCenters.count == 5 && dock.itemCenters.allSatisfy { bounds.contains($0) },
                  "\(edge) dock retains all targets inside the safe area")
            check(fan.itemCenters.count == 5 && fan.itemCenters.allSatisfy { bounds.contains($0) },
                  "\(edge) fan retains all targets inside the safe area")
        }
    }
}
#endif
