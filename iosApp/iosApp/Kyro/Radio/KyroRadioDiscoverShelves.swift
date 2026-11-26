#if os(iOS)
import SwiftUI

enum KyroRadioShelfLink: Hashable {
    case directory(title: String, query: KyroRadioQuery)
    case favorites
    case history
}

struct KyroRadioDiscoverShelves: View {
    let local: KyroRadioDiscoverModel
    let preferences: KyroRadioPreferences
    let open: (KyroRadioShelfLink) -> Void
    @State private var featured = KyroRadioDiscoverModel()
    @State private var popular = KyroRadioDiscoverModel()
    private let library = KyroRadioLibrary.shared

    var body: some View {
        directory("Featured Stations", caption: "Most voted for on Radio Browser", model: featured)
            .onAppear { featured.loadIfNeeded(.init(ranking: .communityVotes)) }
        directory("Popular Stations", caption: "Most clicked on Radio Browser", model: popular)
            .onAppear { popular.loadIfNeeded(.worldwide()) }
        if preferences.countryCode != nil {
            directory("Local Stations", caption: preferences.regionTitle, model: local)
        }
        if !library.history.isEmpty {
            KyroRadioStationShelf(title: "Recently Played", stations: Array(library.history.prefix(12).map(\.station)),
                                  seeAll: { open(.history) })
        }
        if !library.favorites.isEmpty {
            KyroRadioStationShelf(title: "Favorite Stations", stations: Array(library.favorites.prefix(12).map(\.station)),
                                  seeAll: { open(.favorites) })
        }
    }

    private func directory(_ title: String, caption: String, model: KyroRadioDiscoverModel) -> some View {
        Group {
            if model.stations.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    KyroAudioShelfHeader(title: title, caption: caption)
                    switch model.phase {
                    case .idle, .loading:
                        ProgressView().accessibilityLabel("Loading \(title)").padding(.horizontal, 20)
                    case .loaded where model.canLoadMore:
                        Button("See All \(title)") { open(.directory(title: title, query: model.query)) }
                            .padding(.horizontal, 20)
                    case .loaded:
                        Text("No playable stations found.").font(.subheadline).padding(.horizontal, 20)
                    case .failed:
                        Button("Retry \(title)") { model.retry() }.padding(.horizontal, 20)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                KyroRadioStationShelf(title: title, caption: caption, stations: Array(model.stations.prefix(12)),
                                      seeAll: { open(.directory(title: title, query: model.query)) })
            }
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
}

private struct KyroRadioStationShelf: View {
    let title: String
    var caption: String?
    let stations: [KyroRadioStation]
    let seeAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            KyroAudioShelfHeader(title: title, caption: caption, seeAll: seeAll)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(stations) { KyroRadioStationTile(station: $0, size: 120) }
                }
                .padding(.horizontal, 20)
            }
            .scrollIndicators(.hidden)
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
}

struct KyroRadioStationTile: View {
    let station: KyroRadioStation
    let size: CGFloat
    private let player = KyroRadioPlayer.shared
    private let library = KyroRadioLibrary.shared

    var body: some View {
        Button { player.play(station) } label: {
            KyroAudioArtworkTile(title: station.name, subtitle: station.location, size: size) {
                KyroRadioArtwork(station: station, size: size, decodeSize: 144)
                    .overlay(alignment: .bottomTrailing) {
                        if library.isFavorite(station.id) {
                            Image(systemName: "heart.fill")
                                .font(.caption.weight(.semibold)).padding(6)
                                .background(.black.opacity(0.8), in: Circle()).padding(5)
                                .accessibilityHidden(true)
                        }
                    }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play \(station.name)")
        .accessibilityHint(station.location)
        .accessibilityAction(named: Text(library.isFavorite(station.id) ? "Remove from Favorites" : "Add to Favorites")) {
            library.toggleFavorite(station)
        }
        .contextMenu {
            Button(library.isFavorite(station.id) ? "Remove from Favorites" : "Add to Favorites",
                   systemImage: library.isFavorite(station.id) ? "heart.slash" : "heart") {
                library.toggleFavorite(station)
            }
        }
    }
}

struct KyroRadioDirectoryPage: View {
    let title: String
    let query: KyroRadioQuery
    @Environment(\.nowPlayingShelfCoversPushedPages) private var shelfCoversPushedPages
    @State private var model = KyroRadioDiscoverModel()

    var body: some View {
        List { KyroRadioDirectoryRows(model: model) }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .siloPageBackground()
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !shelfCoversPushedPages { KyroRadioPageNowPlayingBar() }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .onAppear { model.loadIfNeeded(query) }
    }
}

struct KyroRadioDirectoryRows: View {
    let model: KyroRadioDiscoverModel

    var body: some View {
        switch model.phase {
        case .idle, .loading:
            ProgressView("Finding stations…")
                .frame(maxWidth: .infinity).padding(.vertical, 24).listRowBackground(Color.clear)
        case .failed(let message):
            ContentUnavailableView {
                Label("Stations Unavailable", systemImage: "wifi.exclamationmark")
            } description: { Text(message) } actions: {
                Button("Try Again") { model.retry() }.buttonStyle(.borderedProminent)
            }
            .listRowBackground(Color.clear)
        case .loaded:
            if model.stations.isEmpty && !model.canLoadMore {
                ContentUnavailableView("No Stations Found", systemImage: "radio",
                    description: Text("Try a different name, genre or place, or search worldwide."))
                    .listRowBackground(Color.clear)
            }
            ForEach(model.stations) { station in
                KyroRadioStationRow(station: station)
            }
            if model.isLoadingMore {
                ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
            } else if model.loadMoreFailed || model.canLoadMore {
                Button(model.loadMoreFailed ? "Couldn’t load more. Try Again" : "Load More Stations") { model.loadMore() }
                    .frame(maxWidth: .infinity).listRowBackground(Color.clear)
            }
        }
    }
}
#endif
