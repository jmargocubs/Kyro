import Foundation

/// Provider-owned media (IPTV VOD) the shared player opens directly, without a Silo session.
///
/// `url` can carry provider credentials in its path. It is handed to Aether only; the player
/// never logs it, shows it, or sends it to the Silo server.
struct ExternalPlaybackRequest: Identifiable {
    let id: UUID
    let url: URL
    /// Ephemeral provider authorization, passed only to the player transport.
    let headers: [String: String]
    /// Optional negotiated HLS fallback, opened in the same player after direct-play failure.
    let fallbackURL: URL?
    let title: String
    let sourceLabel: String
    let startPosition: Double
    /// Runs once after a failed open, when the engine has released the source, and reports what
    /// the provider actually answered. Nil skips the probe.
    let probe: (@MainActor () async -> ExternalStreamProbeReport?)?
    /// Position, duration and whether the item ended, when the player closes after playing.
    let onFinish: (@MainActor (_ position: Double, _ duration: Double, _ ended: Bool) -> Void)?
    let onStart: (@MainActor (_ position: Double) -> Void)?
    let onProgress: (@MainActor (_ position: Double, _ duration: Double, _ paused: Bool) -> Void)?
    let onFallback: (@MainActor () -> Void)?
    let onEnd: (@MainActor (_ position: Double) -> Void)?

    init(id: UUID = UUID(), url: URL, title: String, sourceLabel: String, startPosition: Double = 0,
         headers: [String: String] = [:], fallbackURL: URL? = nil,
         probe: (@MainActor () async -> ExternalStreamProbeReport?)? = nil,
         onFinish: (@MainActor (_ position: Double, _ duration: Double, _ ended: Bool) -> Void)? = nil,
         onStart: (@MainActor (_ position: Double) -> Void)? = nil,
         onProgress: (@MainActor (_ position: Double, _ duration: Double, _ paused: Bool) -> Void)? = nil,
         onFallback: (@MainActor () -> Void)? = nil,
         onEnd: (@MainActor (_ position: Double) -> Void)? = nil) {
        self.id = id
        self.url = url
        self.headers = headers
        self.fallbackURL = fallbackURL
        self.title = title
        self.sourceLabel = sourceLabel
        self.startPosition = startPosition
        self.probe = probe
        self.onFinish = onFinish
        self.onStart = onStart
        self.onProgress = onProgress
        self.onFallback = onFallback
        self.onEnd = onEnd
    }

    /// The same request reopened at `position`, keeping its identity for a retry.
    func resuming(at position: Double) -> ExternalPlaybackRequest {
        ExternalPlaybackRequest(id: id, url: url, title: title, sourceLabel: sourceLabel,
                                startPosition: position.isFinite ? max(0, position) : 0,
                                headers: headers, fallbackURL: fallbackURL,
                                probe: probe, onFinish: onFinish, onStart: onStart,
                                onProgress: onProgress, onFallback: onFallback, onEnd: onEnd)
    }

    func usingFallback(at position: Double) -> ExternalPlaybackRequest? {
        guard let fallbackURL else { return nil }
        return ExternalPlaybackRequest(id: id, url: fallbackURL, title: title,
                                       sourceLabel: sourceLabel, startPosition: max(0, position),
                                       headers: headers, fallbackURL: nil, probe: probe,
                                       onFinish: onFinish, onStart: onStart,
                                       onProgress: onProgress, onFallback: onFallback, onEnd: onEnd)
    }
}
