import Foundation
import Observation

/// Which Live TV screen presents the full-screen player. The channel list and the guide sit in one
/// navigation stack, and each presents its own cover, so exactly one of them may show it.
enum LiveTVPresenter: Hashable, Sendable {
    case list
    case guide
    /// Kyro's unified navigation: the app shell, over whatever the user has open, when no Live TV
    /// screen can come forward without closing it. Never counted as a visible screen.
    case shell
}

/// What a channel selection means right now.
enum LiveTVSelection: Equatable, Sendable {
    /// The full-screen player opens for the channel.
    case present
    /// Picture in Picture keeps playing; tune the live session to the channel.
    case playInPlace
    /// Picture in Picture is being closed first; the full-screen player opens when it has closed.
    case exitingPictureInPicture
    /// A restore is in flight; the selection is not acted on.
    case ignored
}

/// What ending Picture in Picture should do to playback.
enum LiveTVEngagementOutcome: Equatable, Sendable {
    /// Nothing is left to watch: stop the session.
    case stopPlayback
    /// Playback continues in the full-screen player that was just presented.
    case continuePlayback
}

/// The single source of truth for Live TV's full-screen player and its Picture in Picture hand-offs,
/// shared by the channel list and the guide.
///
/// It owns no playback. The host wires `stopPlayback`, `stopPictureInPicture` and
/// `navigateToLiveTV` to the Live TV session, the Picture in Picture coordinator and the router, so
/// the rules here run with no AVKit and no engine.
@MainActor
@Observable
final class LiveTVPresentation {
    enum Phase: Equatable {
        /// No player on screen and none in Picture in Picture.
        case idle
        /// The full-screen player is showing, from the named screen.
        case presented(LiveTVChannel, LiveTVPresenter)
        /// The player's cover is closed and Picture in Picture owns the stream.
        case pictureInPicture(LiveTVChannel)
        /// Picture in Picture asked for the player back and its cover has not appeared yet.
        /// `nil` waits for a Live TV screen to appear.
        case restoring(LiveTVChannel, LiveTVPresenter?)
    }

    static let restoreTimeoutSeconds: Double = 4

    private(set) var phase: Phase = .idle

    /// Ends the Live TV session: stop playback, release Picture in Picture.
    @ObservationIgnored var stopPlayback: (() -> Void)?
    /// Asks the Picture in Picture coordinator to close its window.
    @ObservationIgnored var stopPictureInPicture: (() -> Void)?
    /// Brings a Live TV screen on screen when none is.
    @ObservationIgnored var navigateToLiveTV: (() -> Void)?

    @ObservationIgnored private let scheduler: any LiveTVScheduling
    @ObservationIgnored private var visible: Set<LiveTVPresenter> = []
    @ObservationIgnored private var lastPresenter: LiveTVPresenter = .list
    @ObservationIgnored private var pendingRestore: ((Bool) -> Void)?
    @ObservationIgnored private var restoreTimer: LiveTVTimerHandle?
    @ObservationIgnored private var restoreRequestID = UUID()
    /// Where the full-screen player opens if Picture in Picture ends without the user asking for it.
    @ObservationIgnored private var returnChannel: LiveTVChannel?
    @ObservationIgnored private var inPlaceTargetID: String?

    init(scheduler: any LiveTVScheduling) {
        self.scheduler = scheduler
    }

    /// The channel whose cover `presenter` should show, nil when it should show none.
    func channel(for presenter: LiveTVPresenter) -> LiveTVChannel? {
        switch phase {
        case .presented(let channel, let owner) where owner == presenter: channel
        case .restoring(let channel, let owner) where owner == presenter: channel
        default: nil
        }
    }

    /// The channel Live TV is playing, wherever it is shown.
    var activeChannel: LiveTVChannel? {
        switch phase {
        case .idle: nil
        case .presented(let channel, _), .pictureInPicture(let channel), .restoring(let channel, _): channel
        }
    }

    var isPictureInPictureOwningPlayback: Bool {
        if case .pictureInPicture = phase { return true }
        return false
    }

    // MARK: Selecting and closing

    /// A channel was chosen in the list or the guide.
    func select(_ channel: LiveTVChannel, from presenter: LiveTVPresenter) -> LiveTVSelection {
        switch phase {
        case .idle, .presented:
            lastPresenter = presenter
            phase = .presented(channel, presenter)
            return .present
        case .restoring:
            return .ignored
        case .pictureInPicture(let current):
            lastPresenter = presenter
            if channel.id == current.id {
                returnChannel = channel
                inPlaceTargetID = nil
                stopPictureInPicture?()
                return .exitingPictureInPicture
            }
            returnChannel = channel
            inPlaceTargetID = nil
            // The window survives a reload on the same route class; crossing between native HLS and
            // the software renderer makes the coordinator close it, so leave it deliberately and show
            // the player instead.
            if LiveTVStreamRoute(url: channel.streamURL) == LiveTVStreamRoute(url: current.streamURL) {
                inPlaceTargetID = channel.id
                phase = .pictureInPicture(channel)
                return .playInPlace
            }
            phase = .pictureInPicture(channel)
            stopPictureInPicture?()
            return .exitingPictureInPicture
        }
    }

    /// SwiftUI closed the cover for `presenter`: the user left the player.
    func coverDismissed(from presenter: LiveTVPresenter) {
        guard case .presented(_, let owner) = phase, owner == presenter else { return }
        phase = .idle
    }

    /// The player switched channel through its own picker.
    func playerChannelChanged(to channel: LiveTVChannel) {
        switch phase {
        case .presented(_, let presenter): phase = .presented(channel, presenter)
        case .pictureInPicture: phase = .pictureInPicture(channel)
        case .restoring(_, let presenter): phase = .restoring(channel, presenter)
        case .idle: break
        }
    }

    // MARK: Screens appearing

    func surfaceAppeared(_ presenter: LiveTVPresenter) {
        visible.insert(presenter)
        if case .restoring(let channel, nil) = phase {
            lastPresenter = presenter
            phase = .restoring(channel, presenter)
        }
    }

    func surfaceDisappeared(_ presenter: LiveTVPresenter) {
        // A cover over the screen can report it as disappearing; it is still there.
        switch phase {
        case .presented, .restoring: return
        case .idle, .pictureInPicture: visible.remove(presenter)
        }
    }

    /// Kyro's unified navigation: no Live TV screen can come forward without closing what the user
    /// has open (a pushed Media Server screen), so the player waiting for one opens over it instead.
    func presentOverCurrentScreen() {
        switch phase {
        case .restoring(let channel, nil):
            lastPresenter = .shell
            phase = .restoring(channel, .shell)
        case .presented(let channel, let presenter) where !visible.contains(presenter):
            lastPresenter = .shell
            phase = .presented(channel, .shell)
        case .idle, .presented, .pictureInPicture, .restoring:
            break
        }
    }

    // MARK: Picture in Picture

    /// Picture in Picture finished starting from the player's own button: the cover closes and the
    /// stream plays on in the window.
    func pictureInPictureStartedFromControl() {
        guard case .presented(let channel, let presenter) = phase else { return }
        lastPresenter = presenter
        returnChannel = nil
        inPlaceTargetID = nil
        phase = .pictureInPicture(channel)
    }

    /// The Live TV session failed while Picture in Picture owns it: close the window and show the
    /// player, where the failure and Retry are.
    func playbackFailedInPictureInPicture() {
        guard case .pictureInPicture(let channel) = phase else { return }
        returnChannel = channel
        inPlaceTargetID = nil
        stopPictureInPicture?()
    }

    /// A tuning change that Picture in Picture survived, so a later close is the user's own.
    func pictureInPictureSettled(activeChannelID: String?) {
        guard case .pictureInPicture = phase,
              let target = inPlaceTargetID, target == activeChannelID else { return }
        inPlaceTargetID = nil
        returnChannel = nil
    }

    /// AVKit asks for the full-screen player back. `completion(true)` must mean it is on screen.
    func restoreRequested(completion: @escaping (Bool) -> Void) {
        switch phase {
        case .presented:
            // Automatic Picture in Picture left the cover up; it is already the interface.
            completion(true)
        case .pictureInPicture(let channel):
            let target = visiblePresenter()
            phase = .restoring(channel, target)
            pendingRestore = completion
            restoreTimer?.cancel()
            restoreRequestID = UUID()
            let requestID = restoreRequestID
            restoreTimer = scheduler.schedule(after: Self.restoreTimeoutSeconds) { [weak self] in
                guard let self, self.restoreRequestID == requestID else { return }
                self.restoreTimedOut()
            }
            if target == nil { navigateToLiveTV?() }
        case .idle, .restoring:
            completion(false)
        }
    }

    /// The full-screen player for `channel` is on screen.
    func playerDidAppear(_ channel: LiveTVChannel) {
        guard case .restoring(let current, let presenter) = phase, current.id == channel.id else { return }
        phase = .presented(current, presenter ?? lastPresenter)
        returnChannel = nil
        inPlaceTargetID = nil
        answerRestore(true)
    }

    /// The cover never mounted. AVKit has taken the window down regardless, so the stream must not
    /// play on headless.
    func restoreTimedOut() {
        guard pendingRestore != nil else { return }
        answerRestore(false)
        phase = .idle
        returnChannel = nil
        stopPlayback?()
    }

    /// Picture in Picture ended: the user closed it, a restore completed, or a route change or
    /// failure closed it on purpose.
    ///
    /// - Parameter isStillBound: false when the coordinator was torn down (sign-out, profile or
    ///   server change), which always ends playback.
    func engagementEnded(isStillBound: Bool = true) -> LiveTVEngagementOutcome {
        guard phase != .idle else { return .stopPlayback }
        defer { returnChannel = nil; inPlaceTargetID = nil }
        restoreRequestID = UUID()
        restoreTimer?.cancel()
        restoreTimer = nil
        pendingRestore = nil
        if isStillBound, let channel = returnChannel {
            let presenter = visiblePresenter() ?? .list
            lastPresenter = presenter
            phase = .presented(channel, presenter)
            // With no Live TV screen up, the list opens and shows the player.
            if visible.isEmpty { navigateToLiveTV?() }
            return .continuePlayback
        }
        phase = .idle
        stopPlayback?()
        return .stopPlayback
    }

    /// Invalidate presentation before stopping the owner-keyed engine/coordinator.
    func providerRemoved(_ id: UUID, activeChannelID: String?) {
        guard (activeChannelID ?? activeChannel?.id)?.hasPrefix("\(id.uuidString):") == true else { return }
        phase = .idle
        returnChannel = nil
        inPlaceTargetID = nil
        answerRestore(false)
        stopPlayback?()
    }

    // MARK: Private

    /// The Live TV screen that can show a cover now: the one that presented last, else any.
    private func visiblePresenter() -> LiveTVPresenter? {
        if visible.contains(lastPresenter) { return lastPresenter }
        return visible.contains(.list) ? .list : visible.first
    }

    private func answerRestore(_ didRestore: Bool) {
        restoreRequestID = UUID()
        restoreTimer?.cancel()
        restoreTimer = nil
        let completion = pendingRestore
        pendingRestore = nil
        completion?(didRestore)
    }
}

/// The ownership rules that keep Live TV's Picture in Picture from colliding with Silo's own.
enum LiveTVPictureInPicturePolicy {
    /// Only one video engine plays at a time, so another player's Picture in Picture blocks Live TV
    /// playback. Live TV's own window must not: it is the stream being tuned.
    static func isOtherVideoActive(isEngaged: Bool, liveTVOwnsEngagement: Bool) -> Bool {
        isEngaged && !liveTVOwnsEngagement
    }

    /// Whether the player's disappearance ends the stream. Closing the cover for Picture in Picture
    /// leaves the stream playing in the window.
    static func shouldStopWhenPlayerDisappears(_ phase: LiveTVPresentation.Phase) -> Bool {
        if case .pictureInPicture = phase { return false }
        return true
    }
}

/// Watches the Live TV session while Picture in Picture owns it: a failed session closes the window
/// and returns to the player, where the error and Retry are; a stream that is playing again makes a
/// later close the user's own.
@MainActor
final class LiveTVPictureInPictureMonitor {
    private let session: LiveTVPlayerSession
    private let presentation: LiveTVPresentation
    private let bind: () -> Void

    init(session: LiveTVPlayerSession, presentation: LiveTVPresentation, bind: @escaping () -> Void) {
        self.session = session
        self.presentation = presentation
        self.bind = bind
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = session.state
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.handle()
                self?.observe()
            }
        }
    }

    private func handle() {
        guard session.activeChannelID != nil else { return }
        if session.state == .playing { bind() }
        guard presentation.isPictureInPictureOwningPlayback else { return }
        switch session.state {
        case .failed: presentation.playbackFailedInPictureInPicture()
        case .playing: presentation.pictureInPictureSettled(activeChannelID: session.activeChannelID)
        case .stopped, .connecting, .buffering, .paused: break
        }
    }
}
