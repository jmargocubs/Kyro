#if os(iOS)
import AetherEngine
import SwiftUI

/// Build 46: the tapped live event plays in a 16:9 player above the Sports Hub feed.
///
/// It hosts the one Live TV session's engine surface. Expand, Picture in Picture and Other
/// Streams go through the same session and presentation as the full-screen player, so no second
/// player, engine or audio claim exists.
///
/// The video carries only Stop, Full Screen and the transport control, the same corner layout as
/// the Live TV watch screen. The matchup, the stream and the less frequent actions (Picture in
/// Picture, Other Streams) sit in a strip beneath it.
struct KyroSportsInlinePlayer: View {
    let service: LiveTVService
    /// The Sports Hub's games, to name the event while it is still being searched.
    let games: [KyroSportsGame]
    /// The playing event with its latest score and status, when the hub has one.
    var pinnedGame: KyroSportsGame? = nil
    @Binding var isShowingOtherStreams: Bool

    @State private var controls = LiveTVControlsVisibility(scheduler: LiveTVTaskScheduler())
    @State private var pictureInPicture = PictureInPictureCoordinator.shared
    @State private var orientationCoordinator = PlayerOrientationCoordinator.shared
    @Environment(\.scenePhase) private var scenePhase

    private var playback: KyroSportsPlaybackCoordinator { service.sportsPlayback }
    private var session: LiveTVPlayerSession { service.playerSession }
    private var mode: KyroSportsInlinePlayerMode {
        .make(sports: playback.phase, presentation: service.presentation.phase)
    }
    private var info: KyroSportsInlineInfo? {
        KyroSportsInlineInfo(mode: mode, context: playback.context, current: pinnedGame)
    }

    var body: some View {
        if mode.isVisible {
            VStack(spacing: 0) {
                frame
                if let info { infoStrip(info) }
            }
            .padding(.horizontal, SiloTheme.padding)
            .padding(.bottom, 4)
            .frame(maxWidth: 720 + 2 * SiloTheme.padding)
            .frame(maxWidth: .infinity)
            .background(Color.siloPageCanvas)
            .transition(.move(edge: .top).combined(with: .opacity))
            .sheet(isPresented: $isShowingOtherStreams) {
                KyroSportsOtherStreamsSheet(coordinator: playback, select: { match in
                    guard playback.switchTo(match) else { return }
                    isShowingOtherStreams = false
                }, dismiss: { isShowingOtherStreams = false })
            }
        }
    }

    private var frame: some View {
        ZStack {
            Color.black
            switch mode {
            case .playing(let channel):
                video(channel)
            case .finding:
                findingOverlay
            case .elsewhere(_, let isPictureInPicture):
                elsewhereOverlay(isPictureInPicture: isPictureInPicture)
            case .hidden:
                EmptyView()
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(KyroTheme.glassRim, lineWidth: 1)
        }
        .foregroundStyle(.white)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("kyroSportsInlinePlayer")
        .onChange(of: session.state) { syncControls() }
        .onChange(of: isShowingOtherStreams) { syncControls() }
        .onAppear {
            orientationCoordinator.watchScreenDidAppear()
            syncControls()
        }
        .onChange(of: orientationCoordinator.observedOrientation) { _, orientation in
            if orientation == .landscape { expandForDeviceRotation() }
        }
        .onChange(of: mode) { _, mode in
            // Coming back from full screen or the window: Expand cancelled the controls, so
            // re-read the session before showing them, or they would never hide again.
            if case .playing = mode {
                orientationCoordinator.watchScreenDidAppear()
                syncControls()
                controls.interact()
            } else {
                isShowingOtherStreams = false
                if !service.presentation.isFullScreenFromInline {
                    orientationCoordinator.watchScreenDidDisappear()
                }
            }
        }
        // Picture in Picture started from the inline button: the window takes the stream and the
        // frame shows where it went.
        .onChange(of: pictureInPicture.controlStartToken) { _, _ in
            guard service.presentation.isInline, pictureInPicture.ownsEngagedSession(session) else { return }
            service.presentation.pictureInPictureStartedFromControl()
        }
        // Automatic Picture in Picture on leaving the app keeps the inline player; coming back
        // lands on it, so end the window into it.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, service.presentation.isInline else { return }
            pictureInPicture.stopForReturnToPresentedPlayer(owner: session)
        }
        .onDisappear {
            controls.cancel()
            if !service.presentation.isFullScreenFromInline {
                orientationCoordinator.watchScreenDidDisappear()
            }
        }
    }

    // MARK: Playing

    @ViewBuilder
    private func video(_ channel: LiveTVChannel) -> some View {
        if let aether = (session.engine as? AetherLiveTVEngine)?.engine {
            // Mounted only while the stream is inline. The full-screen cover binds its own
            // surface; the engine moves its one layer to whichever surface is bound last.
            AetherPlayerSurface(engine: aether)
                .task {
                    service.attachPictureInPicture()
                    service.presentation.inlinePlayerDidAppear(channel)
                }
        }
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { controls.toggle() }
        LiveTVInlineStatusOverlay(state: session.state, errorMessage: session.errorMessage) {
            if session.canRetry {
                Button("Retry") {
                    controls.interact()
                    session.retry()
                }
                .buttonStyle(.borderedProminent)
                .tint(LiveTVAccent.primary)
            }
            if info?.hasOtherStreams == true {
                Button("Other Streams") { isShowingOtherStreams = true }
                    .buttonStyle(.bordered)
            }
        }
        controlsOverlay
            .opacity(controls.isVisible ? 1 : 0)
            .allowsHitTesting(controls.isVisible)
            .animation(.easeInOut(duration: 0.2), value: controls.isVisible)
    }

    private var controlsOverlay: some View {
        LiveTVInlineControlsOverlay(transport: LiveTVTransportControl(state: session.state)) {
            controls.interact()
            session.togglePlayback()
        } leading: {
            LiveTVInlineIconButton(symbol: "xmark", label: "Stop", identifier: "kyroSportsInlineStop") {
                controls.cancel()
                service.stopSportsInlinePlayback()
            }
        } trailing: {
            if let aether = (session.engine as? AetherLiveTVEngine)?.engine {
                LiveTVBasicControlsButton(engine: aether) { presenting in
                    controls.update(state: session.state, isOverlayPresented: presenting)
                }
            }
            LiveTVInlineIconButton(symbol: "arrow.up.left.and.arrow.down.right", label: "Full screen",
                                   identifier: "kyroSportsInlineExpand") {
                controls.cancel()
                LiveTVCoverTransition.immediate { service.presentation.expandInline() }
            }
        }
    }

    private func expandForDeviceRotation() {
        guard case .playing = mode, service.presentation.isInline,
              orientationCoordinator.observedOrientation == .landscape,
              !orientationCoordinator.suppressNaturalExpansionUntilUpright else { return }
        controls.cancel()
        LiveTVCoverTransition.immediate { service.presentation.expandInline(byRotation: true) }
    }

    // MARK: Information strip

    /// Matchup and score on the first line; live status, the stream and its actions on the second.
    private func infoStrip(_ info: KyroSportsInlineInfo) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(info.matchup)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(KyroTheme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let score = info.score {
                    Text(score)
                        .font(.subheadline.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(KyroTheme.textPrimary)
                }
            }
            .accessibilityElement(children: .combine)
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    if info.isLive {
                        Circle().fill(KyroTheme.live).frame(width: 6, height: 6)
                    }
                    Text(info.league).foregroundStyle(KyroTheme.accentInk)
                    Text(info.statusLine)
                    if let channelName = info.channelName {
                        Text("·")
                        Text(channelName).lineLimit(1).truncationMode(.tail)
                    }
                    switch info.location {
                    case .inline: EmptyView()
                    case .fullScreen: Image(systemName: "arrow.up.left.and.arrow.down.right")
                    case .pictureInPicture: Image(systemName: "pip")
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(KyroTheme.textSecondary)
                .lineLimit(1)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("kyroSportsInlineStream")
                Spacer(minLength: 4)
                if info.showsPlaybackActions {
                    if pictureInPicture.isSupported, pictureInPicture.hasSource {
                        stripIconButton("pip.enter", label: "Picture in Picture",
                                        identifier: "kyroSportsInlinePictureInPicture") {
                            controls.interact()
                            pictureInPicture.toggle()
                        }
                        .disabled(!pictureInPicture.isPossible)
                    }
                    if info.hasOtherStreams {
                        LiveTVInlinePillButton(title: "Streams", symbol: "sportscourt",
                                               identifier: "kyroSportsInlineOtherStreams") {
                            controls.interact()
                            isShowingOtherStreams = true
                        }
                        .accessibilityLabel("Other streams")
                    }
                }
            }
        }
        .padding(.top, 4)
        .padding(.horizontal, 2)
    }

    private func stripIconButton(_ symbol: String, label: String, identifier: String,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.siloOnSurface)
                .frame(width: LiveTVInlineChromeMetrics.pillHeight, height: LiveTVInlineChromeMetrics.pillHeight)
                .background(LiveTVSurface.row, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    // MARK: Finding and elsewhere

    private var findingOverlay: some View {
        VStack(spacing: 10) {
            ProgressView().tint(.white)
            if let status = KyroSportsConnectingStatus(phase: playback.phase, games: games) {
                VStack(spacing: 2) {
                    Text(status.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if let detail = status.detail {
                        Text(detail).font(.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.updatesFrequently)
                .accessibilityIdentifier("kyroSportsConnecting")
            }
            Button("Cancel") { service.cancelSportsPlayback() }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("kyroSportsCancelConnecting")
        }
        .padding(.horizontal, 16)
    }

    private func elsewhereOverlay(isPictureInPicture: Bool) -> some View {
        VStack(spacing: 6) {
            Image(systemName: isPictureInPicture ? "pip" : "arrow.up.left.and.arrow.down.right")
                .font(.title2)
            Text(isPictureInPicture ? "Playing in Picture in Picture" : "Playing full screen")
                .font(.subheadline.weight(.semibold))
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Helpers

    private func syncControls() {
        controls.update(state: session.state, isOverlayPresented: isShowingOtherStreams)
    }
}
#endif
