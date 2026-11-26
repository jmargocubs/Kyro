#if os(iOS)
import AVFoundation
import MediaPlayer
import Nuke
import Observation

/// Only progress consumers (expanded transport and cassette tape) read this.
@MainActor @Observable
final class PodcastPlaybackClock {
    var position = 0.0
    var duration = 0.0
    var seeking = false
    var fraction: Double { PodcastProgress(position: position, duration: duration, played: false).fraction }
}

@MainActor @Observable
final class KyroPodcastPlayer {
    static let shared = KyroPodcastPlayer()
    enum State: Equatable { case idle, loading, playing, paused, failed }

    private(set) var hasSession = false
    private(set) var current: PodcastEntry?
    private(set) var state: State = .idle
    private(set) var isAdvancing = false
    private(set) var sleep: PodcastSleep = .off
    var isShowingNowPlaying = false
    @ObservationIgnored let clock = PodcastPlaybackClock()
    private var library: KyroPodcastLibrary { .shared }
    @ObservationIgnored private lazy var engine: AVPlayer = {
        let player = AVPlayer()
        player.allowsExternalPlayback = true
        player.automaticallyWaitsToMinimizeStalling = true
        return player
    }()
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var transportObservation: NSKeyValueObservation?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var sessionObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var sleepTask: Task<Void, Never>?
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    @ObservationIgnored private var artwork: MPMediaItemArtwork?
    @ObservationIgnored private var commands: [(MPRemoteCommand, Any)] = []
    @ObservationIgnored private var claim: AetherAudioSessionOwnership.Claim?
    @ObservationIgnored private var systemMedia = false
    @ObservationIgnored private var wantsPlayback = false
    @ObservationIgnored private var didReachEnd = false
    @ObservationIgnored private var resumeAfterInterruption = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var seekGeneration = UUID()
    @ObservationIgnored private var lastSavedPosition = 0.0
    @ObservationIgnored private var initialPosition = 0.0
    @ObservationIgnored private var hasReadyItem = false
    @ObservationIgnored private var didStartListening = false

    private init() {
        claim = AetherAudioSessionOwnership.Claim { [weak self] in self?.wantsPlayback == true }
        KyroPlaybackExclusivity.shared.register(self, source: .podcast) { [weak self] in self?.yieldPlayback() }
        observeAudioSession()
    }

    func play(_ entry: PodcastEntry) {
        if current?.id == entry.id, engine.currentItem != nil, state != .failed, !didReachEnd {
            resume()
            return
        }
        save(publish: true)
        disposeItem()
        let available = KyroPodcastDownloads.shared.localURL(for: entry)
        guard let url = available ?? PodcastAddress.url(entry.episode.media.absoluteString) else { return }
        generation = UUID()
        let expected = generation
        current = entry
        hasSession = true
        didReachEnd = false
        hasReadyItem = false
        didStartListening = false
        initialPosition = library.resumePosition(for: entry.id)
        lastSavedPosition = initialPosition
        clock.duration = entry.episode.duration ?? 0
        clock.position = PodcastProgress.clamped(initialPosition, duration: clock.duration)
        clock.seeking = false
        library.removeFromQueue(entry.id)
        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .timeDomain
        engine.replaceCurrentItem(with: item)
        transportObservation = engine.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.generation == expected else { return }
                let advancing = self.wantsPlayback && self.engine.timeControlStatus == .playing
                if advancing, !self.didStartListening, let current = self.current {
                    self.didStartListening = true
                    self.library.recordStart(current)
                }
                if self.isAdvancing != advancing {
                    self.isAdvancing = advancing
                    self.publishSystemMedia()
                }
            }
        }
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in self?.itemStatusChanged(expected) }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
            object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard self?.generation == expected else { return }
                    self?.ended()
                }
            }
        timeObserver = engine.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main) { [weak self] value in
                MainActor.assumeIsolated {
                    guard self?.generation == expected else { return }
                    self?.tick(value.seconds)
                }
            }
        if sleep == .off { setSleep(library.preferences.sleepMinutes) }
        resume()
        loadArtwork(entry, expected: expected)
    }

    func toggle() { wantsPlayback ? pause() : resume() }

    func resume() {
        guard let current else { return }
        if state == .failed || didReachEnd { play(current); return }
        hasSession = true
        wantsPlayback = true
        KyroPlaybackExclusivity.shared.begin(self, source: .podcast)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
            try session.setActive(true)
        } catch {
            wantsPlayback = false
            state = .failed
            return
        }
        bindSystemMedia()
        state = hasReadyItem ? .playing : .loading
        if hasReadyItem, !clock.seeking { engine.playImmediately(atRate: Float(library.preferences.speed)) }
        publishSystemMedia()
    }

    func pause() {
        guard current != nil, state != .failed else { return }
        wantsPlayback = false
        engine.pause()
        isAdvancing = false
        state = .paused
        save(publish: true)
        publishSystemMedia()
    }

    func stop() {
        guard current != nil else { return }
        pause()
        generation = UUID()
        disposeItem()
        setSleep(0)
        current = nil
        wantsPlayback = false
        state = .idle
        hasSession = false
        isShowingNowPlaying = false
        unbindSystemMedia()
        if let claim, AetherAudioSessionOwnership.canReleaseSharedSession(excluding: claim) {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func seek(_ seconds: Double) {
        guard hasReadyItem, clock.duration > 0, !didReachEnd else { return }
        seekReady(seconds)
    }

    func skip(_ interval: Double) { seek(clock.position + interval) }

    func updatePreferences(_ preferences: PodcastPreferences) {
        let old = library.preferences
        library.updatePreferences(preferences)
        guard old != library.preferences else { return }
        if wantsPlayback, hasReadyItem, !clock.seeking, old.speed != library.preferences.speed {
            engine.rate = Float(library.preferences.speed)
        }
        if systemMedia, SharedNowPlayingArbiter.shared.isCurrentClaimant(self) {
            updateSkipIntervals()
            publishSystemMedia()
        }
    }

    func setSleep(_ minutes: Int) {
        sleepTask?.cancel()
        sleep = PodcastSleep.make(minutes)
        guard case .deadline(let deadline) = sleep else { return }
        sleepTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
            guard !Task.isCancelled, self?.sleep == .deadline(deadline) else { return }
            self?.expireSleep()
        }
    }

    private func expireSleep() { setSleep(0); pause() }

    private func yieldPlayback() {
        guard hasSession else { return }
        pause()
        resumeAfterInterruption = false
        hasSession = false
        isShowingNowPlaying = false
        setSleep(0)
        unbindSystemMedia()
    }

    private func itemStatusChanged(_ expected: UUID) {
        guard generation == expected, let item = engine.currentItem else { return }
        switch item.status {
        case .readyToPlay:
            guard !hasReadyItem else { return }
            hasReadyItem = true
            updateDuration(item.duration.seconds)
            if initialPosition > 0 {
                seekReady(initialPosition)
            } else if wantsPlayback {
                state = .playing
                engine.playImmediately(atRate: Float(library.preferences.speed))
            }
            publishSystemMedia()
        case .failed:
            wantsPlayback = false
            state = .failed
            publishSystemMedia()
        default: break
        }
    }

    private func seekReady(_ seconds: Double) {
        let expected = generation
        let seeking = UUID()
        seekGeneration = seeking
        clock.seeking = true
        let target = PodcastProgress.clamped(seconds, duration: clock.duration)
        clock.position = target
        let time = CMTime(seconds: target, preferredTimescale: 600)
        let tolerance = CMTime(seconds: 0.20, preferredTimescale: 600)
        engine.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == expected, self.seekGeneration == seeking else { return }
                self.clock.seeking = false
                let actual = self.engine.currentTime().seconds
                if actual.isFinite { self.clock.position = PodcastProgress.clamped(actual, duration: self.clock.duration) }
                if self.wantsPlayback {
                    self.state = .playing
                    self.engine.playImmediately(atRate: Float(self.library.preferences.speed))
                }
                self.save(publish: true)
                self.publishSystemMedia()
            }
        }
    }

    private func tick(_ time: Double) {
        guard hasReadyItem, !clock.seeking, !didReachEnd else { return }
        updateDuration(engine.currentItem?.duration.seconds ?? 0)
        guard time.isFinite else { return }
        let position = PodcastProgress.clamped(time, duration: clock.duration)
        if clock.position != position { clock.position = position }
        if wantsPlayback && abs(clock.position - lastSavedPosition) >= 15 { save(publish: false) }
        if sleep.shouldPause(at: Date()) { expireSleep() }
    }

    private func updateDuration(_ duration: Double) {
        if duration.isFinite, duration > 0, clock.duration != duration { clock.duration = duration }
    }

    private func save(publish: Bool) {
        guard let current, hasReadyItem, !clock.seeking else { return }
        library.checkpoint(current, position: clock.position, duration: clock.duration, played: didReachEnd, publish: publish)
        lastSavedPosition = clock.position
    }

    private func ended() {
        guard let current, hasSession else { return }
        didReachEnd = true
        wantsPlayback = false
        state = .paused
        isAdvancing = false
        clock.seeking = false
        if clock.duration > 0 { clock.position = clock.duration }
        save(publish: true)
        if library.preferences.removeCompleted { KyroPodcastDownloads.shared.remove(current) }
        if sleep.shouldPause(at: Date(), ended: true) { setSleep(0) }
        else if let next = library.nextInQueue() { play(next); return }
        publishSystemMedia()
    }

    private func disposeItem() {
        artworkTask?.cancel()
        artwork = nil
        isAdvancing = false
        transportObservation = nil
        statusObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        if let timeObserver { engine.removeTimeObserver(timeObserver) }
        timeObserver = nil
        engine.pause()
        engine.replaceCurrentItem(with: nil)
    }

    private func observeAudioSession() {
        let center = NotificationCenter.default
        sessionObservers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                MainActor.assumeIsolated {
                    guard let self, self.hasSession else { return }
                    if type == AVAudioSession.InterruptionType.began.rawValue {
                        self.resumeAfterInterruption = self.wantsPlayback
                        self.pause()
                    } else {
                        let pending = self.resumeAfterInterruption
                        self.resumeAfterInterruption = false
                        if pending, AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) { self.resume() }
                    }
                }
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
                let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                MainActor.assumeIsolated {
                    if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue, self?.hasSession == true {
                        self?.pause()
                    }
                }
            }
        ]
    }

    private func bindSystemMedia() {
        if !systemMedia || !SharedNowPlayingArbiter.shared.isCurrentClaimant(self) {
            SharedNowPlayingArbiter.shared.claim(self, suspend: { [weak self] in self?.clearCommands() },
                restore: { [weak self] in self?.registerCommands(); self?.publishSystemMedia() })
            systemMedia = true
        }
        registerCommands()
    }

    private func unbindSystemMedia() {
        guard systemMedia else { return }
        systemMedia = false
        clearCommands()
        SharedNowPlayingArbiter.shared.releaseSharedCenters(self)
    }

    private func registerCommands() {
        guard systemMedia, commands.isEmpty, SharedNowPlayingArbiter.shared.isCurrentClaimant(self) else { return }
        let center = MPRemoteCommandCenter.shared()
        func add(_ command: MPRemoteCommand, action: @escaping @MainActor (KyroPodcastPlayer, Double?) -> Void) {
            command.isEnabled = true
            let token = command.addTarget { [weak self] event in
                let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime
                Task { @MainActor in
                    guard let self, self.hasSession, SharedNowPlayingArbiter.shared.isCurrentClaimant(self) else {
                        return
                    }
                    action(self, position)
                }
                return .success
            }
            commands.append((command, token))
        }
        add(center.playCommand) { player, _ in player.resume() }
        add(center.pauseCommand) { player, _ in player.pause() }
        add(center.togglePlayPauseCommand) { player, _ in player.toggle() }
        add(center.stopCommand) { player, _ in player.stop() }
        add(center.skipBackwardCommand) { player, _ in player.skip(-Double(player.library.preferences.back)) }
        add(center.skipForwardCommand) { player, _ in player.skip(Double(player.library.preferences.forward)) }
        add(center.changePlaybackPositionCommand) { player, position in
            if let position { player.seek(position) }
        }
        updateSkipIntervals()
    }

    private func clearCommands() {
        for (command, token) in commands { command.removeTarget(token) }
        commands = []
    }

    private func updateSkipIntervals() {
        let center = MPRemoteCommandCenter.shared()
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: library.preferences.back)]
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: library.preferences.forward)]
    }

    private func publishSystemMedia() {
        guard systemMedia, SharedNowPlayingArbiter.shared.isCurrentClaimant(self), let current else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: current.episode.title,
            MPMediaItemPropertyArtist: current.showTitle,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: clock.position,
            MPNowPlayingInfoPropertyPlaybackRate: isAdvancing && !clock.seeking ? library.preferences.speed : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: library.preferences.speed,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
        if clock.duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = clock.duration }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadArtwork(_ entry: PodcastEntry, expected: UUID) {
        guard let url = entry.artwork else { return }
        artworkTask = Task { [weak self] in
            guard let request = PosterImageCache.displayRequest(url: url, pointSize: CGSize(width: 250, height: 250), scale: 2),
                  let image = try? await ImagePipeline.shared.image(for: request),
                  let self, !Task.isCancelled, generation == expected else { return }
            artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            publishSystemMedia()
        }
    }
}
#endif
