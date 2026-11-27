#if KYRO_STANDALONE_TESTS
import Foundation

// Build 132 host checks: player theme persistence and Settings Backup, the
// playback-state-driven turntable motion (including Reduce Motion and the
// animation lifecycle), and source contracts for the redesign's limits.

@main @MainActor
enum KyroBuild132HostChecks {
    static var count = 0
    static func check(_ condition: Bool, _ title: String) {
        precondition(condition, title)
        count += 1
    }

    static func main() throws {
        themePersistence()
        themeBackup()
        turntableMotion()
        try sourceContracts()
        print("Build 132: \(count) theme, backup, turntable motion and source checks passed.")
    }

    static func freshDefaults() -> UserDefaults {
        let suite = "kyro.build132.\(UUID())"
        return UserDefaults(suiteName: suite)!
    }

    // MARK: Theme persistence

    static func themePersistence() {
        let defaults = freshDefaults()
        check(KyroRadioPlayerTheme.default == .crimsonNoir, "Crimson Noir is the default theme")
        check(KyroRadioPlayerTheme.allCases == [.crimsonNoir, .classicWalnut, .modernStream],
              "three themes in display order")
        let appearance = KyroRadioPlayerAppearance(defaults: defaults)
        check(appearance.theme == .crimsonNoir, "a fresh install starts on Crimson Noir")
        appearance.select(.classicWalnut)
        check(appearance.theme == .classicWalnut, "selecting applies immediately")
        check(KyroRadioPlayerAppearance(defaults: defaults).theme == .classicWalnut, "the choice persists across launches")
        defaults.set("vaporwave", forKey: KyroRadioPlayerAppearance.key)
        check(KyroRadioPlayerAppearance(defaults: defaults).theme == .crimsonNoir, "an unknown stored theme falls back to the default")
        check(KyroRadioPlayerAppearance.key == "kyrox.radio.playerTheme.v1", "theme has its own storage key")
    }

    // MARK: Settings Backup

    static func themeBackup() {
        let defaults = freshDefaults()
        let appearance = KyroRadioPlayerAppearance(defaults: defaults)
        let library = KyroRadioLibrary(defaults: defaults)
        let settings = KyroRadioBackupSettings.make(library: library, defaults: defaults, appearance: appearance)
        guard let theme = settings.first(where: { $0.id == "radio.playerTheme" }) else {
            check(false, "radio.playerTheme backup entry exists"); return
        }
        check(theme.group == .radio && !SettingsBackupSafety.isSensitiveName(theme.id), "theme backs up in the Radio group")
        check(theme.read() == .string("crimsonNoir"), "a default install backs up Crimson Noir")
        appearance.select(.classicWalnut)
        let saved = theme.read()!
        check(saved == .string("classicWalnut") && !SettingsBackupSafety.isSuspiciousValue(saved), "the chosen theme backs up as plain text")

        // Restore onto another device.
        let otherDefaults = freshDefaults()
        let other = KyroRadioPlayerAppearance(defaults: otherDefaults)
        let otherSettings = KyroRadioBackupSettings.make(library: KyroRadioLibrary(defaults: otherDefaults),
                                                         defaults: otherDefaults, appearance: other)
        let restore = otherSettings.first { $0.id == "radio.playerTheme" }!
        check(restore.validate(saved), "a saved theme validates")
        try? restore.write(saved)
        check(other.theme == .classicWalnut && KyroRadioPlayerAppearance(defaults: otherDefaults).theme == .classicWalnut,
              "restoring applies and persists the theme")
        check(!restore.validate(.string("vaporwave")) && !restore.validate(.bool(true)), "unknown themes and wrong types are rejected")
        check(restore.label(saved) == "Classic Walnut", "restore preview names the theme")

        // Backward compatibility: earlier entries are unchanged, and a backup without the
        // theme (Builds 128–131) leaves the device's theme alone.
        check(settings.map(\.id) == ["radio.favorites", "radio.preferences", "radio.homeShelves", "radio.playerTheme", "radio.musicSources", "radio.homeShelfLimits"],
              "earlier Radio backup entries keep their IDs and order")
        let untouched = KyroRadioPlayerAppearance(defaults: freshDefaults())
        check(untouched.theme == .crimsonNoir, "a backup without the theme keeps the default")
    }

    // MARK: Turntable motion

    static func turntableMotion() {
        typealias M = KyroTurntableMotion
        let playing = M.motion(for: .playing, reduceMotion: false)
        check(playing.platter == .spinning && playing.tonearm == .playing && playing.lamp == .on && playing.animates,
              "playing: record turns, arm in the grooves, lamp lit")
        for state in [KyroRadioPlaybackState.connecting, .reconnecting(attempt: 2)] {
            let motion = M.motion(for: state, reduceMotion: false)
            check(motion.platter == .stopped && motion.tonearm == .cued && motion.lamp == .blinking,
                  "\(state): no audio yet, so the record does not turn; arm cued; lamp blinks")
        }
        let paused = M.motion(for: .paused, reduceMotion: false)
        check(paused.platter == .stopped && paused.tonearm == .rest && paused.lamp == .off && paused.animates,
              "paused: record coasts to a stop, arm returns to rest")
        let failed = M.motion(for: .failed(.streamFailed), reduceMotion: false)
        check(failed.platter == .stopped && failed.tonearm == .rest && failed.lamp == .fault, "failed: stopped, fault lamp")
        let idle = M.motion(for: .idle, reduceMotion: false)
        check(idle.platter == .stopped && idle.tonearm == .rest && idle.lamp == .off, "idle: at rest")

        // Reduce Motion: the record never turns, the arm still shows the state without animating.
        let still = M.motion(for: .playing, reduceMotion: true)
        check(still.platter == .stopped && still.tonearm == .playing && !still.animates, "Reduce Motion keeps the record still")
        check(M.motion(for: .connecting, reduceMotion: true).lamp == .on, "Reduce Motion: no blinking lamp")

        // Lifecycle: off screen or in the background nothing turns.
        check(M.platterRuns(playing, isVisible: true, isAppActive: true), "visible and active: turns")
        check(!M.platterRuns(playing, isVisible: false, isAppActive: true), "dismissed: stops")
        check(!M.platterRuns(playing, isVisible: true, isAppActive: false), "background: stops")
        check(!M.platterRuns(paused, isVisible: true, isAppActive: true), "paused: does not turn")

        check(M.tonearmDegrees(.rest) < M.tonearmDegrees(.cued) && M.tonearmDegrees(.cued) < M.tonearmDegrees(.playing),
              "tonearm swings rest → cued → playing")
        check(abs(60 / M.secondsPerRevolution - 100.0 / 3) < 0.1, "33⅓ rpm")
        check(M.spinUpSeconds > 0 && M.slowDownSeconds > M.spinUpSeconds, "gradual spin-up and longer coast-down")
    }

    // MARK: Source contracts

    static func sourceContracts() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        func source(_ path: String) throws -> String { try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }

        let turntable = try source("iosApp/iosApp/Kyro/Radio/KyroRadioTurntable.swift")
        // Only the expanded player animates, with Core Animation; no timers or frame loops.
        for forbidden in ["Timer.", "TimelineView", "CADisplayLink", "DispatchSourceTimer", "repeatForever(autoreverses: false)"] {
            check(!turntable.contains(forbidden), "no \(forbidden) in the turntable")
        }
        check(turntable.contains("CABasicAnimation(keyPath: \"transform.rotation.z\")"), "record turns with Core Animation")
        check(turntable.contains("static func dismantleUIView(_ view: KyroVinylPlatterUIView, coordinator: ()) { view.freeze() }"),
              "dismissing the player removes the record's animations")
        check(turntable.contains("isLive: isVisible && scenePhase == .active"), "the background and dismissal stop the record")
        check(turntable.contains("@Environment(\\.accessibilityReduceMotion) private var reduceMotion"), "Reduce Motion is honoured")
        check(turntable.contains("Task.detached(priority: .userInitiated) { drawRecord")
              && turntable.contains("Task.detached(priority: .userInitiated) { drawWood"),
              "grooves and grain are drawn once, off the main thread")
        check(turntable.contains("spinLayer.shouldRasterize = true"), "the static record content is rasterised once")
        // Live radio: no fake track controls, progress or waveform.
        for symbol in ["\"backward.fill\"", "\"forward.fill\"", "\"shuffle\"", "\"repeat\"", "\"waveform", "ProgressView(value"] {
            check(!turntable.contains(symbol), "no \(symbol) in the live radio player")
        }
        // Working controls stay.
        check(turntable.contains("player.stop(); dismiss()"), "Stop stops and closes, as before")
        check(turntable.contains("library.toggleFavorite(station)"), "Save to Library")
        check(turntable.contains("AVRoutePickerView()") && turntable.contains("MPVolumeView("), "AirPlay/output picker and system volume")
        check(turntable.contains("player.track") && turntable.contains("station?.formatLine"), "real song metadata and codec/bitrate")
        check(turntable.contains("Text(\"LIVE\")"), "live indicator")
        check(turntable.contains("accessibilityIdentifier(\"kyroRadioNowPlaying\")"), "Now Playing keeps its identifier")

        let views = try source("iosApp/iosApp/Kyro/Radio/KyroRadioViews.swift")
        check(!views.contains("struct KyroRadioNowPlayingView"), "one Now Playing view")
        check(views.contains("KyroRadioNowPlayingView()\n                .presentationDetents([.large])"),
              "Now Playing is presented as before (sheet, large detent)")
        check(views.contains("KyroRadioPlayerAppearanceSection()"), "Radio Settings has Player Appearance")
        let mini = views.components(separatedBy: "struct KyroRadioMiniPlayerView").last?
            .components(separatedBy: "private struct KyroRadioTransportButton").first ?? ""
        check(!mini.isEmpty && !mini.contains("Appearance") && !mini.contains("KyroTurntable"),
              "the mini-player artwork and metadata do not observe the theme or render the turntable")

        let shelf = try source("iosApp/iosApp/Control/iOS/NowPlayingShelf.swift")
        let shelves = try source("iosApp/iosApp/Kyro/Home/KyroHomeShelves.swift")
        check(!shelf.contains("KyroRadioPlayerAppearance") && !shelves.contains("KyroRadioPlayerAppearance"),
              "Home and the app-wide slot never observe the theme")
        check(shelves.contains("ForEach(KyroHomeSportsHeightProbe.games(games))"), "Build 131 sports rail fix stays")

    }
}
#endif
