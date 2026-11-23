#if os(iOS)
import SwiftUI
import KyroProviders
import KyroSourceJellyfin

/// The existing detail card's Jellyfin root. It never routes a Jellyfin ID through Silo's detail
/// endpoint. Playback uses the same external stream path and PlayerView as IPTV.
struct KyroJellyfinDetailView: View {
    let ref: ContentRef
    let isSeries: Bool
    let onClose: () -> Void

    @State private var item: JellyfinMediaItem?
    @State private var seasons: [JellyfinMediaItem] = []
    @State private var episodes: [JellyfinMediaItem] = []
    @State private var selectedSeasonID: String?
    @State private var selectedEpisode: EpisodeSelection?
    @State private var errorText: String?
    @State private var playbackError: String?
    @State private var isPreparingPlayback = false
    @State private var playback: ExternalPlaybackRequest?
    @State private var scrollState = PhoneDetailScrollState()

    private var client: JellyfinClient? { KyroJellyfinConnections.shared.client(for: ref.account) }
    private var posterURL: String? {
        guard let item, let client else { return nil }
        return client.imageURL(itemID: item.contentID.itemID, kind: .primary,
                               tag: item.artwork.primaryTag)?.absoluteString
    }
    private var backdropURL: String? {
        guard let item, let client else { return nil }
        return client.imageURL(itemID: item.contentID.itemID, kind: .backdrop,
                               tag: item.artwork.backdropTag)?.absoluteString
    }

    var body: some View {
        PhoneDetailPageSurface(backdropURL: backdropURL, backdropThumbhash: nil,
                               enablesArtworkGlass: true) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 30) {
                    if let item {
                        PhoneDetailHero(
                            title: item.title, logoUrl: nil, posterUrl: posterURL,
                            posterThumbhash: nil, backdropUrl: backdropURL, backdropThumbhash: nil,
                            eyebrow: "Jellyfin", sourceTokens: [], ratingChip: nil,
                            overview: item.overview,
                            factsLine: [], overlayData: nil,
                            artworkStyle: backdropURL == nil
                                ? .cover(aspectRatio: 2.0 / 3.0,
                                         placeholderSymbol: isSeries ? "tv" : "film") : .backdrop,
                            actions: {
                                if !isSeries {
                                    playbackActions(for: item)
                                } else if let episode = episodes.first(where: { ($0.userState?.resumePositionSeconds ?? 0) > 0 }) ?? episodes.first {
                                    playbackActions(for: episode)
                                }
                            }, belowOverview: { EmptyView() }
                        )
                        if let year = item.year {
                            Text(String(year)).font(.subheadline).foregroundStyle(.secondary)
                                .padding(.horizontal, SiloTheme.safePadding)
                        }
                        if isSeries { episodeSection.padding(.horizontal, SiloTheme.safePadding) }
                    } else if let errorText {
                        ContentUnavailableView("Jellyfin details unavailable", systemImage: "wifi.exclamationmark",
                                               description: Text(errorText))
                            .padding(.top, 100)
                    } else {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 300)
                    }
                }
                .padding(.bottom, 40)
            }
            .ignoresSafeArea(edges: .top)
            .coordinateSpace(name: PhoneDetailScrollCoordinateSpace.name)
            .phoneDetailScrollTracking(scrollState)
        }
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .top) {
            PhoneDetailTopChrome(
                title: item?.title ?? "Jellyfin", isScrollGlassEnabled: true,
                scrollState: scrollState, leadingSystemName: "xmark",
                leadingAccessibilityLabel: "Close details", onLeadingTap: onClose,
                trailingSystemName: nil, onTrailingTap: nil)
        }
        .task(id: ref) { await load() }
        .fullScreenCover(item: $playback) { request in
            PlayerView(contentId: "jellyfin-\(ref.account.description)-\(request.id.uuidString)",
                       externalPlayback: request, onDismissRequested: {
                playback = nil
                Task { await load() }
            })
                .id(request.id)
                .interactiveDismissDisabled()
        }
        .sheet(item: $selectedEpisode) { selection in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(selection.item.title).font(.largeTitle.bold())
                        if let number = selection.item.indexNumber {
                            Text("Episode \(number)").font(.subheadline).foregroundStyle(.secondary)
                        }
                        if let runtime = selection.item.runtimeSeconds {
                            Text("\(Int(runtime / 60)) min").font(.subheadline).foregroundStyle(.secondary)
                        }
                        if let overview = selection.item.overview {
                            Text(overview).font(.body)
                        }
                        playbackActions(for: selection.item)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(SiloTheme.safePadding)
                }
                .navigationTitle("Episode details")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { selectedEpisode = nil }
                } }
            }
        }
    }

    @ViewBuilder private func playbackActions(for selected: JellyfinMediaItem) -> some View {
        VStack(spacing: 10) {
            PhonePrimaryPillButton(icon: "play.fill",
                title: isPreparingPlayback ? "Starting…" :
                    ((selected.userState?.resumePositionSeconds ?? 0) > 0 ? "Resume" : "Play"),
                action: { Task { await play(selected, fromStart: false) } }, fullWidth: true)
                .disabled(isPreparingPlayback)
            if (selected.userState?.resumePositionSeconds ?? 0) > 0 {
                Button("Start Over") { Task { await play(selected, fromStart: true) } }
                    .disabled(isPreparingPlayback)
            }
            if let playbackError {
                Text(playbackError).font(.siloCaption).foregroundStyle(Color.siloErrorInk)
            }
        }
    }

    private func play(_ selected: JellyfinMediaItem, fromStart: Bool) async {
        guard !isPreparingPlayback, let client else { return }
        isPreparingPlayback = true
        playbackError = nil
        defer { isPreparingPlayback = false }
        do {
            guard await KyroProviderCatalogBridge.registeredAccounts().contains(ref.account) else {
                playbackError = "This Jellyfin server is not linked to the current profile."
                return
            }
            let position = fromStart ? 0 : selected.userState?.resumePositionSeconds ?? 0
            let plan = try await client.playback(itemID: selected.contentID.itemID,
                                                 resumePositionSeconds: position)
            guard let url = plan.directURL ?? plan.transcodingURL else { return }
            let reporter = JellyfinPlaybackSessionReporter(client: client, plan: plan,
                profileID: KyroLocalIdentityDefaults.activeProfileID)
            selectedEpisode = nil
            playback = ExternalPlaybackRequest(url: url, title: selected.title,
                sourceLabel: "Jellyfin", startPosition: position,
                headers: plan.headers, fallbackURL: plan.directURL == nil ? nil : plan.transcodingURL,
                onFinish: { position, _, _ in reporter.finish(position: position) },
                onStart: { position in reporter.start(position: position) },
                onProgress: { position, _, paused in reporter.progress(position: position, paused: paused) },
                onFallback: { reporter.markTranscoding() },
                onEnd: { position in reporter.finish(position: position) })
        } catch {
            playbackError = (error as? LocalizedError)?.errorDescription ?? "This title cannot be played."
        }
    }

    @ViewBuilder private var episodeSection: some View {
        if !seasons.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                PhoneSectionHeader(title: "Episodes")
                Picker("Season", selection: $selectedSeasonID) {
                    ForEach(seasons, id: \.contentID.itemID) { season in
                        Text(season.title).tag(Optional(season.contentID.itemID))
                    }
                }
                .onChange(of: selectedSeasonID) { _, _ in Task { await loadEpisodes() } }
                ForEach(episodes, id: \.contentID.itemID) { episode in
                    Button { selectedEpisode = EpisodeSelection(item: episode) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(episode.title).font(.headline)
                        if let overview = episode.overview {
                            Text(overview).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func load() async {
        guard let client else {
            errorText = "Reconnect this Jellyfin server to view details."
            return
        }
        do {
            errorText = nil
            item = try await (isSeries ? client.series(id: ref.remoteID) : client.movie(id: ref.remoteID))
            if isSeries {
                seasons = try await client.seasons(seriesID: ref.remoteID).items
                selectedSeasonID = seasons.first?.contentID.itemID
                await loadEpisodes()
            }
        } catch {
            errorText = "Check the server connection and try again."
        }
    }

    private func loadEpisodes() async {
        guard let client, let selectedSeasonID else { episodes = []; return }
        do {
            episodes = try await client.episodes(seriesID: ref.remoteID,
                                                 seasonID: selectedSeasonID).items
        } catch { episodes = [] }
    }
}

private struct EpisodeSelection: Identifiable {
    let item: JellyfinMediaItem
    var id: String { item.contentID.rawValue }
}

/// Serializes the one player's Jellyfin reports. A profile switch cannot send its subsequent
/// ticks to the former profile's remote user, even if the full-screen player is still closing.
@MainActor
private final class JellyfinPlaybackSessionReporter {
    private let client: JellyfinClient
    private let plan: JellyfinPlaybackPlan
    private let profileID: String?
    private var pending: Task<Void, Never>?
    private var started = false
    private var stopped = false
    private var method: JellyfinPlayMethod = .directPlay

    init(client: JellyfinClient, plan: JellyfinPlaybackPlan, profileID: String?) {
        self.client = client
        self.plan = plan
        self.profileID = profileID
        method = plan.directURL == nil ? .transcode : .directPlay
    }

    private var isSameProfile: Bool {
        profileID != nil && profileID == KyroLocalIdentityDefaults.activeProfileID
    }

    func start(position: Double) {
        guard !started, !stopped, isSameProfile else { return }
        started = true
        enqueue(.start, position: position, paused: false)
    }

    func progress(position: Double, paused: Bool) {
        guard started, !stopped, isSameProfile else { return }
        enqueue(.progress, position: position, paused: paused)
    }

    func finish(position: Double) {
        guard started, !stopped, isSameProfile else { return }
        stopped = true
        enqueue(.stopped, position: position, paused: false)
        let stoppedReport = pending
        Task {
            _ = await stoppedReport?.value
            NotificationCenter.default.post(name: .homeSectionsShouldRefresh, object: nil)
        }
    }

    func markTranscoding() { method = .transcode }

    private func enqueue(_ phase: JellyfinPlaybackPhase, position: Double, paused: Bool) {
        let prior = pending
        let method = method
        pending = Task { [client, plan] in
            _ = await prior?.value
            try? await client.reportPlayback(phase, plan: plan,
                                             positionSeconds: max(0, position), paused: paused,
                                             method: method)
        }
    }
}
#endif
