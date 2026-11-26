#if os(iOS) || KYRO_STANDALONE_TESTS
import Foundation
import Observation

/// Build 132: the expanded Radio player's look. Both themes share one layout;
/// only colours, materials and hardware finish differ.
enum KyroRadioPlayerTheme: String, CaseIterable, Identifiable, Sendable {
    case crimsonNoir
    case classicWalnut

    /// Crimson Noir until the listener picks another.
    static let `default`: Self = .crimsonNoir

    var id: String { rawValue }

    var title: String {
        switch self {
        case .crimsonNoir: "Crimson Noir"
        case .classicWalnut: "Classic Walnut"
        }
    }

    var subtitle: String {
        switch self {
        case .crimsonNoir: "Burgundy, matte black and rose-gold metal"
        case .classicWalnut: "Walnut wood, brass and cream panels"
        }
    }
}

/// The chosen player theme, kept apart from Radio's library so a theme change
/// redraws only the views that read it (the expanded player and the Settings
/// previews), never the mini-player or Home.
@MainActor @Observable
final class KyroRadioPlayerAppearance {
    static let shared = KyroRadioPlayerAppearance()
    static let key = "kyrox.radio.playerTheme.v1"

    private(set) var theme: KyroRadioPlayerTheme
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        theme = Self.load(from: defaults)
    }

    /// An unknown or missing value (a newer build's theme, a fresh install) is the default.
    static func load(from defaults: UserDefaults) -> KyroRadioPlayerTheme {
        defaults.string(forKey: key).flatMap(KyroRadioPlayerTheme.init(rawValue:)) ?? .default
    }

    func select(_ theme: KyroRadioPlayerTheme) {
        guard theme != self.theme else { return }
        self.theme = theme
        defaults.set(theme.rawValue, forKey: Self.key)
    }

    /// Re-reads the stored theme (after a settings restore).
    func reload() { theme = Self.load(from: defaults) }
}

/// What the turntable does for each playback state. Pure, so the rules are
/// host-tested; the views only render it.
///
/// Live radio has no position, so nothing here simulates track progress: the
/// record turns only while audio plays, and the tonearm says whether Kyro is
/// connecting, playing or stopped.
struct KyroTurntableMotion: Equatable, Sendable {
    enum Platter: Equatable, Sendable {
        /// Turning at 33⅓ rpm.
        case spinning
        /// Coasting to a stop, or still.
        case stopped
    }

    enum Tonearm: Equatable, Sendable {
        /// On its rest, off the record.
        case rest
        /// Lifted over the lead-in while the stream connects or reconnects.
        case cued
        /// Down in the grooves.
        case playing
    }

    enum Lamp: Equatable, Sendable {
        case off
        /// Blinking while connecting (steady with Reduce Motion).
        case blinking
        case on
        case fault
    }

    var platter: Platter
    var tonearm: Tonearm
    var lamp: Lamp
    /// Whether changes animate. Reduce Motion moves the arm straight to its
    /// place and keeps the record still.
    var animates: Bool

    static let secondsPerRevolution: Double = 1.8 // 33⅓ rpm
    static let spinUpSeconds: Double = 1.0
    static let slowDownSeconds: Double = 2.4

    static func motion(for state: KyroRadioPlaybackState, reduceMotion: Bool) -> Self {
        let platter: Platter
        let tonearm: Tonearm
        let lamp: Lamp
        switch state {
        case .playing:
            platter = .spinning; tonearm = .playing; lamp = .on
        case .connecting, .reconnecting:
            platter = .stopped; tonearm = .cued; lamp = .blinking
        case .paused, .idle:
            platter = .stopped; tonearm = .rest; lamp = .off
        case .failed:
            platter = .stopped; tonearm = .rest; lamp = .fault
        }
        return Self(platter: reduceMotion ? .stopped : platter, tonearm: tonearm,
                    lamp: reduceMotion && lamp == .blinking ? .on : lamp, animates: !reduceMotion)
    }

    /// The record turns only while it should spin and the player is on screen
    /// in an active app. Off screen or in the background, nothing animates.
    static func platterRuns(_ motion: Self, isVisible: Bool, isAppActive: Bool) -> Bool {
        motion.platter == .spinning && isVisible && isAppActive
    }

    /// Tonearm angle in degrees, clockwise from its rest.
    static func tonearmDegrees(_ tonearm: Tonearm) -> Double {
        switch tonearm {
        case .rest: 0
        case .cued: 15
        case .playing: 24
        }
    }
}
#endif
