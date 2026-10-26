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
    private var cancellables: Set<AnyCancellable> = []
    private let systemObservers = LiveTVNotificationTokens()

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
        onPhase?(mapped)
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
            guard type == AVAudioSession.InterruptionType.began.rawValue else { return }
            MainActor.assumeIsolated { self?.onSystemInterruption?() }
        })
        systemObservers.add(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            guard reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            MainActor.assumeIsolated { self?.onSystemInterruption?() }
        })
        #endif
    }
}

extension LiveTVPlayerSession {
    static func makeDefault() -> LiveTVPlayerSession {
        LiveTVPlayerSession(
            scheduler: LiveTVTaskScheduler(),
            makeEngine: { try AetherLiveTVEngine() },
            isOtherVideoActive: {
                #if os(iOS)
                // Engaged covers PiP starting as well as active.
                PictureInPictureCoordinator.shared.isEngaged
                #else
                false
                #endif
            }
        )
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
    #endif
    let channels: [LiveTVChannel]
    let session: LiveTVPlayerSession

    init(channel: LiveTVChannel, channels: [LiveTVChannel], session: LiveTVPlayerSession) {
        _channel = State(initialValue: channel)
        self.channels = channels
        self.session = session
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
        .task { session.play(channel) }
        .onAppear {
            #if os(iOS)
            orientationCoordinator.activateLiveTVPlayer()
            #endif
        }
        .onChange(of: channel) { oldValue, newValue in
            guard oldValue.id != newValue.id else { return }
            controls.channelChanged()
            session.play(newValue)
        }
        .onChange(of: session.state) { syncControls() }
        .onChange(of: isShowingChannelPicker) { syncControls() }
        .onDisappear {
            controls.cancel()
            session.stop()
            #if os(iOS)
            orientationCoordinator.deactivatePlayer()
            #endif
        }
        .sheet(isPresented: $isShowingChannelPicker) {
            LiveTVChannelPickerView(channels: channels, selectedChannelID: channel.id) { selected in
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

