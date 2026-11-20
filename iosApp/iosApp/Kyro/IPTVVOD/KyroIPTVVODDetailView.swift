#if os(iOS)
import SwiftUI

/// A provider title's detail page, built from the same phone detail components as Silo's movie
/// and series pages (and offline downloads): `PhoneDetailPageSurface`, `PhoneDetailHero`,
/// `PhonePrimaryPillButton`, `PhoneLabeledActionRow` and `PhoneSectionHeader`.
///
/// Playback opens Silo's `PlayerView` with an `ExternalPlaybackRequest`, so IPTV titles get the
/// same player chrome, PiP and transport as Silo titles.
struct KyroIPTVVODDetailView: View {
    let item: XtreamVODItem
    let providerName: String

    private let service = XtreamVODService.shared
    @State private var detail: XtreamVODDetail?
    @State private var detailFailed: String?
    @State private var playbackError: String?
    @State private var playback: ExternalPlaybackRequest?
    @State private var selectedSeason: Int?

    var body: some View {
        PhoneDetailPageSurface(
            backdropURL: item.poster,
            backdropThumbhash: nil,
            enablesArtworkGlass: true
        ) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 32) {
                    hero
                    if item.kind == .series {
                        episodesSection
                            .padding(.horizontal, SiloTheme.safePadding)
                    }
                }
                .padding(.bottom, 40)
            }
            .ignoresSafeArea(edges: .top)
            .coordinateSpace(name: PhoneDetailScrollCoordinateSpace.name)
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .siloNavigationBarBackgroundHidden()
        .siloToolbarColorSchemeDark()
        .task(id: item.id) {
            do {
                let loaded = try await service.detail(for: item)
                detail = loaded
                if selectedSeason == nil { selectedSeason = resumeEpisode(in: loaded)?.season ?? loaded.seasons.first }
            } catch {
                detailFailed = (error as? LocalizedError)?.errorDescription ?? "Details are unavailable."
            }
        }
        .fullScreenCover(item: $playback) { request in
            PlayerView(
                contentId: "iptv-vod-\(request.id.uuidString)",
                externalPlayback: request,
                onDismissRequested: { playback = nil }
            )
            .id(request.id)
            .interactiveDismissDisabled()
        }
    }

    // MARK: Hero

    private var hero: some View {
        PhoneDetailHero(
            title: item.title,
            logoUrl: nil,
            posterUrl: item.poster,
            posterThumbhash: nil,
            backdropUrl: item.poster,
            backdropThumbhash: nil,
            eyebrow: "IPTV · \(providerName)".uppercased(),
            sourceTokens: [],
            ratingChip: ratingChip,
            overview: detail?.summary ?? item.summary,
            factsLine: factsLine,
            overlayData: nil,
            enablesArtworkParallax: true,
            artworkStyle: .cover(aspectRatio: 2.0 / 3.0, placeholderSymbol: item.kind == .movie ? "film" : "tv"),
            actions: { actions },
            belowOverview: { EmptyView() }
        )
    }

    private var ratingChip: String? {
        guard let raw = detail?.rating ?? item.rating, let value = Double(raw), value > 0 else { return nil }
        return String(format: "★ %.1f", value)
    }

    private var factsLine: [PhoneHeroFactToken] {
        var tokens: [PhoneHeroFactToken] = []
        if let year = XtreamVODTitle.year(in: item.title) { tokens.append(.text(String(year))) }
        if let duration = detail?.duration, duration > 0,
           let runtime = MediaTextFormatting.runtime(minutes: Int((duration / 60).rounded())) {
            tokens.append(.text(runtime))
        }
        if let genre = (detail?.genre ?? item.genre)?.split(separator: ",").first {
            tokens.append(.text(genre.trimmingCharacters(in: .whitespaces)))
        }
        if item.kind == .series, let count = detail?.episodes.count, count > 0 {
            tokens.append(.text(count == 1 ? "1 episode" : "\(count) episodes"))
        }
        return tokens
    }

    // MARK: Actions

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 14) {
            if item.kind == .movie {
                let state = service.watchState(for: item)
                PhonePrimaryPillButton(
                    icon: "play.fill",
                    title: Self.isResumable(state) ? "Resume" : "Play",
                    action: { play(episode: nil, fromStart: false) },
                    fullWidth: true,
                    progress: Self.isResumable(state) && state.duration > 0 ? state.position / state.duration : nil
                )
                if Self.isResumable(state) {
                    PhoneLabeledActionRow {
                        PhoneLabeledAction(icon: "gobackward", label: "Start Over", isToggle: false) {
                            play(episode: nil, fromStart: true)
                        }
                    }
                }
            } else if let detail, let episode = resumeEpisode(in: detail) ?? detail.episodes.first {
                let state = service.watchState(for: item, episode: episode)
                PhonePrimaryPillButton(
                    icon: "play.fill",
                    title: "\(Self.isResumable(state) ? "Resume" : "Play") S\(episode.season) E\(episode.number)",
                    action: { play(episode: episode, fromStart: false) },
                    fullWidth: true,
                    progress: Self.isResumable(state) && state.duration > 0 ? state.position / state.duration : nil
                )
            } else if detail == nil, detailFailed == nil {
                ProgressView().tint(.siloOnSurface).frame(minHeight: 52)
            }
            if let message = playbackError ?? detailFailed {
                Text(message)
                    .font(.siloCaption)
                    .foregroundColor(.siloErrorInk)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Episodes

    @ViewBuilder
    private var episodesSection: some View {
        if let detail, !detail.episodes.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                PhoneSectionHeader(title: "Episodes", trailingText: seasonCaption(detail))
                if detail.seasons.count > 1 {
                    seasonChips(detail.seasons)
                }
                VStack(spacing: 0) {
                    let episodes = detail.episodes.filter { $0.season == (selectedSeason ?? detail.seasons.first) }
                    ForEach(Array(episodes.enumerated()), id: \.element.id) { index, episode in
                        if index > 0 {
                            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                        }
                        episodeRow(episode)
                    }
                }
            }
        }
    }

    private func seasonCaption(_ detail: XtreamVODDetail) -> String {
        detail.seasons.count == 1 ? "1 season" : "\(detail.seasons.count) seasons"
    }

    /// Silo's season chip look: filled white capsule when selected, outlined otherwise.
    private func seasonChips(_ seasons: [Int]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(seasons, id: \.self) { season in
                    let selected = season == selectedSeason
                    Button {
                        selectedSeason = season
                    } label: {
                        Text(season == 0 ? "Specials" : "Season \(season)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(selected ? .black : .siloOnSurface)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background {
                                if selected {
                                    Capsule().fill(Color.white)
                                } else {
                                    Capsule().stroke(Color.white.opacity(0.35), lineWidth: 1)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func episodeRow(_ episode: XtreamVODEpisode) -> some View {
        let state = service.watchState(for: item, episode: episode)
        return Button {
            play(episode: episode, fromStart: false)
        } label: {
            HStack(alignment: .top, spacing: 14) {
                Text("\(episode.number)")
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundColor(.siloOnSurface.opacity(0.6))
                    .frame(minWidth: 24, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    Text(episode.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.siloOnSurface)
                        .lineLimit(2)
                    if let summary = episode.summary {
                        Text(summary)
                            .font(.system(size: 13))
                            .foregroundColor(.siloOnSurface.opacity(0.6))
                            .lineLimit(2)
                    }
                    if Self.isResumable(state), state.duration > 0 {
                        ProgressView(value: min(1, state.position / state.duration))
                            .tint(.white)
                            .frame(maxWidth: 120)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: state.completed ? "checkmark.circle.fill" : "play.circle")
                    .font(.system(size: 22))
                    .foregroundColor(.siloOnSurface.opacity(state.completed ? 0.5 : 0.85))
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Episode \(episode.number), \(episode.title)")
    }

    // MARK: Playback

    private static func isResumable(_ state: XtreamVODWatchState) -> Bool {
        !state.completed && state.position > 15
    }

    /// The most recently watched unfinished episode, else the first unwatched one.
    private func resumeEpisode(in detail: XtreamVODDetail) -> XtreamVODEpisode? {
        let states = detail.episodes.map { ($0, service.watchState(for: item, episode: $0)) }
        if let resume = states.filter({ Self.isResumable($0.1) }).max(by: { $0.1.updatedAt < $1.1.updatedAt }) {
            return resume.0
        }
        if let lastDone = states.lastIndex(where: { $0.1.completed }), lastDone + 1 < states.count {
            return states[lastDone + 1].0
        }
        return nil
    }

    private func play(episode: XtreamVODEpisode?, fromStart: Bool) {
        playbackError = nil
        let url: URL
        do {
            url = try service.playbackURL(for: item, episode: episode)
        } catch {
            playbackError = (error as? LocalizedError)?.errorDescription ?? "This title cannot be played."
            return
        }
        let state = service.watchState(for: item, episode: episode)
        let start = !fromStart && Self.isResumable(state) ? state.position : 0
        // Xtream accounts commonly allow one stream at a time. Live TV (including an inline
        // Sports player or its Picture in Picture window) would hold that connection and the
        // provider would refuse this one, so release it first.
        let liveTV = LiveTVService.shared
        if liveTV.playerSession.state != .stopped { liveTV.endPlayback() }
        let service = service
        let item = item
        playback = ExternalPlaybackRequest(
            url: url,
            title: episode.map { "\(item.title) · S\($0.season) E\($0.number)" } ?? item.title,
            sourceLabel: "IPTV · \(providerName)",
            startPosition: start,
            probe: { await XtreamVODStreamProbe.probe(url) },
            onFinish: { position, duration, ended in
                service.saveProgress(position: ended ? max(position, duration) : position,
                                     duration: duration, item: item, episode: episode)
            }
        )
    }
}

private extension XtreamVODDetail {
    var seasons: [Int] { Array(Set(episodes.map(\.season))).sorted() }
}
#endif
