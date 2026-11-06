import AVFoundation
import AetherEngine
import Combine
import Observation
import SwiftUI

/// The production Live TV engine: a dedicated AetherEngine, separate from Silo's VOD playback
/// controller. It reports no watch progress and does not own Now Playing.
@MainActor
final class AetherLiveTVEngine: LiveTVEngineDriving {
    let engine: AetherEngine
    var onPhase: ((LiveTVEnginePhase) -> Void)?
    var onLiveSourceReset: (() -> Void)?
    var onSystemInterruption: (() -> Void)?
    var onSystemInterruptionEnded: (() -> Void)?
    var onAudioRouteLost: (() -> Void)?
    private var cancellables: Set<AnyCancellable> = []
    private let systemObservers = LiveTVNotificationTokens()
    private var runtimeCancellables: Set<AnyCancellable> = []
    private var runtimeSession: RuntimeAudioDiagnosticSession?
    private var runtimeID: UUID?
    private var runtimeGeneration = 0
    private var runtimeRoute = "unknown"

    init() throws {
        engine = try AetherEngine()
        engine.logTag = "livetv"
        engine.videoGravity = .resizeAspect
        // `playbackPhase` tracks motion, unlike `state`, which turns `.playing` as soon as the
        // engine calls play() on a live join that may not move for seconds.
        engine.$playbackPhase
            .sink { [weak self] phase in self?.publish(phase) }
            .store(in: &cancellables)
        engine.liveSourceReset
            .sink { [weak self] in self?.onLiveSourceReset?() }
            .store(in: &cancellables)
        observeSystemAudioEvents()
    }

    func load(_ url: URL, route: LiveTVStreamRoute) async throws {
        // Live only, fast-zap joins. HLS takes the engine's live HLS route, whose ingest fallback
        // covers HEVC-in-TS carriage and refused mounts; everything else is read by the engine.
        let options = LoadOptions(isLive: true, liveJoinProfile: .fastZap, nativeRemoteHLS: route == .hls)
        do {
            _ = try await engine.load(url: url, options: options)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LiveTVEngineLoadError(failure: Self.failure(engine.errorInfo), detail: Self.detail(engine.errorInfo))
        }
    }

    func recoverLiveSource() -> Bool { engine.retryLiveSourceRecovery() }

    func play() { engine.play() }

    func pause() { engine.pause() }

    func stop(final: Bool, releaseAudioSession: Bool) {
        finishRuntimeDiagnostics(phase: "stopped")
        // Silo's ownership rule: release only when no other Silo engine holds audio. Across
        // engines the release still belongs to the last one out (AetherEngine's shared output book).
        engine.deactivatesAudioSessionOnStop = releaseAudioSession
        engine.stop(finalTeardown: final)
    }

    private func publish(_ phase: PlaybackPhase) {
        let mapped: LiveTVEnginePhase = switch phase {
        case .idle: .idle
        case .loading: .loading
        case .playing: .playing
        case .paused: .paused
        case .seeking, .rebuffering: .rebuffering
        case .stalled(let reconnecting): .stalled(reconnecting: reconnecting)
        case .ended: .ended
        // `errorInfo` is assigned before the state it describes.
        case .error: .failed(Self.failure(engine.errorInfo), detail: Self.detail(engine.errorInfo))
        }
        if case .playing = phase {
            if runtimeSession == nil { beginRuntimeDiagnostics() }
            else { captureRuntimeSnapshot() }
        } else if runtimeSession != nil {
            captureRuntimeSnapshot()
            switch phase {
            case .ended: finishRuntimeDiagnostics(phase: "ended")
            case .error: finishRuntimeDiagnostics(phase: "error")
            default: break
            }
        }
        onPhase?(mapped)
    }

    /// Selection metadata contains only an opaque UUID, generation and the app's route enum.
    func prepareRuntimeDiagnostics(sessionID: UUID, generation: Int, route: LiveTVStreamRoute) {
        finishRuntimeDiagnostics(phase: "replaced")
        runtimeID = sessionID
        runtimeGeneration = generation
        runtimeRoute = route == .hls ? "hls" : "transport_stream"
    }

    private func beginRuntimeDiagnostics() {
        guard let runtimeID else { return }
        let now = ProcessInfo.processInfo.systemUptime
        runtimeSession = RuntimeAudioDiagnosticSession(sessionID: runtimeID, generation: runtimeGeneration,
            route: runtimeRoute, startedAt: now, initial: runtimeSnapshot())
        persistRuntime()
        engine.$audioDelivery.sink { [weak self] _ in self?.captureRuntimeSnapshot() }.store(in: &runtimeCancellables)
        engine.$activeAudioDecoder.sink { [weak self] _ in self?.captureRuntimeSnapshot() }.store(in: &runtimeCancellables)
        engine.$audioTracks.sink { [weak self] _ in self?.captureRuntimeSnapshot() }.store(in: &runtimeCancellables)
        engine.$activeAudioTrackIndex.sink { [weak self] _ in self?.captureRuntimeSnapshot() }.store(in: &runtimeCancellables)
    }

    private func runtimeSnapshot() -> RuntimeAudioDiagnosticSession.Snapshot {
        let phase: String = switch engine.playbackPhase {
        case .idle: "idle"
        case .loading: "loading"
        case .playing: "playing"
        case .paused: "paused"
        case .seeking: "seeking"
        case .rebuffering: "rebuffering"
        case .stalled: "stalled"
        case .ended: "ended"
        case .error: "error"
        }
        return .init(phase: phase, delivery: engine.audioDelivery.rawValue,
            decoder: safeDecoderLabel(engine.activeAudioDecoder), selectedTrack: engine.activeAudioTrackIndex,
            trackCount: engine.audioTracks.count)
    }

    private func safeDecoderLabel(_ value: String?) -> String? {
        guard let value else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 .+-_/()")
        let normalized = String(value.unicodeScalars.map { allowed.contains($0) ? Character($0) : " " })
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return normalized.isEmpty ? nil : String(normalized.prefix(80))
    }

    private func captureRuntimeSnapshot() {
        guard var runtimeSession else { return }
        guard runtimeSession.observe(runtimeSnapshot(), now: ProcessInfo.processInfo.systemUptime) else { return }
        self.runtimeSession = runtimeSession
        persistRuntime()
    }

    private func recordSystemAudioEvent(_ name: String, value: String) {
        guard var runtimeSession else { return }
        runtimeSession.systemEvent(name, value: value, now: ProcessInfo.processInfo.systemUptime)
        self.runtimeSession = runtimeSession
        persistRuntime()
    }

    private func finishRuntimeDiagnostics(phase: String) {
        guard var runtimeSession else { runtimeID = nil; return }
        runtimeSession.end(phase: phase, now: ProcessInfo.processInfo.systemUptime)
        self.runtimeSession = nil
        runtimeCancellables.removeAll()
        persist(runtimeSession.record)
        runtimeID = nil
    }

    private func persistRuntime() {
        guard let runtimeSession else { return }
        persist(runtimeSession.record)
    }

    private func persist(_ record: RuntimeAudioDiagnosticRecord) {
        PlaybackDiagnosticsStore.shared.appendRuntime(record)
    }

    private static func failure(_ info: PlaybackErrorInfo?) -> LiveTVPlaybackFailure {
        LiveTVPlaybackFailure.classifyEngine(kind: info?.kind.rawValue, code: info?.underlyingCode)
    }

    private static func detail(_ info: PlaybackErrorInfo?) -> String? {
        LiveTVPlaybackFailure.diagnosticDetail(kind: info?.kind.rawValue, code: info?.underlyingCode)
    }

    /// Interruptions and lost routes pause Live TV; it resumes only when the viewer asks.
    private func observeSystemAudioEvents() {
        #if os(iOS) || os(tvOS)
        let center = NotificationCenter.default
        systemObservers.add(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            let typeLabel = type == AVAudioSession.InterruptionType.began.rawValue ? "began"
                : (type == AVAudioSession.InterruptionType.ended.rawValue ? "ended" : "unknown")
            let audioSession = AVAudioSession.sharedInstance()
            KyroPiPDiagnostics.record(
                "live_tv_audio_interruption",
                state: "type=\(typeLabel) options=\(options.map(String.init) ?? "none") category=\(audioSession.category.rawValue) mode=\(audioSession.mode.rawValue) otherAudio=\(audioSession.isOtherAudioPlaying) secondarySilenced=\(audioSession.secondaryAudioShouldBeSilencedHint)"
            )
            if let type { MainActor.assumeIsolated { self?.recordSystemAudioEvent("audio_interruption", value: type == AVAudioSession.InterruptionType.began.rawValue ? "began" : "ended") } }
            if type == AVAudioSession.InterruptionType.began.rawValue {
                MainActor.assumeIsolated { self?.onSystemInterruption?() }
            } else if type == AVAudioSession.InterruptionType.ended.rawValue,
                      let raw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt,
                      AVAudioSession.InterruptionOptions(rawValue: raw).contains(.shouldResume) {
                MainActor.assumeIsolated { self?.onSystemInterruptionEnded?() }
            }
        })
        systemObservers.add(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            KyroPiPDiagnostics.record("live_tv_audio_route_change", state: "reason=\(reason.map(String.init) ?? "unknown")")
            if let reason { MainActor.assumeIsolated { self?.recordSystemAudioEvent("audio_route_change", value: String(reason)) } }
            guard reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            MainActor.assumeIsolated { self?.onAudioRouteLost?() }
        })
        #endif
    }
}

extension LiveTVPlayerSession {
    static func makeDefault() -> LiveTVPlayerSession {
        #if os(iOS)
        let reference = LiveTVSessionReference()
        #endif
        let session = LiveTVPlayerSession(
            scheduler: LiveTVTaskScheduler(),
            makeEngine: { try AetherLiveTVEngine() },
            isOtherVideoActive: {
                #if os(iOS)
                // Engaged covers PiP starting as well as active. Live TV's own window is the stream
                // being tuned, so only another player's window blocks it.
                let coordinator = PictureInPictureCoordinator.shared
                return LiveTVPictureInPicturePolicy.isOtherVideoActive(
                    isEngaged: coordinator.isEngaged,
                    liveTVOwnsEngagement: reference.session.map(coordinator.ownsEngagedSession) ?? false)
                #else
                false
                #endif
            },
            isOwnPictureInPictureEngaged: {
                #if os(iOS)
                reference.session.map(PictureInPictureCoordinator.shared.ownsEngagedSession) ?? false
                #else
                false
                #endif
            }
        )
        #if os(iOS)
        reference.session = session
        #endif
        return session
    }
}

/// Removes block-based observers when their owner goes away.
private final class LiveTVNotificationTokens: @unchecked Sendable {
    private var tokens: [NSObjectProtocol] = []
    func add(_ token: NSObjectProtocol) { tokens.append(token) }
    deinit { for token in tokens { NotificationCenter.default.removeObserver(token) } }
}

struct LiveTVPlayerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var channel: LiveTVChannel
    @State private var isShowingChannelPicker = false
    @State private var controls = LiveTVControlsVisibility(scheduler: LiveTVTaskScheduler())
    #if os(iOS)
    @State private var orientationCoordinator = PlayerOrientationCoordinator.shared
    @State private var pictureInPicture = PictureInPictureCoordinator.shared
    @Environment(\.scenePhase) private var scenePhase
    #endif
    let channels: [LiveTVChannel]
    let session: LiveTVPlayerSession
    /// Owns the shared presentation and Picture in Picture hand-off; nil for a bare player.
    let service: LiveTVService?

    init(channel: LiveTVChannel, channels: [LiveTVChannel], session: LiveTVPlayerSession,
         service: LiveTVService? = nil) {
        _channel = State(initialValue: channel)
        self.channels = channels
        self.session = session
        self.service = service
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let aether = (session.engine as? AetherLiveTVEngine)?.engine {
                // The engine swaps its own layer per route; the surface only hosts it, so rotation
                // remounts the view without recreating the engine.
                AetherPlayerSurface(engine: aether)
                    .ignoresSafeArea()
            }

            // Taps on the bare video toggle the controls; hidden controls let taps through to here.
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { controls.toggle() }

            VStack(spacing: 0) {
                HStack {
                    Button {
                        controls.cancel()
                        session.stop()
                        #if os(iOS)
                        orientationCoordinator.deactivatePlayer()
                        #endif
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.headline.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("Stop Live TV")

                    Spacer()
                    Text(channel.name)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer()

                    #if os(iOS)
                    Button {
                        controls.interact()
                        orientationCoordinator.toggleLiveTVOrientation()
                    } label: {
                        Image(systemName: orientationCoordinator.observedOrientation == .landscape
                              ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                            .font(.headline.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel(orientationCoordinator.observedOrientation == .landscape
                                        ? "Return to portrait" : "Rotate to landscape")
                    .accessibilityHint("Changes Live TV orientation without stopping playback")
                    #endif

                    #if os(iOS)
                    if pictureInPicture.isSupported, pictureInPicture.hasSource {
                        Button {
                            controls.interact()
                            pictureInPicture.toggle()
                        } label: {
                            Image(systemName: pictureInPicture.isActive ? "pip.exit" : "pip.enter")
                                .font(.headline.weight(.semibold))
                                .frame(width: 44, height: 44)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .disabled(!pictureInPicture.isPossible && !pictureInPicture.isActive)
                        .accessibilityLabel(pictureInPicture.isActive ? "Exit Picture in Picture" : "Picture in Picture")
                    }
                    #endif

                    Button {
                        controls.interact()
                        isShowingChannelPicker = true
                    } label: {
                        Image(systemName: "list.bullet")
                            .font(.headline.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("Switch channel")
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .opacity(controls.isVisible ? 1 : 0)
                .allowsHitTesting(controls.isVisible)

                Spacer()

                statusOverlay

                Spacer()

                if let symbol = transportSymbol {
                    Button {
                        controls.interact()
                        session.togglePlayback()
                    } label: {
                        Image(systemName: symbol)
                            .font(.title2.weight(.bold))
                            .frame(width: 58, height: 58)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel(session.isPaused ? "Resume live stream" : "Pause live stream")
                    .accessibilityHint("Temporary live-stream pause; the provider may not retain paused video.")
                    .padding(.bottom, 30)
                    .opacity(controls.isVisible ? 1 : 0)
                    .allowsHitTesting(controls.isVisible)
                } else {
                    Color.clear.frame(height: 88)
                }
            }
            .foregroundStyle(.white)
        }
        .animation(.easeInOut(duration: 0.2), value: controls.isVisible)
        #if os(iOS)
        .statusBarHidden()
        #endif
        .task {
            if let service {
                service.playPresentedChannel(channel)
                service.attachPictureInPicture()
            } else {
                session.play(channel)
            }
        }
        .onAppear {
            service?.presentation.playerDidAppear(channel)
            #if os(iOS)
            orientationCoordinator.activateLiveTVPlayer()
            #endif
        }
        .onChange(of: channel) { oldValue, newValue in
            guard oldValue.id != newValue.id else { return }
            controls.channelChanged()
        }
        #if os(iOS)
        // Picture in Picture started from the button: only the cover closes. The stream plays on in
        // the window, and AVKit's restore control re-presents this player.
        .onChange(of: pictureInPicture.controlStartToken) { _, _ in
            guard pictureInPicture.ownsEngagedSession(session) else { return }
            service?.presentation.pictureInPictureStartedFromControl()
            dismiss()
        }
        // Automatic Picture in Picture on leaving the app keeps this cover, so coming back lands on
        // the player itself; end the window into it.
        .onChange(of: scenePhase) { _, phase in
            KyroPiPDiagnostics.record("live_tv_scene_phase", state: String(describing: phase))
            if phase == .active { pictureInPicture.stopForReturnToPresentedPlayer(owner: session) }
        }
        #endif
        .onChange(of: session.state) { syncControls() }
        .onChange(of: isShowingChannelPicker) { syncControls() }
        .onDisappear {
            controls.cancel()
            // A cover closed for Picture in Picture leaves the stream playing in the window.
            if service.map({ LiveTVPictureInPicturePolicy.shouldStopWhenPlayerDisappears($0.presentation.phase) }) ?? true {
                session.stop()
            }
            #if os(iOS)
            orientationCoordinator.deactivatePlayer()
            #endif
        }
        .sheet(isPresented: $isShowingChannelPicker) {
            LiveTVChannelPickerView(channels: channels, selectedChannelID: channel.id) { selected in
                if let service {
                    guard service.playFromPlayerPicker(selected) else { return }
                } else {
                    session.play(selected)
                }
                channel = selected
                isShowingChannelPicker = false
            }
        }
        #if os(iOS)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in
            orientationCoordinator.refreshInterfaceOrientation()
        }
        #endif
    }

    private func syncControls() {
        controls.update(state: session.state, isOverlayPresented: isShowingChannelPicker)
    }

    /// Pause only while there is something to pause; play only when paused. Connecting and
    /// failed show no transport control, so a failure never looks like active playback.
    private var transportSymbol: String? {
        switch session.state {
        case .playing, .buffering: "pause.fill"
        case .paused: "play.fill"
        case .connecting, .failed, .stopped: nil
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch session.state {
        case .connecting:
            statusCapsule("Connecting…")
        case .buffering:
            statusCapsule("Buffering…")
        case .failed:
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").font(.title2)
                Text(session.errorMessage ?? LiveTVPlaybackFailure.unknown.message)
                    .font(.subheadline).multilineTextAlignment(.center)
                if let detail = session.failureDetail {
                    Text(detail).font(.caption2.monospaced()).foregroundStyle(.white.opacity(0.7))
                }
                if session.canRetry {
                    Button("Retry") {
                        controls.interact()
                        session.retry()
                    }
                        .buttonStyle(.borderedProminent)
                        .accessibilityHint("Reconnects this channel")
                }
            }
            .foregroundStyle(.white)
            .padding(18)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 28)
        case .playing, .paused, .stopped:
            EmptyView()
        }
    }

    private func statusCapsule(_ title: String) -> some View {
        ProgressView(title)
            .tint(.white)
            .foregroundStyle(.white)
            .padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct LiveTVChannelPickerView: View {
    @Environment(\.dismiss) private var dismiss
    let channels: [LiveTVChannel]
    let selectedChannelID: String
    let onSelect: (LiveTVChannel) -> Void
    @State private var query = ""
    @State private var search = LiveTVChannelSearchModel()

    var body: some View {
        NavigationStack {
            List {
                ForEach(search.orderedCategories, id: \.self) { category in
                    Section(category) {
                        ForEach(search.groups[category] ?? []) { candidate in
                            Button {
                                onSelect(candidate)
                            } label: {
                                HStack {
                                    Text(candidate.name).lineLimit(1)
                                    Spacer()
                                    if candidate.id == selectedChannelID {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Select Channel")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search channels")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { updateSearch() }
            .onChange(of: query) { updateSearch() }
            .onDisappear { search.cancel() }
        }
    }

    private func updateSearch() {
        search.update(channels: channels, query: query, category: nil, favoritesOnly: false, favoriteIDs: [])
    }
}
