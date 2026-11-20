#if os(iOS)
import NukeUI
import SwiftUI

private struct KyroIPTVPlayback: Identifiable {
    let id = UUID()
    let title: String
    let source: String
    let url: URL
}

struct KyroIPTVVODCatalogView: View {
    let provider: LiveTVProvider
    let kind: XtreamVODKind
    @Binding var category: String?
    @Binding var query: String

    private let service = XtreamVODService.shared
    @State private var items: [XtreamVODItem] = []
    @State private var categories: [String] = []
    @State private var isLoading = false
    @State private var hasMore = true
    @State private var errorMessage: String?
    @State private var loadGeneration = 0

    private let columns = [GridItem(.adaptive(minimum: 130, maximum: 190), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                Text("IPTV \(kind.title)")
                    .font(.largeTitle.bold())
                Label(provider.name, systemImage: "antenna.radiowaves.left.and.right")
                    .font(.subheadline).foregroundStyle(.secondary)

                if !categories.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            categoryButton("All", selected: category == nil) { category = nil }
                            ForEach(categories, id: \.self) { name in
                                categoryButton(name, selected: category == name) { category = name }
                            }
                        }
                    }
                }

                if let progress = service.progress, progress.providerID == provider.id {
                    VStack(alignment: .leading, spacing: 5) {
                        if let message = progress.message { Text(message) }
                        else { Text("Importing IPTV catalogs…") }
                        let count = kind == .movie ? progress.movies : progress.series
                        if count.total > 0 {
                            ProgressView(value: count.fraction ?? 0)
                            Text("\(count.accepted.formatted()) of \(count.total.formatted()) titles")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if service.isRefreshing {
                            ProgressView()
                        }
                    }
                    .font(.footnote)
                }

                if items.isEmpty && !isLoading {
                    ContentUnavailableView(query.isEmpty ? "No IPTV \(kind.title) Yet" : "No Results",
                                           systemImage: kind == .movie ? "film" : "tv",
                                           description: Text(query.isEmpty
                                            ? "Import this provider’s \(kind.title.lowercased()) catalog to browse titles."
                                            : "Try another search or category."))
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(.footnote) }

                if query.isEmpty && items.isEmpty {
                    Button(service.isRefreshing ? "Importing…" : "Import IPTV Catalogs") {
                        Task {
                            _ = await service.refresh(providerID: provider.id)
                            await reload()
                        }
                    }
                    .disabled(service.isRefreshing)
                    .buttonStyle(.borderedProminent)
                }

                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(items) { item in
                        NavigationLink {
                            KyroIPTVVODDetailView(item: item, providerName: provider.name)
                        } label: {
                            KyroIPTVVODPoster(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if hasMore && !items.isEmpty {
                    ProgressView().frame(maxWidth: .infinity)
                        .task { await loadNext() }
                }
            }
            .padding(SiloTheme.padding)
        }
        .siloPageBackground()
        .searchable(text: $query, prompt: "Search IPTV \(kind.title)")
        .task(id: "\(provider.id.uuidString)|\(kind.rawValue)|\(category ?? "")|\(query)") {
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
            guard !Task.isCancelled else { return }
            await reload()
        }
        .refreshable {
            _ = await service.refresh(providerID: provider.id)
            await reload()
        }
    }

    private func categoryButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .tint(selected ? .accentColor : .secondary)
    }

    private func reload() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        items = []
        hasMore = true
        isLoading = false
        errorMessage = nil
        categories = await service.categories(providerID: provider.id, kind: kind)
        guard generation == loadGeneration, !Task.isCancelled else { return }
        await loadNext(generation: generation)
    }

    private func loadNext(generation: Int? = nil) async {
        guard !isLoading && hasMore && IPTVVODPreference.isEnabled() else { return }
        isLoading = true
        let activeGeneration = generation ?? loadGeneration
        let page = await service.page(providerID: provider.id, kind: kind, query: query,
                                      category: category, offset: items.count)
        guard !Task.isCancelled, activeGeneration == loadGeneration else {
            if activeGeneration == loadGeneration { isLoading = false }
            return
        }
        items.append(contentsOf: page)
        hasMore = page.count == 100
        isLoading = false
    }
}

private struct KyroIPTVVODPoster: View {
    let item: XtreamVODItem

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            LazyImage(url: item.poster.flatMap(URL.init(string:))) { state in
                if let image = state.image { image.resizable().scaledToFill() }
                else { Image(systemName: item.kind == .movie ? "film" : "tv").resizable()
                    .scaledToFit().padding(35).foregroundStyle(.secondary) }
            }
            .frame(height: 190)
            .frame(maxWidth: .infinity)
            .clipped()
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(item.title).font(.subheadline.weight(.medium)).lineLimit(2)
            Text("IPTV").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct KyroIPTVVODDetailView: View {
    let item: XtreamVODItem
    let providerName: String

    private let service = XtreamVODService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var detail: XtreamVODDetail?
    @State private var errorMessage: String?
    @State private var playback: KyroIPTVPlayback?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    KyroIPTVVODPoster(item: item).frame(width: 150)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.title).font(.title.bold())
                        Text("IPTV · \(providerName)").font(.subheadline).foregroundStyle(.secondary)
                        if let genre = detail?.genre ?? item.genre { Text(genre).font(.footnote) }
                        if let rating = detail?.rating ?? item.rating { Text("Rating \(rating)").font(.footnote) }
                    }
                }
                if let summary = detail?.summary ?? item.summary { Text(summary) }
                if item.kind == .movie {
                    Button("Play from IPTV") { play(episode: nil) }
                        .buttonStyle(.borderedProminent)
                } else if let detail {
                    ForEach(Array(Set(detail.episodes.map(\.season))).sorted(), id: \.self) { season in
                        Text("Season \(season)").font(.headline)
                        ForEach(detail.episodes.filter { $0.season == season }) { episode in
                            Button {
                                play(episode: episode)
                            } label: {
                                HStack {
                                    Text("\(episode.number). \(episode.title)")
                                    Spacer()
                                    Image(systemName: "play.fill")
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(.footnote) }
            }
            .padding(SiloTheme.padding)
        }
        .navigationTitle(item.title)
        .task {
            do { detail = try await service.detail(for: item) }
            catch { errorMessage = (error as? LocalizedError)?.errorDescription ?? "Details are unavailable." }
        }
        .fullScreenCover(item: $playback) { request in
            PlayerView(contentId: "iptv-vod-\(request.id.uuidString)",
                       externalPlaybackURL: request.url,
                       externalPlaybackTitle: request.title,
                       externalPlaybackSource: request.source,
                       onDismissRequested: { dismiss() })
            .id(request.id)
            .interactiveDismissDisabled()
        }
    }

    private func play(episode: XtreamVODEpisode?) {
        do {
            let url = try service.playbackURL(for: item, episode: episode)
            playback = KyroIPTVPlayback(title: episode?.title ?? item.title,
                                         source: "IPTV · \(providerName)", url: url)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "This title cannot be played."
        }
    }
}

#endif
