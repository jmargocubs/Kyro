#if os(iOS)
import AVFoundation
import MediaPlayer
import Nuke
import Observation
import OSLog
import UIKit

/// The app's one radio player. AVPlayer plays MP3, AAC and HLS radio
/// streams; `KyroRadioPlaybackMachine` decides every transition.
///
/// - Audio session: `.playback`, not mixed, active only while radio holds
///   audio, and released only when no other Silo engine is holding audio
///   (`AetherAudioSessionOwnership`).
/// - Lock Screen and Control Center: through `SharedNowPlayingArbiter`, with
///   Play, Pause, Play/Pause and Stop only. A live stream has no seek bar.
/// - Song and artist come from the stream's own ICY metadata when it sends any.
@MainActor @Observable
final class KyroRadioPlayer {
    static let shared = KyroRadioPlayer()

    private(set) var machine = KyroRadioPlaybackMachine()
    /// Song and artist from the stream, when it sends them.
    private(set) var track: KyroRadioTrack?
    var isShowingNowPlaying = false

    var station: KyroRadioStation? { machine.station }
    var state: KyroRadioPlaybackState { machine.state }
    /// A station is loaded (playing, paused or failed): the mini player shows.
    var hasSession: Bool { machine.station != nil }
    var isPlaying: Bool { machine.state == .playing }

    @ObservationIgnored private let library: KyroRadioLibrary
    @ObservationIgnored private let client: KyroRadioBrowserClient
    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var metadataOutput: AVPlayerItemMetadataOutput?
    @ObservationIgnored private let metadataDelegate = MetadataDelegate()
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var itemNotifications: [NSObjectProtocol] = []
    @ObservationIgnored private var sessionNotifications: [NSObjectProtocol] = []
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var detailsTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var startupTimeout: Task<Void, Never>?
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    @ObservationIgnored private var artwork: MPMediaItemArtwork?
    @ObservationIgnored private var commandTargets: [(MPRemoteCommand, Any)] = []
    @ObservationIgnored private var isBoundToSystemMedia = false
    /// Tells Silo's other engines whether radio holds the shared audio session.
    @ObservationIgnored private var audioClaim: AetherAudioSessionOwnership.Claim?
    @ObservationIgnored private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.cubbiestream.kyro", category: "KyroRadio")

    /// A stream that hasn't started after this long counts as failed.
    static let startupTimeoutSeconds: UInt64 = 20

    init(library: KyroRadioLibrary? = nil, client: KyroRadioBrowserClient = .shared) {
        self.library = library ?? .shared
        self.client = client
        metadataDelegate.onTitle = { [weak self] value in self?.receiveStreamTitle(value) }
        audioClaim = AetherAudioSessionOwnership.Claim(isHoldingAudio: { [weak self] in
            self?.machine.isActive ?? false
        })
        KyroPlaybackExclusivity.shared.register(self, source: .radio) { [weak self] in
            self?.apply { $0.yieldToOtherPlayback() }
        }
        observeAudioSession()
    }

    // MARK: Listener actions

    func play(_ station: KyroRadioStation) {
        if self.station?.id == station.id, machine.isActive { isShowingNowPlaying = true; return }
        detailsTask?.cancel()
        guard station.playbackCandidates.isEmpty else { start(station); return }
        // A favorite restored from a backup has only its ID and name: get its
        // stream from Radio Browser first (one bounded request).
        let client = client
        detailsTask = Task { [weak self] in
            let fresh = try? await client.stations(uuids: [station.id]).first { $0.id == station.id }
            guard let self, !Task.isCancelled else { return }
            if let fresh { self.library.refreshDetails([fresh]) }
            self.start(fresh ?? station)
        }
    }

    private func start(_ station: KyroRadioStation) {
        track = nil
        artwork = nil
        apply { $0.play(station) }
        loadArtwork(for: station)
    }

    func togglePlayPause() { apply { $0.togglePlayPause() } }
    func pause() { apply { $0.pause() } }
    func resume() { apply { $0.resume() } }

    func stop() {
        detailsTask?.cancel()
        apply { $0.stop() }
        track = nil
        isShowingNowPlaying = false
    }

    // MARK: Transitions

    private func apply(_ transition: (inout KyroRadioPlaybackMachine) -> [KyroRadioPlaybackMachine.Effect]) {
        let before = machine.state
        let effects = transition(&machine)
        for effect in effects { perform(effect) }
        if machine.isActive, !before.isActive { KyroPlaybackExclusivity.shared.begin(self, source: .radio) }
        if machine.state != before { logger.info("radio state \(String(describing: self.machine.state), privacy: .public)") }
        updateSystemMedia()
    }

    private func perform(_ effect: KyroRadioPlaybackMachine.Effect) {
        switch effect {
        case .recordStart:
            guard let station else { return }
            library.recordPlay(station)
            let client = client
            Task { await client.reportClick(station.id) }
        case .load(let candidate, let generation):
            reconnectTask?.cancel()
            load(candidate: candidate, generation: generation)
        case .pausePlayer:
            tearDownPlayer()
            releaseAudioSessionIfIdle()
        case .stopPlayer:
            tearDownPlayer()
            releaseAudioSessionIfIdle()
        case .scheduleReconnect(let delay, let generation):
            reconnectTask?.cancel()
            reconnectTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.apply { $0.reconnectDue(generation: generation) }
            }
        }
    }

    private func load(candidate: Int, generation: Int) {
        tearDownPlayer()
        guard let station, station.playbackCandidates.indices.contains(candidate) else {
            apply { $0.playerFailed(generation: generation) }
            return
        }
        let url = station.playbackCandidates[candidate]
        loadTask = Task { [weak self] in
            guard let self else { return }
            var streamURL = url
            if KyroRadioPlaylist.isPlaylist(url) {
                guard let resolved = try? await self.client.resolvePlaylist(url) else {
                    guard !Task.isCancelled else { return }
                    self.apply { $0.playerFailed(generation: generation) }
                    return
                }
                streamURL = resolved
            }
            guard !Task.isCancelled, generation == self.machine.generation else { return }
            self.startPlayer(streamURL, generation: generation)
        }
    }

    private func startPlayer(_ url: URL, generation: Int) {
        activateAudioSession()
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        // Live radio: a short forward buffer keeps it near the live edge.
        item.preferredForwardBufferDuration = 8
        let output = AVPlayerItemMetadataOutput(identifiers: nil)
        output.setDelegate(metadataDelegate, queue: .main)
        item.add(output)
        metadataOutput = output
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        player.allowsExternalPlayback = true
        self.player = player
        observations = [
            item.observe(\.status, options: [.new]) { [weak self] item, _ in
                let status = item.status
                Task { @MainActor in
                    guard let self, generation == self.machine.generation else { return }
                    if status == .failed { self.apply { $0.playerFailed(generation: generation) } }
                }
            },
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                let status = player.timeControlStatus
                Task { @MainActor in
                    guard let self, generation == self.machine.generation, status == .playing else { return }
                    self.startupTimeout?.cancel()
                    self.apply { machine in machine.playerStarted(generation: generation); return [] }
                }
            },
        ]
        let center = NotificationCenter.default
        itemNotifications = [
            center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply { $0.playerFailed(generation: generation) } }
            },
            // A live stream that "ends" has dropped.
            center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply { $0.playerFailed(generation: generation) } }
            },
        ]
        startupTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.startupTimeoutSeconds * 1_000_000_000)
            guard !Task.isCancelled, let self, generation == self.machine.generation,
                  self.machine.state != .playing else { return }
            self.apply { $0.playerFailed(generation: generation) }
        }
        player.play()
    }

    private func tearDownPlayer() {
        loadTask?.cancel()
        loadTask = nil
        startupTimeout?.cancel()
        startupTimeout = nil
        if !(machine.state.isReconnecting) { reconnectTask?.cancel() }
        observations.forEach { $0.invalidate() }
        observations = []
        itemNotifications.forEach(NotificationCenter.default.removeObserver)
        itemNotifications = []
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        metadataOutput = nil
    }

    private func receiveStreamTitle(_ value: String?) {
        guard let station else { return }
        let next = KyroRadioTrack(streamTitle: value, stationName: station.name)
        guard next != track else { return }
        track = next
        publishNowPlayingInfo()
    }

    // MARK: Audio session

    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
            try session.setActive(true)
        } catch {
            logger.error("radio audio session: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func releaseAudioSessionIfIdle() {
        guard !machine.isActive, let audioClaim,
              AetherAudioSessionOwnership.canReleaseSharedSession(excluding: audioClaim) else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func observeAudioSession() {
        let center = NotificationCenter.default
        sessionNotifications = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                let info = note.userInfo ?? [:]
                let type = (info[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
                let options = (info[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init)
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch type {
                    case .began: self.apply { $0.interruptionBegan() }
                    case .ended: self.apply { $0.interruptionEnded(shouldResume: options?.contains(.shouldResume) == true) }
                    default: break
                    }
                }
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
                let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                    .flatMap(AVAudioSession.RouteChangeReason.init)
                MainActor.assumeIsolated {
                    guard let self, reason == .oldDeviceUnavailable else { return }
                    self.apply { $0.outputRouteLost() }
                }
            },
        ]
    }

    // MARK: Lock Screen and Control Center

    private func updateSystemMedia() {
        if station == nil {
            unbindSystemMedia()
            return
        }
        if !isBoundToSystemMedia {
            SharedNowPlayingArbiter.shared.claim(self,
                suspend: { [weak self] in self?.removeCommandTargets() },
                restore: { [weak self] in self?.restoreSystemMedia() })
            isBoundToSystemMedia = true
            registerCommandTargets()
        }
        publishNowPlayingInfo()
    }

    private func restoreSystemMedia() {
        guard isBoundToSystemMedia else { return }
        removeCommandTargets()
        registerCommandTargets()
        publishNowPlayingInfo()
    }

    private func unbindSystemMedia() {
        guard isBoundToSystemMedia else { return }
        removeCommandTargets()
        isBoundToSystemMedia = false
        SharedNowPlayingArbiter.shared.releaseSharedCenters(self)
    }

    private func registerCommandTargets() {
        guard SharedNowPlayingArbiter.shared.isCurrentClaimant(self) else { return }
        let center = MPRemoteCommandCenter.shared()
        func add(_ command: MPRemoteCommand, _ action: @escaping @MainActor (KyroRadioPlayer) -> Void) {
            command.isEnabled = true
            let target = command.addTarget { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.station != nil else { return .noActionableNowPlayingItem }
                    action(self)
                    return .success
                }
            }
            commandTargets.append((command, target))
        }
        add(center.playCommand) { $0.resume() }
        add(center.pauseCommand) { $0.pause() }
        add(center.togglePlayPauseCommand) { $0.togglePlayPause() }
        add(center.stopCommand) { $0.stop() }
        // No seeking, skipping or scrubbing on a live stream.
        center.changePlaybackPositionCommand.isEnabled = false
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
    }

    private func removeCommandTargets() {
        for (command, target) in commandTargets { command.removeTarget(target) }
        commandTargets = []
    }

    private func publishNowPlayingInfo() {
        guard isBoundToSystemMedia, SharedNowPlayingArbiter.shared.isCurrentClaimant(self), let station else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track?.title ?? station.name,
            MPMediaItemPropertyArtist: track?.artist ?? (track == nil ? station.location : station.name),
            MPMediaItemPropertyAlbumTitle: station.name,
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: machine.state == .playing ? 1.0 : 0.0,
        ]
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadArtwork(for station: KyroRadioStation) {
        artworkTask?.cancel()
        guard let url = station.favicon else { return }
        artworkTask = Task { [weak self] in
            // Nuke's shared pipeline: the same cached image the station rows use.
            guard let image = try? await ImagePipeline.shared.image(for: url),
                  !Task.isCancelled, let self, self.station?.id == station.id else { return }
            self.artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.publishNowPlayingInfo()
        }
    }
}

private extension KyroRadioPlaybackState {
    var isReconnecting: Bool {
        if case .reconnecting = self { return true }
        return false
    }
}

/// Receives the stream's timed metadata (Shoutcast/Icecast `StreamTitle`,
/// HLS ID3 titles) on the main queue.
private final class MetadataDelegate: NSObject, AVPlayerItemMetadataOutputPushDelegate {
    var onTitle: (@MainActor (String?) -> Void)?

    func metadataOutput(_ output: AVPlayerItemMetadataOutput, didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup],
                        from track: AVPlayerItemTrack?) {
        let items = groups.flatMap(\.items)
        let title = items.first { item in
            item.identifier == .icyMetadataStreamTitle || item.commonKey == .commonKeyTitle
        }
        Task { [onTitle] in
            let value = try? await title?.load(.stringValue)
            await MainActor.run { onTitle?(value ?? nil) }
        }
    }
}
#endif
