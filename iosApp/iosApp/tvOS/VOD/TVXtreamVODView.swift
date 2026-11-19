#if os(tvOS)
import SwiftUI
import AVKit

/// Provider-only catalog page; Silo cards, collections and playback never pass through this route.
struct TVXtreamVODView: View {
    let provider: LiveTVProvider
    let kind: XtreamVODKind
    let focusRequest: Int
    let isTopMenuFocused: Bool
    let onMoveUp: (() -> Void)?
    @State private var vod = XtreamVODService.shared
    @State private var items: [XtreamVODItem] = []
    @State private var query = ""
    @State private var personalMode = 0 // 0 catalog, 1 favorites, 2 continue watching
    @State private var isLoading = false
    @State private var selected: XtreamVODItem?
    private let columns = Array(repeating: GridItem(.flexible(minimum: 220, maximum: 320), spacing: 28), count: 5)

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                VStack(alignment: .leading) {
                    Text("\(provider.name) \(kind.title)").font(.system(size: 42, weight: .bold))
                    Text("Provider catalog · separate from Silo").font(.system(size: 21))
                        .foregroundStyle(Color.siloSecondaryText)
                }
                Spacer()
                Button("Refresh Catalog") { Task { await vod.refresh(providerID: provider.id) } }
                    .buttonStyle(TVKyroChipStyle())
                    .disabled(vod.activeProviderID != nil)
                    .onMoveCommand { if $0 == .up { onMoveUp?() } }
            }
            HStack {
                TextField("Search \(kind.title.lowercased())", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 25))
                    .padding(15)
                    .background(Color.siloSurface, in: RoundedRectangle(cornerRadius: 12))
                    .frame(width: 500)
                    .onMoveCommand { if $0 == .up { onMoveUp?() } }
                if isLoading { ProgressView() }
                Button("All") { personalMode = 0; Task { await reload() } }
                    .buttonStyle(TVKyroChipStyle(isSelected: personalMode == 0))
                Button("Favorites") { personalMode = 1; Task { await reload() } }
                    .buttonStyle(TVKyroChipStyle(isSelected: personalMode == 1))
                Button("Continue Watching") { personalMode = 2; Task { await reload() } }
                    .buttonStyle(TVKyroChipStyle(isSelected: personalMode == 2))
            }
            if let progress = vod.progress, progress.providerID == provider.id,
               progress.stage != .ready {
                importStatus(progress)
            }
            ScrollView {
                LazyVGrid(columns: columns, spacing: 30) {
                    ForEach(items) { item in
                        Button { selected = item } label: { card(item) }
                            .buttonStyle(TVKyroCardFocusStyle(cornerRadius: 16))
                    }
                    if personalMode == 0 && items.count >= 100 {
                        Button("Load More") { Task { await loadMore() } }
                            .buttonStyle(TVKyroChipStyle())
                    }
                }
            }
            if items.isEmpty && !isLoading {
                Text("No \(kind.title.lowercased()) in this catalog. Enable and refresh VOD in Live TV Providers.")
                    .font(.system(size: 25)).foregroundStyle(Color.siloSecondaryText)
            }
        }
        .padding(.horizontal, 72)
        .padding(.top, 28)
        .padding(.bottom, 30)
        .background(TVKyroAmbientBackdrop())
        .task(id: "\(provider.id)-\(kind.rawValue)-\(vod.revision)") { await reload() }
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await reload()
        }
        .sheet(item: $selected) { item in TVXtreamVODDetailView(item: item) }
    }

    private func reload() async {
        isLoading = true
        let result: [XtreamVODItem]
        if personalMode == 0 {
            result = await vod.page(providerID: provider.id, kind: kind, query: query)
        } else {
            let personal = await vod.personalItems(providerID: provider.id, kind: kind, favorites: personalMode == 1)
            result = query.isEmpty ? personal : personal.filter { $0.title.localizedCaseInsensitiveContains(query) }
        }
        guard !Task.isCancelled else { return }
        items = result
        isLoading = false
    }

    private func loadMore() async {
        guard !isLoading else { return }
        isLoading = true
        let next = await vod.page(providerID: provider.id, kind: kind, query: query, offset: items.count)
        items += next
        isLoading = false
    }

    private func card(_ item: XtreamVODItem) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            if let poster = item.poster, let url = URL(string: poster) {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: {
                    Image(systemName: kind == .movie ? "film" : "tv").font(.system(size: 46))
                }
                .frame(height: 210).frame(maxWidth: .infinity).clipped()
            } else {
                Image(systemName: kind == .movie ? "film" : "tv")
                    .font(.system(size: 46)).frame(maxWidth: .infinity).frame(height: 210)
            }
            Text(item.title).font(.system(size: 23, weight: .semibold)).lineLimit(2)
            Text("\(provider.name) · \(item.category)").font(.system(size: 17)).lineLimit(1)
                .foregroundStyle(Color.siloSecondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.siloSurface, in: RoundedRectangle(cornerRadius: 16))
    }

    private func importStatus(_ progress: XtreamVODImportProgress) -> some View {
        let count: XtreamVODImportCount
        let stage: String
        switch progress.stage {
        case .connecting: count = progress.movies; stage = "Connecting to provider"
        case .downloading(let kind): count = kind == .movie ? progress.movies : progress.series; stage = "Downloading \(kind.title)"
        case .importing(let kind): count = kind == .movie ? progress.movies : progress.series; stage = "Importing \(kind.title)"
        case .ready: count = progress.series; stage = "Ready"
        case .failed: count = progress.series; stage = "Import failed"
        case .cancelled: count = progress.series; stage = "Import cancelled"
        }
        return VStack(alignment: .leading, spacing: 12) {
            Text(stage).font(.system(size: 25, weight: .semibold))
            if case .importing = progress.stage, let fraction = count.fraction {
                ProgressView(value: fraction)
                Text("\(count.processed.formatted()) / \(count.total.formatted()) records · \(count.accepted.formatted()) accepted · \(count.malformed + count.duplicate) skipped")
            } else if progress.stage != .failed && progress.stage != .cancelled { ProgressView() }
            if let message = progress.message { Text(message) }
            if vod.activeProviderID == provider.id {
                Button("Cancel VOD Import") { vod.cancel() }.buttonStyle(TVKyroChipStyle())
            } else if progress.stage == .failed || progress.stage == .cancelled {
                Button("Retry VOD Import") { Task { await vod.refresh(providerID: provider.id) } }
                    .buttonStyle(TVKyroChipStyle())
            }
        }
        .font(.system(size: 20))
        .padding(20)
        .background(Color.siloSurface, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct TVXtreamVODRail: View {
    let providers: [LiveTVProvider]
    let kind: XtreamVODKind
    @State private var vod = XtreamVODService.shared
    @State private var entries: [(LiveTVProvider, XtreamVODItem)] = []
    @State private var selected: XtreamVODItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("IPTV \(kind.title)").font(.system(size: 28, weight: .bold))
            ScrollView(.horizontal) {
                HStack(spacing: 16) {
                    ForEach(entries, id: \.1.id) { provider, item in
                        Button { selected = item } label: {
                            VStack(alignment: .leading) {
                                Text(item.title).font(.system(size: 21, weight: .semibold)).lineLimit(2)
                                Text(provider.name).font(.system(size: 17)).foregroundStyle(Color.siloSecondaryText)
                            }
                            .frame(width: 210, height: 84, alignment: .leading).padding(14)
                            .background(Color.siloSurface, in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(TVKyroCardFocusStyle(cornerRadius: 14))
                    }
                }
            }
        }
        .padding(.horizontal, 72)
        .frame(height: 156)
        .task(id: vod.revision) {
            var result: [(LiveTVProvider, XtreamVODItem)] = []
            for provider in providers {
                result += await vod.page(providerID: provider.id, kind: kind).prefix(8).map { (provider, $0) }
            }
            entries = result
        }
        .sheet(item: $selected) { item in TVXtreamVODDetailView(item: item) }
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
