import SwiftUI

/// Full-screen unified search. One query fans out into independent Silo and Live TV sections.
struct SearchView: View {
    @State private var coordinator: UnifiedSearchCoordinator
    @State private var selectedFilter: UnifiedSearchFilter = .all
    @State private var liveTVVisibleLimit = UnifiedSearchResultsSection.combinedPreviewLimit
    @State private var liveTVService = LiveTVService.shared
    @State private var serverRegistry = ServerRegistry.shared
    @Environment(AppRouter.self) private var router
    #if os(iOS)
    @FocusState private var isSearchFieldFocused: Bool
    #endif
    private let usesTVTopMenuInset: Bool
    /// A query handed over by Siri. Search replaces whatever the field held
    /// with it, then clears it so no later Search picks it up again.
    @Binding private var seededQuery: AppRouter.SearchRequest?

    private var siloAdapter: UnifiedSearchSiloAdapter {
        coordinator.silo as! UnifiedSearchSiloAdapter
    }
    private var viewModel: SearchViewModel { siloAdapter.searchModel }
    private var requestsViewModel: RequestSearchSectionViewModel { siloAdapter.requestSearchModel }

    @MainActor
    init(
        usesTVTopMenuInset: Bool = true,
        seededQuery: Binding<AppRouter.SearchRequest?> = .constant(nil)
    ) {
        let searchModel = SearchViewModel(includesPeople: true, includesEpisodes: true)
        // The unified search has only All / Movies & TV / Live TV filters. Its Silo scope is video
        // with episodes, not audiobooks, regardless of the device's optional audiobook tab.
        searchModel.audiobooksEnabled = false
        let requestModel = RequestSearchSectionViewModel()
        _coordinator = State(initialValue: UnifiedSearchCoordinator(
            silo: UnifiedSearchSiloAdapter(searchModel: searchModel,
                                           requestSearchModel: requestModel)
        ))
        self.usesTVTopMenuInset = usesTVTopMenuInset
        self._seededQuery = seededQuery
    }

    var body: some View {
        ScrollView {
            VStack(spacing: SiloTheme.padding) {
                if shouldShowFilters {
                    filterControl
                    #if os(tvOS)
                        .padding(.horizontal, SiloTheme.padding)
                        // The picker is a centered 760pt pill inside a 1600pt column.
                        .frame(maxWidth: .infinity)
                        .focusSection()
                    #elseif os(macOS)
                        .padding(.horizontal, SiloTheme.padding)
                    #endif
                }
                content
            }
            .padding(.horizontal, SiloTheme.padding)
            #if os(tvOS)
            .padding(.top, usesTVTopMenuInset ? TVTopMenuLayout.contentTopInset : SiloTheme.padding)
            #else
            .padding(.top, SiloTheme.smallPadding)
            #endif
#if os(tvOS)
            .siloFormWidth(tvSearchContentWidth)
#endif
        }
        .siloPageBackground()
        #if os(tvOS)
        .safeAreaPadding(.horizontal, tvSearchSafeHorizontalPadding)
        #endif
        .navigationTitle("Search")
        .siloNavigationTitleDisplayMode(.inline)
        .siloToolbarColorSchemeDark()
        .siloNavigationBarSurfaceBackground()
        .siloSearchable(text: searchText, prompt: "Search movies, series, and live TV...")
        #if os(iOS)
        .searchFocused($isSearchFieldFocused)
        .task {
            // A Siri search shows its results; the keyboard would cover them.
            guard seededQuery == nil else { return }
            await focusSearchField()
        }
        .onChange(of: router.presentedItemDetail != nil) { _, isPresented in
            // On iPad the detail sheet leaves Search on screen, so the field
            // stays first responder under it and its keyboard returns over the sheet.
            if isPresented { isSearchFieldFocused = false }
        }
        #endif
        .task(id: seededQuery?.id) {
            guard let seed = seededQuery else { return }
            selectedFilter = .all
            searchText.wrappedValue = seed.query
            seededQuery = nil
        }
        .onAppear {
            coordinator.synchronizeSiloIdentity(restartSearch: false)
            coordinator.resumeAfterDismissalIfNeeded()
            Task { await coordinator.catalogDidChange() }
        }
        .onDisappear {
            coordinator.cancelForDismissal()
        }
        .onChange(of: router.authState) { _, _ in
            coordinator.synchronizeSiloIdentity()
        }
        .onChange(of: serverRegistry.activeServerId) { _, _ in
            coordinator.synchronizeSiloIdentity()
        }
        .onChange(of: liveTVService.selectedProviderID) { _, _ in
            Task { await coordinator.catalogDidChange() }
        }
        .onChange(of: liveTVService.channelCatalogRevision) { _, _ in
            Task { await coordinator.catalogDidChange() }
        }
    }

    private var searchText: Binding<String> {
        Binding(
            get: { viewModel.query },
            set: { value in
                viewModel.query = value
                liveTVVisibleLimit = UnifiedSearchResultsSection.combinedPreviewLimit
                coordinator.onQueryChanged(value)
            }
        )
    }

    private var shouldShowFilters: Bool {
        !viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private var filterControl: some View {
        #if os(iOS)
        Menu {
            ForEach(UnifiedSearchFilter.allCases) { filter in
                Button {
                    selectedFilter = filter
                } label: {
                    if selectedFilter == filter {
                        Label(filter.title, systemImage: "checkmark")
                    } else {
                        Text(filter.title)
                    }
                }
                .accessibilityAddTraits(selectedFilter == filter ? .isSelected : [])
            }
        } label: {
            HStack(spacing: 6) {
                Text(selectedFilter.title)
                    .font(.siloBody)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .bold()
                    .imageScale(.small)
            }
            .foregroundStyle(Color.siloOnSurface)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(Capsule().fill(Color.siloChromeRestingFill))
            .overlay(Capsule().strokeBorder(Color.siloChromeRestingBorder, lineWidth: 1))
            .contentShape(Capsule())
        }
        .menuOrder(.fixed)
        .accessibilityLabel("Search filter")
        .accessibilityValue(selectedFilter.title)
        .frame(maxWidth: .infinity, alignment: .leading)
        #else
        Picker("Search filter", selection: $selectedFilter) {
            ForEach(UnifiedSearchFilter.allCases) { filter in
                Text(filter.title).tag(filter)
            }
        }
        .pickerStyle(.segmented)
#if os(tvOS)
        .siloFormWidth(tvFilterWidth)
#endif
        #endif
    }

    @ViewBuilder
    private var content: some View {
        if !shouldShowFilters {
            VStack {
                Spacer(minLength: 80)
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: "Search \(AppBrand.name)",
                    subtitle: "Find movies, series, people, and live TV"
                )
            }
        } else {
            VStack(alignment: .leading, spacing: SiloTheme.padding) {
                if selectedFilter.showsMoviesAndTV { moviesAndTVSection }
                if selectedFilter.showsLiveTV { liveTVSection }
            }
        }
    }

    private var moviesAndTVSection: some View {
        let isCombined = selectedFilter == .all
        let visibleItems = isCombined ? Array(viewModel.results.prefix(6)) : viewModel.results
        let hasMoreTitles = viewModel.hasMore || viewModel.total > visibleItems.count
        let contentCount = viewModel.results.count + viewModel.people.count + requestsViewModel.results.count

        return VStack(alignment: .leading, spacing: SiloTheme.padding) {
            sectionHeader(
                title: "Movies & TV",
                count: coordinator.isSiloIdentityCurrent ? coordinator.siloState.resultCount : 0,
                showsSeeAll: isCombined && hasMoreTitles,
                seeAll: { selectedFilter = UnifiedSearchFilter.all.seeAllFilter(for: .moviesAndTV) }
            )

            if !coordinator.isSiloIdentityCurrent {
                sourceMessage("Updating Silo results for this profile…", symbol: "arrow.clockwise")
            } else {
                if !viewModel.people.isEmpty { peopleSection }
                if !visibleItems.isEmpty {
                    titleResults(items: visibleItems, showsPagination: !isCombined)
                }
                if !requestsViewModel.results.isEmpty {
                    RequestSearchSectionView(viewModel: requestsViewModel)
                }
                if contentCount == 0 {
                    siloEmptyOrStatus
                } else if coordinator.siloState.phase == .partialFailure,
                          let message = coordinator.siloState.message {
                    sourceMessage(message, symbol: "exclamationmark.triangle")
                }
            }
        }
    }

    @ViewBuilder
    private var siloEmptyOrStatus: some View {
        switch coordinator.siloState.phase {
        case .debouncing, .loading:
            searchLoading
        case .failed, .partialFailure:
            if let error = viewModel.error {
                ErrorView(state: error, onRetry: { coordinator.retrySilo() })
            } else {
                sourceMessage(coordinator.siloState.message ?? "Silo search failed.",
                             symbol: "exclamationmark.triangle", retry: coordinator.retrySilo)
            }
        case .unavailable:
            sourceMessage(coordinator.siloState.message ?? "Silo search is unavailable.",
                         symbol: "person.crop.circle")
        case .loaded:
            EmptyStateView(icon: "magnifyingglass", title: "No Movies & TV results",
                           subtitle: "Try a different search term")
        case .idle:
            EmptyView()
        }
    }

    private var liveTVSection: some View {
        let isCombined = selectedFilter == .all
        let count = coordinator.liveTVResults.count
        let visibleLimit = isCombined ? UnifiedSearchResultsSection.combinedPreviewLimit : liveTVVisibleLimit
        let visibleResults = Array(coordinator.liveTVResults.prefix(visibleLimit))
        let hasMore = UnifiedSearchResultsSection.hasAdditionalResults(total: count, visible: visibleResults.count)
        let catalogIsCurrent = coordinator.isLiveTVCatalogCurrent(
            providerID: liveTVService.selectedProviderID,
            revision: liveTVService.channelCatalogRevision
        )

        return VStack(alignment: .leading, spacing: SiloTheme.smallPadding) {
            sectionHeader(
                title: "Live TV",
                count: catalogIsCurrent ? coordinator.liveTVState.resultCount : 0,
                showsSeeAll: isCombined && hasMore,
                seeAll: {
                    selectedFilter = UnifiedSearchFilter.all.seeAllFilter(for: .liveTV)
                    liveTVVisibleLimit = min(UnifiedSearchResultsSection.liveTVPageSize, count)
                }
            )

            if !catalogIsCurrent {
                sourceMessage("Updating channels…", symbol: "arrow.clockwise")
            } else if !visibleResults.isEmpty {
                LazyVStack(spacing: SiloTheme.smallPadding) {
                    ForEach(visibleResults) { result in
                        liveTVResultRow(result)
                    }
                }
                if !isCombined && hasMore {
                    Button("Load More Channels") {
                        liveTVVisibleLimit = UnifiedSearchResultsSection.nextVisibleLimit(
                            current: liveTVVisibleLimit,
                            total: count
                        )
                    }
                    .font(.siloBody.weight(.semibold))
                    .foregroundStyle(KyroTheme.accentInk)
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
            } else {
                liveTVEmptyOrStatus
            }
        }
    }

    @ViewBuilder
    private var liveTVEmptyOrStatus: some View {
        switch coordinator.liveTVState.phase {
        case .debouncing, .loading:
            HStack(spacing: 10) {
                ProgressView().tint(KyroTheme.accentInk)
                Text("Searching Live TV…").font(.siloBody).foregroundStyle(Color.siloSecondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, SiloTheme.smallPadding)
        case .failed, .partialFailure:
            sourceMessage(coordinator.liveTVState.message ?? "Live TV search failed.",
                          symbol: "exclamationmark.triangle", retry: coordinator.retryLiveTV)
        case .unavailable:
            sourceMessage(coordinator.liveTVState.message ?? "Live TV is unavailable.",
                          symbol: "dot.radiowaves.left.and.right")
        case .loaded:
            Text("No Live TV results")
                .font(.siloBody)
                .foregroundStyle(Color.siloSecondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, SiloTheme.smallPadding)
        case .idle:
            EmptyView()
        }
    }

    private func sectionHeader(title: String, count: Int, showsSeeAll: Bool,
                               seeAll: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.siloHeadline)
                .foregroundStyle(Color.siloOnSurface)
            if count > 0 {
                Text("\(count)")
                    .font(.siloCaption)
                    .foregroundStyle(Color.siloSecondaryText)
            }
            Spacer(minLength: 8)
            if showsSeeAll {
                Button("See All", action: seeAll)
                    .font(.siloBody.weight(.semibold))
                    .foregroundStyle(KyroTheme.accentInk)
                    .accessibilityHint("Show all \(title) search results")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sourceMessage(_ message: String, symbol: String,
                               retry: (() -> Void)? = nil) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(Color.siloSecondaryText)
            Text(message)
                .font(.siloBody)
                .foregroundStyle(Color.siloSecondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let retry {
                Button("Retry", action: retry)
                    .font(.siloBody.weight(.semibold))
                    .foregroundStyle(KyroTheme.accentInk)
            }
        }
        .padding(.vertical, SiloTheme.smallPadding)
    }

    private func liveTVResultRow(_ result: UnifiedLiveTVSearchResult) -> some View {
        Button {
            openLiveTVResult(result)
        } label: {
            HStack(spacing: 12) {
                if let logoURL = result.logoURL {
                    AsyncImageView(url: logoURL.absoluteString,
                                   targetSize: CGSize(width: 56, height: 42),
                                   contentMode: .fit, placeholderStyle: .surface,
                                   placeholderSymbol: "tv")
                        .frame(width: 56, height: 42)
                } else {
                    Image(systemName: "tv")
                        .font(.title3)
                        .foregroundStyle(KyroTheme.accentInk)
                        .frame(width: 56, height: 42)
                        .background(Color.siloSurfaceElevated, in: RoundedRectangle(cornerRadius: 8))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.name)
                        .font(.siloBody.weight(.semibold))
                        .foregroundStyle(Color.siloOnSurface)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(result.category.isEmpty ? "Uncategorized" : result.category)
                            .font(.siloCaption)
                            .foregroundStyle(Color.siloSecondaryText)
                            .lineLimit(1)
                        Text("LIVE TV")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(KyroTheme.accentInk)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(KyroTheme.accentInk.opacity(0.12), in: Capsule())
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "play.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(KyroTheme.accentInk)
            }
            .padding(.horizontal, SiloTheme.smallPadding)
            .padding(.vertical, 8)
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .background(Color.siloSurfaceElevated.opacity(0.45),
                        in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play Live TV channel \(result.name), \(result.category)")
    }

    private func openLiveTVResult(_ result: UnifiedLiveTVSearchResult) {
        Task { @MainActor in
            guard let channel = await coordinator.resolveChannel(for: result),
                  liveTVService.canPlay(channel) else {
                await coordinator.catalogDidChange()
                return
            }
            #if os(iOS)
            if KyroUnifiedNavigation.isActive {
                liveTVService.choose(channel, from: .shell)
            } else {
                // Classic navigation owns its Live TV player cover on the list presenter.
                // Selecting first is safe: the pushed Live TV surface observes the shared presentation.
                liveTVService.choose(channel, from: .list)
                KyroLiveTVEntry.open(router: router)
            }
            #else
            liveTVService.choose(channel, from: .list)
            KyroLiveTVEntry.open(router: router)
            #endif
        }
    }

    /// A new search with nothing to show yet: reuse the existing catalog grid's loading skeleton.
    @ViewBuilder
    private var searchLoading: some View {
        #if os(tvOS)
        HStack {
            Spacer()
            ProgressView().tint(.siloOnSurface).padding()
            Spacer()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Searching")
        #else
        CatalogGrid(items: [], isLoading: true, hasMore: false, onItemTap: { _ in }, onLoadMore: {})
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Searching")
        #endif
    }

    /// Matching actors, directors, and other credited people. Each opens the person's page.
    private var peopleSection: some View {
        let people = viewModel.people.map(CastMember.init(searchResult:))
        let openPerson: (String) -> Void = { router.navigate(to: .personDetail(personId: $0)) }
        #if os(tvOS)
        return VStack(alignment: .leading, spacing: TVDetailLayout.sectionHeaderSpacing) {
            TVSectionHeader(title: "People")
            TVDetailCastRail(cast: people, onTap: openPerson)
        }
        #else
        return VStack(alignment: .leading, spacing: 14) {
            PhoneSectionHeader(title: "People")
            PhoneCastRail(cast: people, onTap: openPerson)
                .padding(.horizontal, -SiloTheme.padding)
        }
        #endif
    }

    private func titleResults(items: [BrowseItem], showsPagination: Bool) -> some View {
        VStack(alignment: .leading, spacing: SiloTheme.padding) {
            Text("\(viewModel.total) result\(viewModel.total == 1 ? "" : "s")")
                .font(.siloCaption)
                .foregroundColor(.siloSecondaryText)
#if os(tvOS)
            TVCatalogGrid(
                items: items,
                isLoading: showsPagination && viewModel.isSearching,
                hasMore: showsPagination && viewModel.hasMore,
                onItemTap: { router.navigate(to: .itemDetail(browseItem: $0)) },
                onNearEnd: { _ in
                    guard showsPagination else { return }
                    Task { await coordinator.loadMoreSilo() }
                },
                columnCount: 6,
                cardWidth: 220,
                prefersDefaultFocusOnFirstItem: true
            )
#else
            CatalogGrid(
                items: items,
                isLoading: showsPagination && viewModel.isSearching,
                hasMore: showsPagination && viewModel.hasMore,
                onItemTap: { router.navigate(to: .itemDetail(browseItem: $0)) },
                onLoadMore: {
                    guard showsPagination else { return }
                    Task { await coordinator.loadMoreSilo() }
                }
            )
#endif
        }
    }

#if os(tvOS)
    private var tvSearchSafeHorizontalPadding: CGFloat { 110 }
    private var tvSearchContentWidth: CGFloat { 1600 }
    private var tvFilterWidth: CGFloat { 760 }
#endif

    #if os(iOS)
    @MainActor
    private func focusSearchField() async {
        await Task.yield()
        isSearchFieldFocused = true
    }
    #endif
}

private extension CastMember {
    /// A people search result shown on a cast rail: no role, just the person.
    init(searchResult person: Person) {
        self.init(
            name: person.name,
            character: nil,
            order: nil,
            personId: person.id,
            tmdbId: person.tmdbId,
            tvdbId: person.tvdbId,
            imdbId: person.imdbId,
            photoUrl: person.photoUrl,
            photoThumbhash: person.photoThumbhash
        )
    }
}
