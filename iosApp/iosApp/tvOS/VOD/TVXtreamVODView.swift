#if os(tvOS)
import SwiftUI
import AVKit

/// The three IPTV browse modes. Continue Watching and Favorites come from Kyro's local IPTV
/// watch history, which is separate from Silo's server-side progress.
enum XtreamVODBrowseMode: Int, CaseIterable, Hashable {
    case catalog, continueWatching, favorites

    var title: String {
        switch self {
        case .catalog: return "All Titles"
        case .continueWatching: return "Continue Watching"
        case .favorites: return "Favorites"
        }
    }
}

/// Pure focus rules for the IPTV catalog page, kept out of the view so they can be tested.
enum TVXtreamVODFocusPlanner {
    enum Target: Equatable {
        /// The first title card.
        case firstCard(String)
        /// The selected browse-mode control, when the page has no titles to land on.
        case mode(XtreamVODBrowseMode)
        /// Titles are still loading; claim once they arrive.
        case wait
    }

    /// Entering the page from the top menu lands on the first title, like the Silo feed.
    static func entryTarget(itemIDs: [String], isLoading: Bool, mode: XtreamVODBrowseMode) -> Target {
        if let first = itemIDs.first { return .firstCard(first) }
        return isLoading ? .wait : .mode(mode)
    }

    /// Load the next page once focus nears the end of the loaded titles.
    static func shouldLoadMore(focusedIndex: Int, loadedCount: Int, hasMore: Bool, isLoading: Bool) -> Bool {
        hasMore && !isLoading && focusedIndex >= max(0, loadedCount - pagePrefetchDistance)
    }

    static let pageSize = 100
    static let pagePrefetchDistance = 15
}

/// One IPTV provider's Movies or Series catalog. Silo cards, collections and playback never pass
/// through this page, and it never shares the screen with the Silo feed.
///
/// Focus follows docs/tvos-focus.md: the control row is the page's top row and the only place
/// Up hands focus back to the top menu; everything else is the native focus graph. A top-menu
/// selection resets the scroll and lands on the first title.
struct TVXtreamVODView: View {
    let provider: LiveTVProvider
    let kind: XtreamVODKind
    let focusRequest: Int
    let isTopMenuFocused: Bool
    let onMoveUp: (() -> Void)?
    /// Space above the header. The tab page sits under the top menu; the Live TV full-screen
    /// cover has no menu above it.
    var topInset: CGFloat = TVTopMenuLayout.contentTopInset
    /// Side inset of the page. The tab page sits under a shell that ignores the side safe area;
    /// the Live TV cover is already inside it and passes 0.
    var horizontalInset: CGFloat = TVScreenLayout.pageHorizontalInset

    private enum Field: Hashable {
        case search, mode(XtreamVODBrowseMode), refresh, card(String)
    }

    @State private var vod = XtreamVODService.shared
    @State private var items: [XtreamVODItem] = []
    @State private var totalCount = 0
    @State private var hasMore = false
    @State private var query = ""
    /// The query the visible titles were loaded for, so the search debounce only reloads on change.
    @State private var loadedQuery = ""
    @State private var mode: XtreamVODBrowseMode = .catalog
    @State private var isLoading = true
    @State private var loadGeneration = 0
    @State private var selected: XtreamVODItem?
    @State private var entryRequest = 0
    @State private var pendingEntryClaim = false
    @FocusState private var focused: Field?

    /// Adaptive: Build 98 fixed seven 200 pt columns, leaving about 156 pt unused at the right of
    /// a 1080p screen. Cells now share the full width; the poster keeps its size.
    private let columns = TVXtreamVODLayout.columns

    var body: some View {
        VStack(alignment: .leading, spacing: TVScreenLayout.sectionSpacing) {
            header
            controls
            if let progress = vod.progress, Self.showsImportStatus(progress, providerID: provider.id, kind: kind) {
                importStatus(progress)
            }
            grid
        }
        .padding(.horizontal, horizontalInset)
        .padding(.top, topInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TVKyroAmbientBackdrop().ignoresSafeArea())
        .task(id: "\(provider.id)-\(kind.rawValue)-\(vod.revision)-\(mode.rawValue)") { await reload() }
        .task(id: query) {
            guard query != loadedQuery else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await reload()
        }
        .onAppear { requestEntry(focusRequest > 0 ? focusRequest : 1) }
        .onChange(of: focusRequest) { _, request in requestEntry(request) }
        .onChange(of: isTopMenuFocused) { _, menuOwnsFocus in if menuOwnsFocus { pendingEntryClaim = false } }
        .sheet(item: $selected) { item in TVXtreamVODDetailView(item: item) }
    }

    // MARK: - Header and controls

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(provider.name)
                .font(.system(size: 46, weight: .bold))
                .lineLimit(1)
            Text(subtitle)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Color.siloSecondaryText)
        }
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        var parts = ["IPTV \(kind.title)"]
        if mode == .catalog, totalCount > 0 { parts.append("\(totalCount.formatted()) titles") }
        if let refreshed = vod.refreshedAt(providerID: provider.id) {
            parts.append("Updated \(refreshed.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: " · ")
    }

    /// The page's single top row. Up from any control here returns to the top menu.
    private var controls: some View {
        HStack(spacing: 18) {
            TextField("Search \(kind.title.lowercased())", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 25))
                .padding(.horizontal, 18)
                .frame(width: 440, height: 58)
                .background(Color.siloSurface, in: RoundedRectangle(cornerRadius: 12))
                .focused($focused, equals: .search)
                .onMoveCommand(perform: handleTopRowMove)
            ForEach(XtreamVODBrowseMode.allCases, id: \.self) { option in
                Button(option.title) { mode = option }
                    .buttonStyle(TVKyroChipStyle(isSelected: mode == option))
                    .focused($focused, equals: .mode(option))
                    .onMoveCommand(perform: handleTopRowMove)
            }
            Spacer(minLength: 0)
            if isLoading { ProgressView() }
            Button("Refresh Catalog") { Task { await vod.refresh(providerID: provider.id) } }
                .buttonStyle(TVKyroChipStyle())
                .disabled(vod.activeProviderID != nil)
                .focused($focused, equals: .refresh)
                .onMoveCommand(perform: handleTopRowMove)
        }
        .focusSection()
    }

    private func handleTopRowMove(_ direction: MoveCommandDirection) {
        // The intentional page-to-menu boundary. Every other move stays native.
        if direction == .up { onMoveUp?() }
    }

    // MARK: - Grid

    private var grid: some View {
        ScrollView(.vertical, showsIndicators: false) {
            if items.isEmpty && !isLoading {
                Text(emptyMessage)
                    .font(.system(size: 26))
                    .foregroundStyle(Color.siloSecondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 30)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: TVXtreamVODLayout.rowSpacing) {
                    ForEach(items) { item in
                        Button { selected = item } label: {
                            TVXtreamVODPosterCard(item: item, providerName: provider.name,
                                                  progress: progressFraction(item))
                        }
                        .buttonStyle(TVKyroCardFocusStyle(cornerRadius: 14))
                        .focused($focused, equals: .card(item.id))
                    }
                }
            }
        }
        // Runs to the screen's side and bottom edges; margins keep resting cards in the safe area
        // and leave room for the focused card's lift (Build 98 clipped 24 pt inside the page).
        .tvEdgeToEdgeScroll(horizontalBleed: max(horizontalInset, TVScreenLayout.focusRoom))
        .onChange(of: focused) { _, field in
            guard case .card(let id)? = field, let index = items.firstIndex(where: { $0.id == id }) else { return }
            if TVXtreamVODFocusPlanner.shouldLoadMore(focusedIndex: index, loadedCount: items.count,
                                                       hasMore: hasMore, isLoading: isLoading) {
                Task { await loadMore() }
            }
        }
        .modifier(TVMenuEntryScroll(request: entryRequest, isTopMenuFocused: isTopMenuFocused,
                                    onReady: { _ in claimEntryFocus() }))
    }

    private var emptyMessage: String {
        switch mode {
        case .catalog:
            if !query.isEmpty { return "No \(kind.title.lowercased()) match “\(query)”." }
            return "No \(kind.title.lowercased()) imported yet. Refresh the catalog, or check this provider in Live TV Providers."
        case .continueWatching: return "Nothing in progress. \(kind.title) you start from this provider appear here."
        case .favorites: return "No favorites yet. Add titles from their detail page."
        }
    }

    private func progressFraction(_ item: XtreamVODItem) -> Double? {
        guard kind == .movie else { return nil }
        let state = vod.watchState(for: item)
        guard state.duration > 0, state.position > 0, !state.completed else { return nil }
        return min(1, state.position / state.duration)
    }

    // MARK: - Focus

    private func requestEntry(_ request: Int) {
        guard request > 0, !isTopMenuFocused else { return }
        entryRequest = request
    }

    private func claimEntryFocus() {
        guard !isTopMenuFocused else { return }
        switch TVXtreamVODFocusPlanner.entryTarget(itemIDs: items.prefix(1).map(\.id), isLoading: isLoading, mode: mode) {
        case .firstCard(let id): focused = .card(id); pendingEntryClaim = false
        case .mode(let option): focused = .mode(option); pendingEntryClaim = false
        case .wait: pendingEntryClaim = true
        }
    }

    // MARK: - Data

    private func reload() async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        let result: [XtreamVODItem]
        var more = false
        switch mode {
        case .catalog:
            result = await vod.page(providerID: provider.id, kind: kind, query: query)
            more = result.count >= TVXtreamVODFocusPlanner.pageSize
            let count = await vod.count(providerID: provider.id, kind: kind)
            if generation == loadGeneration { totalCount = count }
        case .continueWatching, .favorites:
            let personal = await vod.personalItems(providerID: provider.id, kind: kind,
                                                   favorites: mode == .favorites)
            result = query.isEmpty ? personal : personal.filter { $0.title.localizedCaseInsensitiveContains(query) }
        }
        // A newer reload owns the state; never leave the spinner stuck on a superseded one.
        guard generation == loadGeneration else { return }
        let focusedCardSurvives: Bool = {
            guard case .card(let id)? = focused else { return true }
            return result.contains { $0.id == id }
        }()
        items = result
        loadedQuery = query
        hasMore = more
        isLoading = false
        if pendingEntryClaim {
            claimEntryFocus()
        } else if !focusedCardSurvives {
            // The focused title disappeared (new query or mode): move to its nearest neighbour.
            focused = result.first.map { .card($0.id) } ?? .mode(mode)
        }
    }

    private func loadMore() async {
        guard mode == .catalog, hasMore, !isLoading else { return }
        let generation = loadGeneration
        isLoading = true
        let next = await vod.page(providerID: provider.id, kind: kind, query: query, offset: items.count)
        guard generation == loadGeneration else { return }
        let known = Set(items.map(\.id))
        items += next.filter { !known.contains($0.id) }
        hasMore = next.count >= TVXtreamVODFocusPlanner.pageSize
        isLoading = false
    }

    // MARK: - Import status

    /// In-progress imports show on every page of the provider; a finished import shows only
    /// where this page's own catalog failed, so a Movies failure does not clutter Series.
    static func showsImportStatus(_ progress: XtreamVODImportProgress, providerID: UUID, kind: XtreamVODKind) -> Bool {
        guard progress.providerID == providerID else { return false }
        switch progress.stage {
        case .connecting, .downloading, .importing: return true
        case .ready: return false
        case .failed, .cancelled:
            switch kind == .movie ? progress.movieResult : progress.seriesResult {
            case .failed, .unsupported, .authentication, .cancelled: return true
            case .notSelected, .waiting, .loading, .ready, .empty: return false
            }
        }
    }

    private func importStatus(_ progress: XtreamVODImportProgress) -> some View {
        let count: XtreamVODImportCount
        let stage: String
        switch progress.stage {
        case .connecting: count = kind == .movie ? progress.movies : progress.series; stage = "Connecting to provider"
        case .downloading(let active): count = active == .movie ? progress.movies : progress.series; stage = "Downloading \(active.title)"
        case .importing(let active): count = active == .movie ? progress.movies : progress.series; stage = "Importing \(active.title)"
        case .ready: count = kind == .movie ? progress.movies : progress.series; stage = "Ready"
        case .failed: count = kind == .movie ? progress.movies : progress.series; stage = "Import failed"
        case .cancelled: count = kind == .movie ? progress.movies : progress.series; stage = "Import cancelled"
        }
        return HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text(stage).font(.system(size: 24, weight: .semibold))
                if case .importing = progress.stage, let fraction = count.fraction {
                    ProgressView(value: fraction).frame(maxWidth: 520)
                    Text("\(count.processed.formatted()) / \(count.total.formatted()) source records · \(count.accepted.formatted()) imported")
                        .foregroundStyle(Color.siloSecondaryText)
                } else if progress.stage != .failed && progress.stage != .cancelled {
                    ProgressView()
                }
                if let message = progress.message {
                    Text(message).foregroundStyle(Color.siloSecondaryText).lineLimit(3)
                }
            }
            Spacer(minLength: 0)
            if vod.activeProviderID == provider.id {
                Button("Cancel Import") { vod.cancel() }.buttonStyle(TVKyroChipStyle())
            } else if progress.stage == .failed || progress.stage == .cancelled {
                Button("Retry Import") { Task { await vod.refresh(providerID: provider.id) } }
                    .buttonStyle(TVKyroChipStyle())
            }
        }
        .font(.system(size: 20))
        .padding(20)
        .background(Color.siloSurface.opacity(0.9), in: RoundedRectangle(cornerRadius: 16))
    }
}

/// IPTV VOD poster grid geometry (Build 99).
enum TVXtreamVODLayout {
    static var cellWidth: CGFloat { SiloTheme.Skyline.densePosterCardWidth + 24 }
    static let columnSpacing: CGFloat = 34
    static let rowSpacing: CGFloat = 38
    static let columns = [GridItem(.adaptive(minimum: cellWidth), spacing: columnSpacing)]

    static func columnCount(width: CGFloat) -> Int {
        TVScreenLayout.adaptiveColumnCount(width: width, minimum: cellWidth, spacing: columnSpacing)
    }
}

/// Poster card sized like the Silo dense poster rows: 2:3 artwork, title, and a resume bar.
private struct TVXtreamVODPosterCard: View {
    let item: XtreamVODItem
    let providerName: String
    let progress: Double?

    private var width: CGFloat { SiloTheme.Skyline.densePosterCardWidth + 24 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .bottomLeading) {
                artwork
                    .frame(width: width, height: width * 1.5)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                if let progress {
                    Capsule().fill(Color.white.opacity(0.25))
                        .frame(height: 6)
                        .overlay(alignment: .leading) {
                            Capsule().fill(KyroTheme.accentInk).frame(width: max(6, (width - 20) * progress))
                        }
                        .padding(10)
                }
            }
            Text(item.title)
                .font(.system(size: 20, weight: .semibold))
                .lineLimit(2)
                .frame(width: width, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title), \(item.category), \(providerName)")
    }

    @ViewBuilder
    private var artwork: some View {
        if let poster = item.poster, let url = URL(string: poster) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            Color.siloSurface
            VStack(spacing: 10) {
                Image(systemName: item.kind == .movie ? "film" : "tv")
                    .font(.system(size: 40, weight: .semibold))
                Text(item.title)
                    .font(.system(size: 17, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 10)
            }
            .foregroundStyle(Color.siloSecondaryText)
        }
    }
}

private struct TVXtreamVODDetailView: View {
    let item: XtreamVODItem
    @Environment(\.dismiss) private var dismiss
    @State private var vod = XtreamVODService.shared
    @State private var detail: XtreamVODDetail?
    @State private var error: String?
    @State private var season = 1
    @State private var playback: XtreamVODPlayback?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Button("Back") { dismiss() }.buttonStyle(TVKyroChipStyle())
                Text(item.title).font(.system(size: 50, weight: .bold))
                Text("\(item.category) · IPTV provider").font(.system(size: 23))
                    .foregroundStyle(Color.siloSecondaryText)
                if let summary = detail?.summary ?? item.summary { Text(summary).font(.system(size: 25)) }
                if let genre = detail?.genre ?? item.genre { Text(genre).font(.system(size: 21)) }
                HStack(spacing: 18) {
                    Button(vod.watchState(for: item).favorite ? "Remove Favorite" : "Add Favorite") {
                        vod.setFavorite(!vod.watchState(for: item).favorite, for: item)
                    }.buttonStyle(TVKyroChipStyle())
                    if item.kind == .movie {
                        Button(vod.watchState(for: item).position > 0 ? "Resume Movie" : "Play Movie") {
                            play(nil)
                        }.buttonStyle(TVKyroChipStyle(isSelected: true))
                    }
                }
                if let detail, item.kind == .series {
                    let seasons = Array(Set(detail.episodes.map(\.season))).sorted()
                    HStack {
                        ForEach(seasons, id: \.self) { number in
                            Button("Season \(number)") { season = number }
                                .buttonStyle(TVKyroChipStyle(isSelected: season == number))
                        }
                    }
                    ForEach(detail.episodes.filter { $0.season == season }) { episode in
                        Button { play(episode) } label: {
                            VStack(alignment: .leading) {
                                Text("\(episode.number). \(episode.title)").font(.system(size: 26, weight: .semibold))
                                if let summary = episode.summary { Text(summary).font(.system(size: 20)).lineLimit(2) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                            .background(Color.siloSurface, in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(TVKyroCardFocusStyle(cornerRadius: 14))
                    }
                }
                if let error { Text(error).foregroundStyle(.red).font(.system(size: 22)) }
            }
            .padding(70)
        }
        .background(TVKyroAmbientBackdrop())
        .task {
            do {
                let result = try await vod.detail(for: item)
                detail = result
                season = result.episodes.first?.season ?? 1
            } catch { self.error = (error as? LocalizedError)?.errorDescription ?? "Details unavailable" }
        }
        .fullScreenCover(item: $playback) { entry in TVXtreamVODPlayerView(entry: entry) }
    }

    private func play(_ episode: XtreamVODEpisode?) {
        do {
            let url = try vod.playbackURL(for: item, episode: episode)
            playback = .init(item: item, episode: episode, url: url)
            error = nil
        } catch { self.error = (error as? LocalizedError)?.errorDescription ?? "Playback unavailable" }
    }
}

private struct XtreamVODPlayback: Identifiable {
    let id = UUID()
    let item: XtreamVODItem
    let episode: XtreamVODEpisode?
    let url: URL
}

private struct TVXtreamVODPlayerView: View {
    let entry: XtreamVODPlayback
    @Environment(\.dismiss) private var dismiss
    @State private var vod = XtreamVODService.shared
    @State private var player = AVPlayer()

    var body: some View {
        TVXtreamAVPlayer(player: player)
            .ignoresSafeArea()
            .onAppear {
                player.replaceCurrentItem(with: AVPlayerItem(url: entry.url))
                let saved = vod.watchState(for: entry.item, episode: entry.episode)
                if saved.position > 0, !saved.completed {
                    player.seek(to: CMTime(seconds: saved.position, preferredTimescale: 600))
                }
                player.play()
            }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(10))
                    if !Task.isCancelled { saveProgress() }
                }
            }
            .onDisappear {
                saveProgress()
                player.pause()
                player.replaceCurrentItem(with: nil)
            }
            .onExitCommand { dismiss() }
    }

    private func saveProgress() {
        let position = player.currentTime().seconds
        let duration = player.currentItem?.duration.seconds ?? 0
        vod.saveProgress(position: position, duration: duration, item: entry.item, episode: entry.episode)
    }
}

private struct TVXtreamAVPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }
}
#endif
