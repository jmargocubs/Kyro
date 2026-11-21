#if os(iOS)
import Foundation
import Observation

/// A bounded, incremental window across Silo libraries and locally indexed Xtream catalogs.
/// No provider network refresh or episode lookup is initiated by browsing.
@MainActor
@Observable
final class KyroUnifiedBrowseModel {
    private struct Source {
        enum Location {
            case silo(Int, LibraryVideoScope?)
            case iptv(UUID)
        }
        let location: Location
        var continuation: APIv2CatalogContinuation?
        var offset = 0
        var exhausted = false
    }

    private(set) var titles: [UnifiedVODTitle] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var hasMore = false
    private(set) var hadSourceFailure = false
    private(set) var windowWasTrimmed = false

    @ObservationIgnored private var sources: [Source] = []
    @ObservationIgnored private var entries: [UnifiedVODEntry] = []
    @ObservationIgnored private var siloLibraries: [String: Int] = [:]
    @ObservationIgnored private var nextSource = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var identity = ""
    @ObservationIgnored private let service = XtreamVODService.shared

    /// A source page is at most 100 rows. Limit retained card models rather than retaining
    /// an ever-growing array for a 100K-item provider. Paging continues past this window.
    private let maximumRetainedEntries = 900

    func configure(kind: XtreamVODKind, libraries: [Library], providers: [LiveTVProvider],
                   vodEnabled: Bool, catalogRevision: Int) async {
        let providerIDs = vodEnabled ? providers.filter { $0.kind == .xtream }.map(\.id) : []
        let key = "\(kind.rawValue):\(libraries.map(\.id)):\(providerIDs):\(vodEnabled):\(catalogRevision)"
        guard identity != key else { return }
        generation &+= 1
        let token = generation
        currentKind = kind
        identity = key
        entries = []
        siloLibraries = [:]
        titles = []
        nextSource = 0
        hasLoaded = false
        hadSourceFailure = false
        windowWasTrimmed = false
        sources = libraries.map { library in
            Source(location: .silo(library.id, library.isMixedLibrary ? (kind == .movie ? .movie : .series) : nil))
        } + providerIDs.map { Source(location: .iptv($0)) }
        hasMore = !sources.isEmpty
        // Seed each configured source so IPTV is visible without a source selection. Work is
        // sequential and cancellable; each query is one indexed SQLite page or Silo page.
        for index in sources.indices {
            guard token == generation, !Task.isCancelled else {
                if token == generation { identity = ""; isLoading = false }
                return
            }
            await fetchPage(at: index, token: token)
        }
        guard token == generation, !Task.isCancelled else {
            if token == generation { identity = ""; isLoading = false }
            return
        }
        hasLoaded = true
    }

    func refresh(kind: XtreamVODKind, libraries: [Library], providers: [LiveTVProvider],
                 vodEnabled: Bool, catalogRevision: Int) async {
        identity = ""
        await configure(kind: kind, libraries: libraries, providers: providers,
                        vodEnabled: vodEnabled, catalogRevision: catalogRevision)
    }

    func loadMore() async {
        guard hasLoaded, hasMore, !isLoading, !sources.isEmpty else { return }
        let token = generation
        for step in 0..<sources.count {
            let index = (nextSource + step) % sources.count
            if !sources[index].exhausted {
                nextSource = (index + 1) % sources.count
                await fetchPage(at: index, token: token)
                return
            }
        }
        hasMore = false
    }

    func libraryID(for item: BrowseItem) -> Int? { siloLibraries[item.contentId] }

    private func fetchPage(at index: Int, token: Int) async {
        guard token == generation, !sources[index].exhausted else { return }
        isLoading = true
        let source = sources[index]
        do {
            let pageEntries: [UnifiedVODEntry]
            var continuation: APIv2CatalogContinuation?
            var exhausted = false
            var startsOver = false
            switch source.location {
            case .silo(let libraryID, let scope):
                let page: CatalogListPage
                if let next = source.continuation {
                    page = try await SiloAPI.shared.nextCatalogPage(next)
                } else {
                    var state = CatalogFilterState.none
                    state.sort = .title
                    state.order = .asc
                    page = try await StartupContentPrefetcher.fetchBrowseFirstPage(
                        libraryId: libraryID, state: state, mediaScope: scope)
                }
                pageEntries = page.response.items.map(UnifiedVODEntry.init(silo:))
                continuation = page.continuation
                exhausted = continuation == nil
                startsOver = page.startsOver
            case .iptv(let providerID):
                let items = await service.page(providerID: providerID, kind: currentKind,
                                               offset: source.offset)
                pageEntries = items.map(UnifiedVODEntry.init(iptv:))
                exhausted = items.count < 100
            }
            guard token == generation, !Task.isCancelled else {
                if token == generation { isLoading = false }
                return
            }
            if startsOver, case .silo(let libraryID, _) = source.location {
                entries.removeAll { entry in
                    guard let id = entry.siloItem?.contentId else { return false }
                    return siloLibraries[id] == libraryID
                }
                siloLibraries = siloLibraries.filter { $0.value != libraryID }
            }
            if case .silo(let libraryID, _) = source.location {
                for item in pageEntries {
                    if let silo = item.siloItem { siloLibraries[silo.contentId] = libraryID }
                }
            }
            sources[index].continuation = continuation
            sources[index].offset += pageEntries.count
            sources[index].exhausted = exhausted
            let appended = UnifiedVODCatalog.appendPage(pageEntries, to: entries,
                                                        maximum: maximumRetainedEntries)
            entries = appended.entries
            if appended.trimmed {
                let retainedSiloIDs = Set(entries.compactMap { $0.siloItem?.contentId })
                siloLibraries = siloLibraries.filter { retainedSiloIDs.contains($0.key) }
                windowWasTrimmed = true
            }
            titles = UnifiedVODCatalog.aggregate(entries)
            hasMore = sources.contains { !$0.exhausted }
        } catch {
            guard token == generation, !Task.isCancelled else {
                if token == generation { isLoading = false }
                return
            }
            sources[index].exhausted = true
            hadSourceFailure = true
            hasMore = sources.contains { !$0.exhausted }
        }
        if token == generation { isLoading = false }
    }

    @ObservationIgnored private var currentKind: XtreamVODKind = .movie

}
#endif
