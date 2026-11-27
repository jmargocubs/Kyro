#if os(iOS)
import AetherEngine
import Combine
import Foundation
import OSLog

/// Build 140: plays IPTV music channels for Radio with AetherEngine, the
/// reader Live TV already uses for the same channels, instead of AVPlayer.
///
/// Before Build 140, Radio rewrote an Xtream `.ts` address to the provider's
/// `.m3u8` variant and played it with AVPlayer, holding only an 8-second
/// forward buffer. That is a different stream from the one Live TV and other
/// IPTV apps read, and a buffer shorter than a typical 10-second live segment.
/// Here the original address is read by FFmpeg (`LoadOptions.isLive`, so a
/// dropped connection is reconnected inside the engine and never reads as
/// the end of the stream), and only its audio is decoded, at the source's
/// own codec and bitrate, into `AVSampleBufferAudioRenderer`. No video is
/// decoded and nothing is transcoded.
///
/// It is a transport only. `KyroRadioPlayer` keeps the station, the
/// playback machine, Lock Screen controls and playback exclusivity, so there
/// is still one Radio session. `.software` keeps the engine on its FFmpeg
/// audio host, which has no Now Playing session of its own and so never
/// competes with Radio's.
@MainActor
final class KyroIPTVAudioEngine {
    enum Event: Equatable {
        /// Audio is moving.
        case playing
        /// Loading, rebuffering or reconnecting inside the engine.
        case waiting
        /// The engine gave up (error, or a live stream that ended).
        case failed
    }

    /// Called with the generation passed to `load`, so a late event from an
    /// earlier load is ignored by the caller.
    var onEvent: ((Event, Int) -> Void)?

    private var engine: AetherEngine?
    private var claim: AetherAudioSessionOwnership.Claim?
    private var cancellables: Set<AnyCancellable> = []
    private var loadTask: Task<Void, Never>?
    private var generation = 0
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.cubbiestream.kyro", category: "KyroRadio")

    var holdsAudio: Bool {
        guard let engine else { return false }
        switch engine.state {
        case .idle, .ended: return false
        default: return true
        }
    }

    func load(_ url: URL, generation: Int) {
        stop(releaseAudioSession: false)
        self.generation = generation
        let engine: AetherEngine
        do { engine = try requireEngine() } catch {
            logger.error("iptv audio engine unavailable")
            onEvent?(.failed, generation)
            return
        }
        let plan = KyroIPTVAudioLoadPlan(url: url)
        let options = LoadOptions(isLive: plan.isLive, audioOnly: plan.audioOnly, autoplay: true,
                                  preferredDecodePath: plan.softwareDecode ? .software : .automatic)
        logger.info("iptv audio load route=\(plan.route.rawValue, privacy: .public) generation=\(generation)")
        loadTask = Task { [weak self] in
            do {
                _ = try await engine.load(url: url, options: options)
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.generation == generation else { return }
                self.logger.error("iptv audio load failed: \(engine.errorInfo?.kind.rawValue ?? "unknown", privacy: .public)")
                self.onEvent?(.failed, generation)
                return
            }
            guard let self, self.generation == generation else { return }
            // Codec label and track count only: never the address.
            self.logger.info("iptv audio decoder=\(engine.activeAudioDecoder ?? "none", privacy: .public) tracks=\(engine.audioTracks.count) selected=\(engine.activeAudioTrackIndex ?? -1)")
        }
    }

    /// Ends the session. Radio decides whether the shared audio session may be
    /// released (`KyroRadioPlayer.releaseAudioSessionIfIdle`).
    func stop(releaseAudioSession: Bool) {
        // No Radio generation is negative, so nothing published after a stop
        // can be mistaken for the next load's.
        generation = -1
        loadTask?.cancel()
        loadTask = nil
        guard let engine else { return }
        engine.deactivatesAudioSessionOnStop = releaseAudioSession
            && (claim.map { AetherAudioSessionOwnership.canReleaseSharedSession(excluding: $0) } ?? false)
        engine.stop(finalTeardown: true)
    }

    private func requireEngine() throws -> AetherEngine {
        if let engine { return engine }
        let engine = try AetherEngine()
        engine.logTag = "radio-iptv"
        self.engine = engine
        claim = AetherAudioSessionOwnership.Claim(engine: engine)
        engine.$playbackPhase
            .sink { [weak self] phase in self?.publish(phase) }
            .store(in: &cancellables)
        return engine
    }

    private func publish(_ phase: PlaybackPhase) {
        let event: Event? = switch phase {
        case .playing: .playing
        case .loading, .rebuffering, .seeking, .stalled: .waiting
        case .error, .ended: .failed
        case .idle, .paused: nil
        }
        guard let event else { return }
        onEvent?(event, generation)
    }
}
#endif
