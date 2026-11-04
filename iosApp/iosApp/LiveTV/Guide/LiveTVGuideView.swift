import SwiftUI

/// The full Live TV guide: a fixed channel column beside a horizontally scrolling time grid.
///
/// One two-axis scroll view hosts lazily built rows under a pinned time header. The channel
/// column and the titles of programmes already under way stay at the leading edge through
/// `visualEffect` offsets, so scrolling never writes view state.
struct LiveTVGuideView: View {
    @Bindable var service: LiveTVService
    #if os(iOS)
    /// Kyro's Live TV navigation around the grid, when Live TV provides it.
    var navigation: KyroLiveTVNavigationRoute?
    #endif
    @Environment(\.timeZone) private var timeZone
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedCategory: String?
    @State private var isShowingCategoryPicker = false
    @State private var categoryPickerPosition: LiveTVGuideCategoryPickerID?
    @State private var categoryPickerState = LiveTVGuideCategoryPickerState()
    @State private var favoritesOnly = false
    @State private var rows: [LiveTVChannel] = []
    @State private var searchText = ""
    @State private var isSearchPresented = false
    @State private var isSearchPending = false
    @State private var searchGeneration = 0
    @State private var searchModel = LiveTVChannelSearchModel()
    @State private var browsingRestoration = LiveTVGuideBrowsingRestoration()
    @State private var restoredContextProviderID: UUID?
    @SceneStorage("liveTV.guideBrowsingContext.v1") private var savedBrowsingContext = ""
    @State private var timeline = LiveTVGuideTimeline(now: .now, timeZone: .current)
    @State private var cells = LiveTVGuideCellCache()
    @State private var position = ScrollPosition(idType: String.self)
    @State private var span = LiveTVGuideVisibleSpan(offsetX: 0, viewportWidth: 430, bucketWidth: 240)
    @State private var hasScrolledToNow = false
    @State private var detail: LiveTVGuideDetail?
    @State private var pendingTune: LiveTVChannel?

    var body: some View {
        content
            // Inside the navigation too, so Classic's tab shows the page rather than its own black.
            .liveTVPageBackground()
            #if os(iOS)
            // Around the grid only: the title, toolbar and search below stay on the page,
            // where they reach the navigation bar in every navigation style.
            .kyroLiveTVNavigation(navigation, active: .guide)
            #endif
            .liveTVPageBackground()
            .tint(LiveTVAccent.primaryText)
            .navigationTitle(selectedCategory ?? (favoritesOnly ? "Favorites" : "TV Guide"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .searchable(text: $searchText, isPresented: $isSearchPresented,
                        placement: .navigationBarDrawer(displayMode: .always), prompt: "Search channels")
            .fullScreenCover(item: Binding(
                get: { service.presentation.channel(for: .guide) },
                set: { if $0 == nil { service.presentation.coverDismissed(from: .guide) } }
            )) { channel in
                LiveTVPlayerView(channel: channel, channels: service.channels, session: service.playerSession,
                                 service: service)
            }
            .sheet(item: $detail, onDismiss: tunePending) { detail in
                LiveTVProgramDetailView(detail: detail) {
                    pendingTune = detail.channel
                    self.detail = nil
                }
            }
            .sheet(isPresented: $isShowingCategoryPicker, onDismiss: rememberCategoryPickerPosition) {
                categoryPicker
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .onAppear {
                service.presentation.surfaceAppeared(.guide)
                restoreBrowsingContext(for: service.selectedProviderID)
                if timeline.timeZone != timeZone { rebuildTimeline(at: .now) }
                rebuildRows()
            }
            .onChange(of: selectedCategory) { rebuildRows() }
            .onChange(of: favoritesOnly) { rebuildRows() }
            .onChange(of: service.favoriteChannelIDs) { if favoritesOnly || !searchText.isEmpty { rebuildRows() } }
            .onChange(of: service.channelCatalogRevision) {
                reconcileBrowsingContext()
                rebuildRows()
            }
            .onChange(of: searchText) { updateSearch() }
            .onChange(of: service.selectedProviderID) { _, providerID in
                saveBrowsingContext(for: restoredContextProviderID)
                searchGeneration += 1
                searchModel.cancel()
                searchText = ""
                isSearchPending = false
                rows = []
                restoreBrowsingContext(for: providerID)
                guard let providerID else {
                    categoryPickerPosition = nil
                    return
                }
                categoryPickerPosition = categoryPickerState.target(
                    providerID: providerID, selectedCategory: selectedCategory, categories: service.categories)
            }
            .onChange(of: service.categories) { _, categories in
                reconcileBrowsingContext()
                guard let providerID = service.selectedProviderID else { return }
                categoryPickerState.reconcile(providerID: providerID, categories: categories)
                if isShowingCategoryPicker {
                    categoryPickerPosition = categoryPickerState.target(
                        providerID: providerID, selectedCategory: selectedCategory, categories: categories)
                }
            }
            .onChange(of: timeZone) { rebuildTimeline(at: .now) }
            .onChange(of: scenePhase) { _, phase in if phase == .background { saveBrowsingContext() } }
            .onDisappear {
                saveBrowsingContext()
                searchGeneration += 1
                searchModel.cancel()
                isSearchPending = false
                service.presentation.surfaceDisappeared(.guide)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch LiveTVGuideContentState.resolve(hasProviders: !service.providers.isEmpty, isLoading: service.isLoading,
                                               errorMessage: service.errorMessage, channelCount: service.channels.count,
                                               visibleCount: rows.count) {
        case .setup:
            ContentUnavailableView("Set Up Live TV", systemImage: "antenna.radiowaves.left.and.right",
                                   description: Text("Add a playlist in Live TV settings to see the guide."))
        case .loading:
            ProgressView("Loading channels…")
                .foregroundStyle(Color.siloSecondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn’t Load Channels", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await service.refreshSelectedProvider() } }
            }
        case .noChannels:
            ContentUnavailableView("No Channels", systemImage: "tv",
                                   description: Text("Refresh the playlist or check its settings."))
        case .noMatches:
            ZStack {
                // Keep the scroll view alive behind empty/search states. This preserves both
                // horizontal time and vertical channel positions when the query is cleared.
                grid.hidden().accessibilityHidden(true).allowsHitTesting(false)
                if isSearchPending {
                    ProgressView("Searching channels…")
                        .foregroundStyle(Color.siloSecondaryText)
                } else if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView {
                        Label("No Channels Found", systemImage: "magnifyingglass")
                    } description: {
                        Text("Try a different name or category, or clear your search.")
                    } actions: {
                        Button("Clear Search") { clearSearch() }
                    }
                } else {
                    ContentUnavailableView {
                        Label(favoritesOnly ? "No Favorites Here" : "No Channels", systemImage: favoritesOnly ? "star" : "tv")
                    } description: {
                        Text(favoritesOnly ? "Star channels in Live TV to see them in the guide."
                                           : "This category has no channels.")
                    } actions: {
                        Button("Show All Channels") {
                            favoritesOnly = false
                            selectedCategory = nil
                        }
                    }
                }
            }
        case .ready:
            VStack(spacing: 0) {
                if let banner = LiveTVGuideContentState.banner(errorMessage: service.errorMessage,
                                                               catalogNotice: service.catalogNotice,
                                                               guideMessage: service.guideMessage,
                                                               isGuideStale: service.isGuideStale,
                                                               isGuideLoading: service.isGuideLoading) {
                    let icon = service.errorMessage == nil && service.catalogNotice != nil
                        ? "info.circle" : "exclamationmark.circle"
                    Label(banner, systemImage: icon)
                        .font(.footnote)
                        .foregroundStyle(Color.siloSecondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(LiveTVSurface.row)
                }
                grid
            }
        }
    }

    private var grid: some View {
        TimelineView(.everyMinute) { context in
            let now = context.date
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(rows) { channel in
                            LiveTVGuideRow(
                                channel: channel,
                                cells: cells.cells(for: channel, revision: service.guideRevision,
                                                   isGuideStale: service.isGuideStale, timeline: timeline,
                                                   channelRevision: service.guideChannelRevision(for: channel)) {
                                    service.guidePrograms(for: channel, overlapping: timeline.interval)
                                },
                                timeline: timeline,
                                span: span,
                                now: now,
                                isFavorite: service.isFavorite(channel),
                                isGuideLoading: service.isGuideLoading || service.isGuideChannelLoading(channel),
                                onTuneChannel: { tune(channel) },
                                onToggleFavorite: { service.toggleFavorite(channel) },
                                onSelect: { select($0, on: channel, at: now) }
                            )
                        }
                    } header: {
                        LiveTVGuideTimeHeader(timeline: timeline, now: now)
                    }
                }
            }
            .scrollPosition($position)
            .scrollIndicators(.hidden)
            // Only whole-hour crossings change `span`, so scrolling itself does not update view state.
            .onScrollGeometryChange(for: LiveTVGuideVisibleSpan.self) { [bucketWidth = timeline.pointsPerMinute * 60] geometry in
                LiveTVGuideVisibleSpan(offsetX: geometry.contentOffset.x, viewportWidth: geometry.containerSize.width,
                                       bucketWidth: bucketWidth)
            } action: { _, newValue in
                span = newValue
            }
            .onAppear {
                guard !hasScrolledToNow else { return }
                hasScrolledToNow = true
                if browsingRestoration.pendingContext?.offsetX != nil || browsingRestoration.pendingContext?.channelID != nil { return }
                position.scrollTo(x: timeline.scrollOffset(showing: now))
            }
            .onChange(of: now) {
                if timeline.needsRebuild(at: now) { rebuildTimeline(at: now) }
            }
            .overlay {
                if isSearchPending {
                    ProgressView("Searching channels…")
                        .foregroundStyle(Color.siloSecondaryText)
                        .padding(16)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                        .accessibilityLabel("Searching channels")
                }
            }
            .allowsHitTesting(!isSearchPending)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        #if os(iOS)
        if LiveTVNavigationPolicy.showsGuideBack(isUnifiedShell: KyroUnifiedNavigation.isActive) {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    navigation?.navigate(.home)
                } label: {
                    Label("Live TV Home", systemImage: "chevron.left")
                }
                .accessibilityHint("Returns to Live TV Home")
            }
        }
        #endif
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button("Now") {
                withAnimation(.easeInOut(duration: 0.3)) {
                    position.scrollTo(x: timeline.scrollOffset(showing: .now))
                }
            }
            .accessibilityHint("Scrolls the guide to the current time")
            Button {
                isSearchPresented = true
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .accessibilityLabel("Search channels")
            Button {
                favoritesOnly.toggle()
            } label: {
                Image(systemName: favoritesOnly ? "star.fill" : "star")
            }
            .accessibilityLabel(favoritesOnly ? "Show all channels" : "Show favorites only")
            if !service.categories.isEmpty {
                Button {
                    guard let providerID = service.selectedProviderID else { return }
                    categoryPickerPosition = categoryPickerState.target(
                        providerID: providerID, selectedCategory: selectedCategory, categories: service.categories)
                    isShowingCategoryPicker = true
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle\(selectedCategory == nil ? "" : ".fill")")
                }
                .accessibilityLabel("Filter by category")
                .accessibilityHint("Choose which channel category the guide shows")
            }
        }
    }

    private var categoryPicker: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    categoryPickerRow(id: .allCategories, title: "All Categories", isSelected: selectedCategory == nil) {
                        selectedCategory = nil
                        isShowingCategoryPicker = false
                    }
                    ForEach(service.categories, id: \.self) { category in
                        categoryPickerRow(id: .category(category), title: category,
                                          isSelected: selectedCategory == category) {
                            selectedCategory = category
                            isShowingCategoryPicker = false
                        }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollPosition(id: $categoryPickerPosition, anchor: .top)
            .scrollIndicators(.hidden)
            .accessibilityLabel("Live TV categories")
            .navigationTitle("Filter by category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { isShowingCategoryPicker = false }
                }
            }
        }
        .onAppear {
            guard let providerID = service.selectedProviderID else { return }
            categoryPickerPosition = categoryPickerState.target(
                providerID: providerID, selectedCategory: selectedCategory, categories: service.categories)
        }
    }

    private func categoryPickerRow(id: LiveTVGuideCategoryPickerID, title: String, isSelected: Bool,
                                   action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(title)
                    .foregroundStyle(Color.siloOnSurface)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(LiveTVAccent.primaryText)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 20)
            .frame(minHeight: 52)
        }
        .buttonStyle(.plain)
        .id(id)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func rememberCategoryPickerPosition() {
        guard let providerID = service.selectedProviderID else { return }
        categoryPickerState.remember(categoryPickerPosition, providerID: providerID, categories: service.categories)
    }

    private func select(_ program: EPGProgram, on channel: LiveTVChannel, at now: Date) {
        switch LiveTVGuideAction(program, at: now) {
        case .tune: tune(channel)
        case .showDetails: detail = LiveTVGuideDetail(channel: channel, program: program)
        }
    }

    private func tunePending() {
        guard let channel = pendingTune else { return }
        pendingTune = nil
        tune(channel)
    }

    private func tune(_ channel: LiveTVChannel) {
        service.choose(channel, from: .guide)
    }

    private func rebuildRows() {
        if let selectedCategory, let providerID = service.selectedProviderID, service.hasCatalog(for: providerID),
           !service.categories.contains(selectedCategory) { self.selectedCategory = nil }
        updateSearch()
    }

    private func updateSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        searchGeneration += 1
        let generation = searchGeneration
        let providerID = service.selectedProviderID
        let catalogRevision = service.channelCatalogRevision
        let category = selectedCategory
        let favoriteFilter = favoritesOnly
        let favoriteIDs = service.favoriteChannelIDs
        // Release the previous filtered rows while the detached search runs. The hidden guide
        // scroll view remains mounted so its two-axis ScrollPosition and current-time offset live on.
        rows = []
        isSearchPending = true
        searchModel.update(channels: service.channels, query: query, category: category,
                           favoritesOnly: favoriteFilter, favoriteIDs: favoriteIDs, includeGroups: false)
        Task { @MainActor in
            await searchModel.waitForCurrentSearch()
            guard generation == searchGeneration, query == searchText.trimmingCharacters(in: .whitespacesAndNewlines),
                  let providerID, providerID == service.selectedProviderID,
                  catalogRevision == service.channelCatalogRevision,
                  category == selectedCategory, favoriteFilter == favoritesOnly,
                  favoriteIDs == service.favoriteChannelIDs else { return }
            rows = searchModel.matches
            isSearchPending = false
            restoreGuidePositionIfNeeded(providerID: providerID, context: browsingRestoration.pendingContext)
        }
    }

    private func clearSearch() {
        searchText = ""
        isSearchPresented = false
    }

    private func restoreBrowsingContext(for providerID: UUID?) {
        guard let providerID, restoredContextProviderID != providerID else { return }
        restoredContextProviderID = providerID
        selectedCategory = nil
        favoritesOnly = false
        searchText = ""
        isSearchPresented = false
        position = ScrollPosition(idType: String.self)
        hasScrolledToNow = false
        let context = LiveTVBrowsingContextCollection.decoded(savedBrowsingContext)?.context(for: providerID)
        browsingRestoration.begin(context: context, providerID: providerID)
        if let context = browsingRestoration.pendingContext {
            selectedCategory = context.category
            favoritesOnly = context.favoritesOnly
            searchText = context.searchQuery
        }
        reconcileBrowsingContext()
    }

    private func reconcileBrowsingContext() {
        guard let providerID = service.selectedProviderID,
              let valid = browsingRestoration.pendingContext?.validatedWhenReady(
                  selectedProviderID: providerID, catalogIsLoaded: service.hasCatalog(for: providerID),
                  categories: service.categories, channels: service.channels) else { return }
        browsingRestoration.updatePendingContext(valid)
        if selectedCategory != valid.category { selectedCategory = valid.category }
    }

    private func restoreGuidePositionIfNeeded(providerID: UUID, context: LiveTVBrowsingContext?) {
        guard service.hasCatalog(for: providerID), let context, context.providerID == providerID,
              browsingRestoration.pendingContext == context else { return }
        if let channelID = context.channelID, rows.contains(where: { $0.id == channelID }) {
            position.scrollTo(id: channelID, anchor: .top)
            if let offsetX = context.offsetX { position.scrollTo(x: offsetX) }
        } else if let offsetX = context.offsetX, let offsetY = context.offsetY {
            position.scrollTo(x: offsetX, y: offsetY)
        } else {
            position.scrollTo(x: timeline.scrollOffset(showing: .now))
        }
        browsingRestoration.complete(context: context)
    }

    private func saveBrowsingContext() {
        saveBrowsingContext(for: service.selectedProviderID)
    }

    private func saveBrowsingContext(for providerID: UUID?) {
        guard let providerID else { return }
        let point = position.point
        let current = LiveTVBrowsingContext(providerID: providerID, category: selectedCategory,
                                            favoritesOnly: favoritesOnly, searchQuery: searchText,
                                            channelID: position.viewID(type: String.self),
                                            offsetX: point.map { Double($0.x) }, offsetY: point.map { Double($0.y) })
        guard let context = browsingRestoration.contextToSave(providerID: providerID,
                                                               restoredProviderID: restoredContextProviderID,
                                                               current: current) else { return }
        let collection = LiveTVBrowsingContextCollection.decoded(savedBrowsingContext) ?? LiveTVBrowsingContextCollection()
        if let encoded = collection.replacing(context).encoded() { savedBrowsingContext = encoded }
    }

    private func rebuildTimeline(at now: Date) {
        timeline = LiveTVGuideTimeline(now: now, timeZone: timeZone)
        position.scrollTo(x: timeline.scrollOffset(showing: now))
    }
}

/// Programme cells per channel for the current guide revision and window, built once per row.
/// Not observed: it only memoizes values derived from observed service state.
@MainActor
final class LiveTVGuideCellCache {
    /// A portrait iPhone 16 Plus shows roughly thirteen 64-point rows. Keeping seven
    /// viewportfuls preserves nearby backtracking without retaining every row visited.
    static let capacity = 96

    private struct Key: Equatable {
        let revision: Int
        let isGuideStale: Bool
        let timeline: LiveTVGuideTimeline
    }

    private struct Entry {
        let cells: [LiveTVGuideCell]
        let channelRevision: Int
    }

    private var key: Key?
    private var storage: [String: Entry] = [:]
    /// Most-recently-used channel IDs first. The cache is intentionally small, so an array keeps
    /// bookkeeping cheaper and more predictable than a linked-list allocation per row.
    private var recency: [String] = []

    private(set) var hitCount = 0
    private(set) var missCount = 0
    private(set) var evictionCount = 0
    private(set) var targetedInvalidationCount = 0
    private(set) var globalInvalidationCount = 0

    var entryCount: Int { storage.count }

    func cells(for channel: LiveTVChannel, revision: Int, isGuideStale: Bool, timeline: LiveTVGuideTimeline,
               channelRevision: Int = 0,
               programs: () -> [EPGProgram]) -> [LiveTVGuideCell] {
        let key = Key(revision: revision, isGuideStale: isGuideStale, timeline: timeline)
        if key != self.key {
            if self.key != nil { globalInvalidationCount += 1 }
            self.key = key
            storage.removeAll(keepingCapacity: true)
            recency.removeAll(keepingCapacity: true)
        }
        if let cached = storage[channel.id], cached.channelRevision == channelRevision {
            hitCount += 1
            touch(channel.id)
            return cached.cells
        }
        if storage[channel.id] != nil { targetedInvalidationCount += 1 }
        missCount += 1
        let built = LiveTVGuideCell.cells(for: programs(), in: timeline)
        storage[channel.id] = Entry(cells: built, channelRevision: channelRevision)
        touch(channel.id)
        if storage.count > Self.capacity, let evicted = recency.popLast() {
            storage.removeValue(forKey: evicted)
            evictionCount += 1
        }
        return built
    }

    private func touch(_ channelID: String) {
        if let index = recency.firstIndex(of: channelID) { recency.remove(at: index) }
        recency.insert(channelID, at: 0)
    }
}

struct LiveTVGuideDetail: Identifiable {
    let channel: LiveTVChannel
    let program: EPGProgram
    var id: String { "\(channel.id)|\(program.id)" }
}

private enum LiveTVGuideMetrics {
    static let channelColumnWidth: CGFloat = 116
    static let rowHeight: CGFloat = 64
    static let headerHeight: CGFloat = 36
}

private extension View {
    /// Keeps the view at the scroll view's leading edge plus `inset`, moving at most `maximum`.
    func pinnedToScrollLeading(inset: CGFloat = 0, maximum: CGFloat = .greatestFiniteMagnitude) -> some View {
        visualEffect { content, proxy in
            content.offset(x: min(max(0, inset - proxy.frame(in: .scrollView).minX), max(0, maximum)))
        }
    }
}

private struct LiveTVGuideTimeHeader: View {
    let timeline: LiveTVGuideTimeline
    let now: Date

    var body: some View {
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                ForEach(timeline.ticks) { tick in
                    let x = timeline.x(for: tick.date)
                    Rectangle()
                        .fill(Color.siloSecondaryText.opacity(tick.isHour ? 0.35 : 0.18))
                        .frame(width: 1, height: tick.isHour ? 12 : 7)
                        .offset(x: x, y: LiveTVGuideMetrics.headerHeight - (tick.isHour ? 12 : 7))
                    Text(tick.date, format: .dateTime.hour().minute())
                        .font(.caption.weight(tick.isHour ? .semibold : .regular))
                        .monospacedDigit()
                        .foregroundStyle(tick.isHour ? Color.siloOnSurface : Color.siloSecondaryText)
                        .fixedSize()
                        .offset(x: x + 5, y: 9)
                }
                Capsule()
                    .fill(LiveTVAccent.primaryText)
                    .frame(width: 8, height: 8)
                    .offset(x: timeline.x(for: now) - 4, y: LiveTVGuideMetrics.headerHeight - 8)
                    .accessibilityHidden(true)
            }
            .frame(width: timeline.width, height: LiveTVGuideMetrics.headerHeight, alignment: .topLeading)
            .padding(.leading, LiveTVGuideMetrics.channelColumnWidth)

            Text(now, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                .font(.caption.weight(.semibold))
                .foregroundStyle(LiveTVAccent.primaryText)
                .frame(width: LiveTVGuideMetrics.channelColumnWidth, height: LiveTVGuideMetrics.headerHeight)
                .background(LiveTVSurface.canvas)
                .pinnedToScrollLeading()
                .zIndex(1)
        }
        .background(LiveTVSurface.canvas)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Timeline")
    }
}

private struct LiveTVGuideRow: View {
    let channel: LiveTVChannel
    let cells: [LiveTVGuideCell]
    let timeline: LiveTVGuideTimeline
    let span: LiveTVGuideVisibleSpan
    let now: Date
    let isFavorite: Bool
    let isGuideLoading: Bool
    let onTuneChannel: () -> Void
    let onToggleFavorite: () -> Void
    let onSelect: (EPGProgram) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                if cells.isEmpty {
                    Text(isGuideLoading ? "Loading guide…" : "No guide information")
                        .font(.footnote)
                        .foregroundStyle(Color.siloSecondaryText)
                        .padding(.horizontal, 12)
                        .frame(height: LiveTVGuideMetrics.rowHeight)
                        .pinnedToScrollLeading(inset: LiveTVGuideMetrics.channelColumnWidth)
                } else {
                    ForEach(cells.filter(span.renders)) { cell in
                        LiveTVGuideProgramCell(cell: cell, now: now, pinsTitle: span.pinsTitle(of: cell)) {
                            onSelect(cell.program)
                        }
                        .frame(width: cell.width, height: LiveTVGuideMetrics.rowHeight)
                        .offset(x: cell.x)
                    }
                }
                Rectangle()
                    .fill(LiveTVAccent.primaryText)
                    .frame(width: 2, height: LiveTVGuideMetrics.rowHeight)
                    .offset(x: timeline.x(for: now) - 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .frame(width: timeline.width, height: LiveTVGuideMetrics.rowHeight, alignment: .topLeading)
            .padding(.leading, LiveTVGuideMetrics.channelColumnWidth)

            channelCell
                .pinnedToScrollLeading()
                .zIndex(1)
        }
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
    }

    private var channelCell: some View {
        Button(action: onTuneChannel) {
            HStack(spacing: 8) {
                LiveTVChannelLogo(channel: channel, size: CGSize(width: 36, height: 30))
                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.siloOnSurface)
                        .lineLimit(2)
                    if isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(LiveTVAccent.ember)
                            .accessibilityHidden(true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(width: LiveTVGuideMetrics.channelColumnWidth, height: LiveTVGuideMetrics.rowHeight)
            .background(LiveTVSurface.row)
            .overlay(alignment: .trailing) { Divider() }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(action: onTuneChannel) { Label("Watch", systemImage: "play.fill") }
            Button(action: onToggleFavorite) {
                Label(isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: isFavorite ? "star.slash" : "star")
            }
        }
        .accessibilityLabel("Watch \(channel.name)")
        .accessibilityHint(isFavorite ? "Favorite channel" : "")
    }
}

private struct LiveTVGuideProgramCell: View {
    let cell: LiveTVGuideCell
    let now: Date
    /// Only a programme that can straddle the viewport's leading edge needs its title to slide;
    /// every other cell skips the per-frame scroll-geometry effect.
    let pinsTitle: Bool
    let action: () -> Void

    private var state: LiveTVGuideProgramState { LiveTVGuideProgramState(cell.program, at: now) }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(background)
                if state == .current {
                    progress
                }
                if cell.width >= 28 {
                    titleBlock
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                if state == .current {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(LiveTVAccent.primaryText.opacity(0.7), lineWidth: 1)
                }
            }
            .padding(2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(state == .current ? "Plays this channel" : "Shows program details")
    }

    @ViewBuilder
    private var titleBlock: some View {
        if pinsTitle {
            titleText.pinnedToScrollLeading(inset: LiveTVGuideMetrics.channelColumnWidth, maximum: cell.width - 96)
        } else {
            titleText
        }
    }

    private var titleText: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(cell.program.title)
                .font(.subheadline.weight(state == .current ? .semibold : .regular))
                .foregroundStyle(state == .past ? Color.siloSecondaryText : Color.siloOnSurface)
            Text("\(cell.program.start, format: .dateTime.hour().minute()) – \(cell.program.end, format: .dateTime.hour().minute())")
        }
        .font(.caption2)
        .monospacedDigit()
        .foregroundStyle(Color.siloSecondaryText)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var background: Color {
        switch state {
        case .past: LiveTVSurface.pastProgram
        case .current: LiveTVAccent.primary.opacity(0.34)
        case .upcoming: LiveTVSurface.upcomingProgram
        }
    }

    private var progress: some View {
        GeometryReader { proxy in
            let total = cell.program.end.timeIntervalSince(cell.program.start)
            let elapsed = now.timeIntervalSince(cell.program.start)
            Capsule()
                .fill(LiveTVAccent.primaryText)
                .frame(width: proxy.size.width * CGFloat(min(max(elapsed / max(total, 1), 0), 1)), height: 3)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 3)
        .allowsHitTesting(false)
    }

    private var accessibilityText: String {
        let status = switch state {
        case .past: "Ended"
        case .current: "On now"
        case .upcoming: "Upcoming"
        }
        let start = cell.program.start.formatted(date: .omitted, time: .shortened)
        let end = cell.program.end.formatted(date: .omitted, time: .shortened)
        return "\(cell.program.title), \(start) to \(end), \(status)"
    }
}

/// Details for a programme that is not airing. Watching is an explicit choice, never automatic.
struct LiveTVProgramDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let detail: LiveTVGuideDetail
    let onWatch: () -> Void

    var body: some View {
        NavigationStack {
            TimelineView(.everyMinute) { context in
                let state = LiveTVGuideProgramState(detail.program, at: context.date)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 10) {
                            LiveTVChannelLogo(channel: detail.channel, size: CGSize(width: 44, height: 36))
                            Text(detail.channel.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.siloSecondaryText)
                        }
                        Text(detail.program.title)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(Color.siloOnSurface)
                        if let subtitle = detail.program.subtitle {
                            Text(subtitle).font(.headline).foregroundStyle(Color.siloOnSurface)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(detail.program.start, format: .dateTime.weekday(.wide).day().month(.wide))
                            Text("\(detail.program.start, format: .dateTime.hour().minute()) – \(detail.program.end, format: .dateTime.hour().minute())")
                            Text(statusText(state, now: context.date))
                                .foregroundStyle(LiveTVAccent.primaryText)
                        }
                        .font(.subheadline)
                        .foregroundStyle(Color.siloSecondaryText)
                        let tags = [detail.program.episode, detail.program.category].compactMap { $0 }
                        if !tags.isEmpty {
                            HStack(spacing: 8) {
                                ForEach(tags, id: \.self) { tag in
                                    Text(tag)
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Color.siloSurfaceElevated, in: Capsule())
                                }
                            }
                        }
                        if let summary = detail.program.summary {
                            Text(summary).font(.body).foregroundStyle(Color.siloOnSurface)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                }
                .safeAreaInset(edge: .bottom) {
                    Button(action: onWatch) {
                        Label(state == .current ? "Watch Now" : "Watch \(detail.channel.name) Now", systemImage: "play.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(LiveTVAccent.primary)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                }
            }
            .background(Color.siloBackground)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .tint(LiveTVAccent.primaryText)
    }

    private func statusText(_ state: LiveTVGuideProgramState, now: Date) -> String {
        switch state {
        case .past: return "Ended"
        case .current: return "On now"
        case .upcoming:
            let minutes = Int((detail.program.start.timeIntervalSince(now) / 60).rounded(.up))
            if minutes < 60 { return "Starts in \(minutes) min" }
            return "Starts \(detail.program.start.formatted(.relative(presentation: .named)))"
        }
    }
}
