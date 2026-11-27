#if os(iOS) || KYRO_STANDALONE_TESTS
import Foundation
import Observation

enum KyroRadioPlaybackError: Equatable, Sendable {
    case unsupportedFormat
    case noStream
    /// Every stream address and reconnection attempt failed.
    case streamFailed

    var message: String {
        switch self {
        case .unsupportedFormat: "This station uses a stream format Kyro can’t play."
        case .noStream: "This station has no playable stream address."
        case .streamFailed: "Couldn’t connect to this station. Check your connection, then try again."
        }
    }
}

enum KyroRadioPlaybackState: Equatable, Sendable {
    case idle
    case connecting
    case playing
    case paused
    case reconnecting(attempt: Int)
    case failed(KyroRadioPlaybackError)

    /// The player is fetching or playing audio.
    var isActive: Bool {
        switch self {
        case .connecting, .playing, .reconnecting: true
        case .idle, .paused, .failed: false
        }
    }
}

/// Radio's transport rules, without AVFoundation, so they can be tested on
/// the host. Every player event carries the generation of the load it
/// belongs to; a stale event (an older station, a load replaced by a
/// reconnect) is ignored.
///
/// Live radio has no seeking: Pause stops fetching, and Play reconnects at
/// the live edge rather than resuming minutes-old buffered audio.
struct KyroRadioPlaybackMachine: Equatable, Sendable {
    static let maxReconnectAttempts = 3

    enum Effect: Equatable, Sendable {
        /// Load the station's stream at `candidate` (an index into
        /// `KyroRadioStation.playbackCandidates`) for `generation`.
        case load(candidate: Int, generation: Int)
        case pausePlayer
        case stopPlayer
        case scheduleReconnect(delay: TimeInterval, generation: Int)
        /// The station started from a listener's tap (history, click report).
        case recordStart
    }

    private(set) var state: KyroRadioPlaybackState = .idle
    private(set) var station: KyroRadioStation?
    private(set) var generation = 0
    private(set) var candidate = 0
    private(set) var reconnectAttempts = 0
    /// Paused by an interruption (a call), not by the listener.
    private(set) var resumesAfterInterruption = false

    var isActive: Bool { state.isActive }

    /// Pausing drops the live connection, not the system-audio session.
    /// A parked station can reconnect at the live edge without losing its
    /// Lock Screen entry. Yield and Stop release the binding separately.
    var retainsAudioForSystemTransport: Bool { isActive || state == .paused }

    /// A listener chose a station.
    mutating func play(_ station: KyroRadioStation) -> [Effect] {
        self.station = station
        resumesAfterInterruption = false
        reconnectAttempts = 0
        candidate = 0
        guard !station.playbackCandidates.isEmpty else {
            generation += 1
            state = .failed(.noStream)
            return [.stopPlayer]
        }
        guard station.isPlayable else {
            generation += 1
            state = .failed(.unsupportedFormat)
            return [.stopPlayer]
        }
        return [.recordStart] + connect()
    }

    /// Play after Pause or a failure: reconnect at the live edge.
    mutating func resume() -> [Effect] {
        guard station != nil else { return [] }
        switch state {
        case .paused, .failed(.streamFailed):
            resumesAfterInterruption = false
            reconnectAttempts = 0
            candidate = 0
            return connect()
        default:
            return []
        }
    }

    mutating func pause() -> [Effect] {
        guard station != nil, state.isActive else { return [] }
        resumesAfterInterruption = false
        generation += 1
        state = .paused
        return [.pausePlayer]
    }

    mutating func togglePlayPause() -> [Effect] {
        state.isActive ? pause() : resume()
    }

    mutating func stop() -> [Effect] {
        guard station != nil || state != .idle else { return [] }
        generation += 1
        station = nil
        state = .idle
        resumesAfterInterruption = false
        return [.stopPlayer]
    }

    mutating func playerStarted(generation: Int) {
        guard generation == self.generation, state == .connecting || isReconnecting else { return }
        state = .playing
        reconnectAttempts = 0
    }

    /// The stream failed or stalled. Another address of the same station is
    /// tried first; then up to `maxReconnectAttempts` reconnections with
    /// growing delays; then a clear failure with Retry.
    mutating func playerFailed(generation: Int) -> [Effect] {
        guard generation == self.generation, state.isActive, let station else { return [] }
        if state == .connecting, candidate + 1 < station.playbackCandidates.count {
            candidate += 1
            self.generation += 1
            return [.load(candidate: candidate, generation: self.generation)]
        }
        guard reconnectAttempts < Self.maxReconnectAttempts else {
            self.generation += 1
            state = .failed(.streamFailed)
            return [.stopPlayer]
        }
        reconnectAttempts += 1
        self.generation += 1
        state = .reconnecting(attempt: reconnectAttempts)
        let delay = pow(2, Double(reconnectAttempts - 1))
        return [.stopPlayer, .scheduleReconnect(delay: delay, generation: self.generation)]
    }

    mutating func reconnectDue(generation: Int) -> [Effect] {
        guard generation == self.generation, isReconnecting else { return [] }
        return [.load(candidate: candidate, generation: generation)]
    }

    /// A call or another app took audio.
    mutating func interruptionBegan() -> [Effect] {
        guard state.isActive else { return [] }
        let effects = pause()
        resumesAfterInterruption = true
        return effects
    }

    /// The system says whether it's appropriate to resume.
    mutating func interruptionEnded(shouldResume: Bool) -> [Effect] {
        guard state == .paused, resumesAfterInterruption else { return [] }
        resumesAfterInterruption = false
        return shouldResume ? resume() : []
    }

    /// Headphones or a Bluetooth device went away: pause, as Apple's apps do.
    mutating func outputRouteLost() -> [Effect] {
        pause()
    }

    /// Video, Live TV or an audiobook started: radio pauses and releases audio.
    mutating func yieldToOtherPlayback() -> [Effect] {
        pause()
    }

    private var isReconnecting: Bool {
        if case .reconnecting = state { return true }
        return false
    }

    private mutating func connect() -> [Effect] {
        generation += 1
        state = .connecting
        return [.load(candidate: candidate, generation: generation)]
    }
}

/// Build 130: the radio state views observe, published apart from the
/// transport machine. `KyroRadioPlayer` writes its machine on every event,
/// including no-op ones (radio yielding while already idle whenever video,
/// Live TV or an audiobook starts, a repeated "player started"). Views that
/// only need to know whether a radio bar exists (the app-wide Now Playing
/// slot) read `hasSession`, which changes only when a session starts or ends.
@MainActor @Observable
final class KyroRadioPlaybackStatus {
    private(set) var station: KyroRadioStation?
    private(set) var state: KyroRadioPlaybackState = .idle
    /// A station is loaded (playing, paused or failed): a radio bar shows.
    private(set) var hasSession = false
    /// Radio is fetching or playing audio.
    private(set) var isActive = false

    /// Lightweight instrumentation: machine transitions seen, and how many
    /// changed something a view observes.
    @ObservationIgnored private(set) var transitionCount = 0
    @ObservationIgnored private(set) var publishCount = 0

    init() {}

    /// Copies `machine` into the observed fields, writing only those that
    /// changed so unrelated observers stay valid. Returns whether any changed.
    @discardableResult
    func publish(_ machine: KyroRadioPlaybackMachine) -> Bool {
        transitionCount += 1
        var changed = false
        if station != machine.station { station = machine.station; changed = true }
        if state != machine.state { state = machine.state; changed = true }
        let session = machine.station != nil
        if hasSession != session { hasSession = session; changed = true }
        if isActive != machine.isActive { isActive = machine.isActive; changed = true }
        if changed { publishCount += 1 }
        return changed
    }
}

/// Keeps radio from playing alongside other playback. Radio yields whenever
/// Silo video, Live TV, Sports or an audiobook starts, and starting radio
/// pauses those. The other players keep their existing rules with each
/// other; only radio's relationship to them is new.
@MainActor
final class KyroPlaybackExclusivity {
    enum Source: Equatable, Sendable {
        case radio
        case podcast
        case video
        case liveTV
        case audiobook
    }

    static let shared = KyroPlaybackExclusivity()

    private struct Entry {
        weak var owner: AnyObject?
        let source: Source
        let yield: @MainActor () -> Void
    }

    private var entries: [Entry] = []

    init() {}

    /// An owner that can be asked to stop. Held weakly; registering again
    /// replaces the earlier entry.
    func register(_ owner: AnyObject, source: Source, yield: @escaping @MainActor () -> Void) {
        entries.removeAll { $0.owner == nil || $0.owner === owner }
        entries.append(Entry(owner: owner, source: source, yield: yield))
    }

    func unregister(_ owner: AnyObject) {
        entries.removeAll { $0.owner == nil || $0.owner === owner }
    }

    /// `owner` is starting playback. Returns the sources asked to yield.
    @discardableResult
    func begin(_ owner: AnyObject, source: Source) -> [Source] {
        entries.removeAll { $0.owner == nil }
        let others = entries.filter { entry in
            guard entry.owner !== owner else { return false }
            // Keep the existing relationships among the other players.
            return source == .radio || entry.source == .radio || source == .podcast || entry.source == .podcast
        }
        others.forEach { $0.yield() }
        return others.map(\.source)
    }
}
#endif
