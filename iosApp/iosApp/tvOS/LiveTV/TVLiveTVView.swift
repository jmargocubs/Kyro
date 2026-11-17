#if os(tvOS)
import SwiftUI

enum TVLiveTVSection: String, CaseIterable, Hashable, Identifiable {
    case channels
    case categories
    case favorites

    var id: Self { self }

    var title: String {
        switch self {
        case .channels: "All Channels"
        case .categories: "Categories"
        case .favorites: "Favorites"
        }
    }

    var symbol: String {
        switch self {
        case .channels: "rectangle.stack"
        case .categories: "square.grid.2x2"
        case .favorites: "star.fill"
        }
    }
}

/// Pure focus-restoration state used by the TV guide and its focused tests.
struct TVLiveTVGuideNavigationState: Equatable {
    private(set) var focusedChannelID: String?

    mutating func focus(channelID: String) { focusedChannelID = channelID }

    mutating func reconcile(visibleChannelIDs: [String]) {
        guard let focusedChannelID else { return }
        if !visibleChannelIDs.contains(focusedChannelID) {
            self.focusedChannelID = visibleChannelIDs.first
        }
    }
}

/// Kyro's native Apple TV Live TV root. Networking, secure provider storage,
/// catalogs, EPG matching, favorites, and the single playback session all
/// remain owned by `LiveTVService`; this view only supplies a TV focus graph.
struct TVLiveTVRootView: View {
    @Bindable var service: LiveTVService
    let focusRequest: Int
    let isTopMenuFocused: Bool
    let onTopMenuFocusRequest: () -> Void

    @State private var section: TVLiveTVSection = .channels
    @State private var selectedCategory: String?
    @State private var query = ""
    @State private var search = LiveTVChannelSearchModel()
    @State private var showsGuide = false
    @State private var showsProviders = false
    @State private var focusedChannelID: String?
    @FocusState private var focusedControl: FocusTarget?

    fileprivate enum FocusTarget: Hashable {
        case section(TVLiveTVSection)
        case guide
        case providers
        case search
        case category(String)
        case channel(String)
        case favorite(String)
        case retry
    }

    private let columns = Array(
        repeating: GridItem(.flexible(minimum: 250, maximum: 340), spacing: 34),
        count: 5
    )

    var body: some View {
        ZStack {
            TVKyroAmbientBackdrop()

            VStack(alignment: .leading, spacing: 22) {
                header
                controls
                content
            }
            .padding(.horizontal, 72)
            .padding(.top, TVTopMenuLayout.contentTopInset)
            .padding(.bottom, 38)
        }
        .modifier(LiveTVChannelCover(
            service: service,
            presenter: .list,
            isEnabled: !showsGuide && !showsProviders
        ))
        .fullScreenCover(isPresented: $showsGuide) {
            TVLiveTVGuideView(service: service)
        }
        .fullScreenCover(isPresented: $showsProviders) {
            TVLiveTVProviderManagementView(service: service)
        }
        .task(id: service.selectedProviderID) {
            updateSearch()
            await service.prepareSelectedProvider()
            updateSearch()
        }
        .task(id: focusRequest) { claimEntryFocus() }
        .onAppear {
            service.presentation.surfaceAppeared(.list)
            updateSearch()
        }
        .onDisappear {
            search.cancel()
            if !showsGuide && !showsProviders { service.presentation.surfaceDisappeared(.list) }
        }
        .onChange(of: query) { updateSearch() }
        .onChange(of: section) {
            updateSearch()
        }
        .onChange(of: selectedCategory) { updateSearch() }
        .onChange(of: service.favoriteChannelIDs) { updateSearch() }
        .onChange(of: service.channelCatalogRevision) { updateSearch() }
        .onChange(of: service.selectedProviderID) {
            query = ""
            selectedCategory = nil
            updateSearch()
        }
        .onChange(of: focusedControl) { _, target in
            if case .channel(let id) = target { focusedChannelID = id }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Live TV")
                    .font(.system(size: 52, weight: .bold))
                Text(providerSummary)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Color.siloSecondaryText)
            }
            Spacer()
            if service.isLoading || service.isGuideLoading {
                ProgressView(service.isLoading ? "Loading channels…" : "Updating guide…")
                    .font(.system(size: 22, weight: .medium))
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            ForEach(TVLiveTVSection.allCases) { item in
                Button {
                    section = item
                    if item != .categories { selectedCategory = nil }
                } label: {
                    Label(item.title, systemImage: item.symbol)
                }
                .buttonStyle(TVBrowseControlPillStyle(active: section == item))
                .focused($focusedControl, equals: .section(item))
                .onMoveCommand { if $0 == .up { onTopMenuFocusRequest() } }
            }

            Button { showsGuide = true } label: {
                Label("TV Guide", systemImage: "calendar.day.timeline.left")
            }
            .buttonStyle(TVBrowseControlPillStyle())
            .focused($focusedControl, equals: .guide)
            .onMoveCommand { if $0 == .up { onTopMenuFocusRequest() } }

            Button { showsProviders = true } label: {
                Label("Providers", systemImage: "antenna.radiowaves.left.and.right")
            }
            .buttonStyle(TVBrowseControlPillStyle(active: service.providers.isEmpty))
            .focused($focusedControl, equals: .providers)
            .onMoveCommand { if $0 == .up { onTopMenuFocusRequest() } }

            Spacer(minLength: 20)

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                TextField("Search channels", text: $query)
                    .textFieldStyle(.plain)
            }
            .font(.system(size: 24))
            .padding(.horizontal, 20)
            .frame(width: 330, height: 54)
            .background(.ultraThinMaterial, in: Capsule())
            .focused($focusedControl, equals: .search)
            .onMoveCommand { if $0 == .up { onTopMenuFocusRequest() } }
        }
        .focusSection()
    }

    @ViewBuilder
    private var content: some View {
        if service.providers.isEmpty {
            statusPage(
                symbol: "antenna.radiowaves.left.and.right.slash",
                title: "Connect a Live TV provider",
                message: "Add an M3U playlist or Xtream Codes account to browse and watch channels.",
                buttonTitle: "Set Up Provider",
                action: { showsProviders = true }
            )
        } else if service.channels.isEmpty, service.isLoading {
            statusPage(symbol: "arrow.trianglehead.2.clockwise.rotate.90", title: "Loading channels",
                       message: "Kyro is securely connecting to \(service.selectedProvider?.name ?? "your provider").")
        } else if service.channels.isEmpty, let error = service.errorMessage {
            statusPage(symbol: "exclamationmark.triangle.fill", title: "Couldn’t load channels", message: error,
                       buttonTitle: "Retry", action: { Task { await service.refreshSelectedProvider() } })
        } else if service.channels.isEmpty {
            statusPage(symbol: "tv.slash", title: "No channels found",
                       message: "Refresh this provider or review its connection settings.",
                       buttonTitle: "Manage Providers", action: { showsProviders = true })
        } else if section == .categories && selectedCategory == nil {
            categoryGrid
        } else {
            channelGrid
        }
    }

    private var categoryGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 28) {
                categoryButton("All Channels", count: service.channels.count, category: nil)
                ForEach(service.categories, id: \.self) { category in
                    categoryButton(category, count: categoryCounts[category, default: 0], category: category)
                }
            }
            .padding(.vertical, 18)
        }
        .focusSection()
    }

    private func categoryButton(_ title: String, count: Int, category: String?) -> some View {
        Button {
            selectedCategory = category
            section = .channels
            updateSearch(categoryOverride: category)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: category == nil ? "rectangle.stack" : "square.grid.2x2")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(KyroTheme.accentInk)
                Text(title).font(.system(size: 27, weight: .semibold)).lineLimit(2)
                Text("\(count) channels")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.siloSecondaryText)
            }
            .frame(maxWidth: .infinity, minHeight: 140, alignment: .leading)
            .padding(24)
            .background(Color.siloSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(TVCardFocusButtonStyle(scale: 1.035))
        .focused($focusedControl, equals: .category(category ?? "__all__"))
    }

    private var channelGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let notice = service.errorMessage ?? service.catalogNotice ?? service.guideMessage {
                Label(notice, systemImage: "info.circle")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color.siloSecondaryText)
                    .lineLimit(2)
            }

            if search.isSearching && search.matches.isEmpty {
                ProgressView("Filtering channels…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if search.matches.isEmpty {
                statusPage(symbol: section == .favorites ? "star.slash" : "magnifyingglass",
                           title: section == .favorites ? "No favorite channels" : "No matching channels",
                           message: section == .favorites
                               ? "Use the star on a channel card to add it here."
                               : "Try a different search or category.")
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 34) {
                        ForEach(search.matches) { channel in
                            TVLiveTVChannelCard(
                                channel: channel,
                                program: service.programPair(for: channel),
                                isFavorite: service.isFavorite(channel),
                                focus: $focusedControl,
                                play: { service.choose(channel, from: .list) },
                                toggleFavorite: { service.toggleFavorite(channel) }
                            )
                        }
                    }
                    .padding(.vertical, 18)
                }
                .focusSection()
            }
        }
    }

    private func statusPage(
        symbol: String,
        title: String,
        message: String,
        buttonTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 20) {
            Image(systemName: symbol)
                .font(.system(size: 64, weight: .semibold))
                .foregroundStyle(KyroTheme.accentInk)
            Text(title).font(.system(size: 34, weight: .bold))
            Text(message)
                .font(.system(size: 23))
                .foregroundStyle(Color.siloSecondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 760)
            if let buttonTitle, let action {
                Button(buttonTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .focused($focusedControl, equals: .retry)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var categoryCounts: [String: Int] {
        Dictionary(grouping: service.channels, by: \.category).mapValues(\.count)
    }

    private var providerSummary: String {
        guard let provider = service.selectedProvider else { return "No provider connected" }
        let suffix = provider.channelCount == 1 ? "channel" : "channels"
        return "\(provider.name) · \(provider.channelCount) \(suffix)"
    }

    private func updateSearch(categoryOverride: String? = nil) {
        let category = categoryOverride ?? selectedCategory
        search.update(
            channels: service.channels,
            query: query,
            category: category,
            favoritesOnly: section == .favorites,
            favoriteIDs: service.favoriteChannelIDs,
            includeGroups: false
        )
    }

    private func claimEntryFocus() {
        guard !isTopMenuFocused else { return }
        Task { @MainActor in
            await Task.yield()
            guard !isTopMenuFocused else { return }
            focusedControl = .section(section)
        }
    }
}

private struct TVLiveTVChannelCard: View {
    let channel: LiveTVChannel
    let program: LiveTVProgramPair
    let isFavorite: Bool
    let focus: FocusState<TVLiveTVRootView.FocusTarget?>.Binding
    let play: () -> Void
    let toggleFavorite: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: play) {
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.siloSurface)
                        .aspectRatio(16 / 9, contentMode: .fit)
                    LiveTVChannelLogo(channel: channel, size: CGSize(width: 150, height: 78), placeholderStyle: .clear)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    LinearGradient(colors: [.clear, .black.opacity(0.78)], startPoint: .center, endPoint: .bottom)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    if program.current != nil {
                        Text("LIVE")
                            .font(.system(size: 16, weight: .black))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(KyroTheme.live, in: Capsule())
                            .padding(14)
                    }
                }
            }
            .buttonStyle(TVCardFocusButtonStyle(scale: 1.04))
            .focused(focus, equals: .channel(channel.id))
            .accessibilityLabel("Watch \(channel.name)")

            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(channel.name)
                        .font(.system(size: 23, weight: .semibold))
                        .lineLimit(1)
                    Text(program.current?.title ?? channel.category)
                        .font(.system(size: 18))
                        .foregroundStyle(Color.siloSecondaryText)
                        .lineLimit(1)
                    if let next = program.next {
                        Text("Next: \(next.title)")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.siloSecondaryText.opacity(0.8))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Button(action: toggleFavorite) {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(isFavorite ? KyroTheme.highlight : Color.siloSecondaryText)
                        .frame(width: 42, height: 42)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isFavorite ? "Remove from Favorites" : "Add to Favorites")
            }
        }
    }
}

struct TVLiveTVProviderManagementView: View {
    @Bindable var service: LiveTVService
    @Environment(\.dismiss) private var dismiss
    @State private var kind: LiveTVProviderKind = .m3u
    @State private var name = "My Provider"
    @State private var playlistURL = ""
    @State private var xmltvURL = ""
    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var localError: String?
    @State private var providerToRemove: LiveTVProvider?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 34) {
                    providerList
                    Divider().overlay(Color.white.opacity(0.18))
                    addProviderForm
                }
                .padding(.horizontal, 120)
                .padding(.vertical, 70)
            }
            .background(TVKyroAmbientBackdrop())
            .navigationTitle("Live TV Providers")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onExitCommand { dismiss() }
        .confirmationDialog(
            "Remove \(providerToRemove?.name ?? "provider")?",
            isPresented: Binding(get: { providerToRemove != nil }, set: { if !$0 { providerToRemove = nil } })
        ) {
            Button("Remove Provider", role: .destructive) {
                guard let provider = providerToRemove else { return }
                providerToRemove = nil
                Task { await service.removeProvider(provider.id) }
            }
            Button("Cancel", role: .cancel) { providerToRemove = nil }
        }
    }

    private var providerList: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connected Providers")
                .font(.system(size: 34, weight: .bold))
            if service.providers.isEmpty {
                Text("No providers configured. Credentials are stored in the Apple TV keychain.")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.siloSecondaryText)
            } else {
                ForEach(service.providers) { provider in
                    HStack(spacing: 18) {
                        Button {
                            service.selectProvider(provider.id)
                            Task { await service.prepareSelectedProvider() }
                        } label: {
                            HStack(spacing: 18) {
                                Image(systemName: service.selectedProviderID == provider.id
                                      ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(KyroTheme.accentInk)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(provider.name).font(.system(size: 26, weight: .semibold))
                                    Text("\(provider.kind == .xtream ? "Xtream Codes" : "M3U") · \(provider.channelCount) channels")
                                        .font(.system(size: 19))
                                        .foregroundStyle(Color.siloSecondaryText)
                                }
                                Spacer()
                            }
                            .padding(20)
                            .background(Color.siloSurface, in: RoundedRectangle(cornerRadius: 16))
                        }
                        .buttonStyle(TVCardFocusButtonStyle(scale: 1.02))

                        Button {
                            service.selectProvider(provider.id)
                            Task { await service.refresh(providerID: provider.id) }
                        } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .buttonStyle(.bordered)
                        .disabled(service.isLoading)

                        Button(role: .destructive) { providerToRemove = provider } label: {
                            Label("Remove", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            if service.isLoading { ProgressView("Connecting…") }
            if let message = localError ?? service.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(KyroTheme.live)
                    .font(.system(size: 20, weight: .medium))
            }
        }
    }

    private var addProviderForm: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add Provider").font(.system(size: 34, weight: .bold))
            Picker("Provider Type", selection: $kind) {
                Text("M3U Playlist").tag(LiveTVProviderKind.m3u)
                Text("Xtream Codes").tag(LiveTVProviderKind.xtream)
            }
            .pickerStyle(.segmented)

            TextField("Provider name", text: $name)
                .modifier(TVLiveTVProviderFieldStyle())
            if kind == .m3u {
                TextField("M3U playlist URL", text: $playlistURL)
                    .modifier(TVLiveTVProviderFieldStyle())
                TextField("XMLTV guide URL (optional)", text: $xmltvURL)
                    .modifier(TVLiveTVProviderFieldStyle())
            } else {
                TextField("Server URL", text: $serverURL)
                    .modifier(TVLiveTVProviderFieldStyle())
                TextField("Username", text: $username)
                    .modifier(TVLiveTVProviderFieldStyle())
                SecureField("Password", text: $password)
                    .modifier(TVLiveTVProviderFieldStyle())
            }

            Text("Kyro stores provider configuration in the device keychain. URLs and credentials are never written into the app bundle.")
                .font(.system(size: 19))
                .foregroundStyle(Color.siloSecondaryText)

            Button {
                saveProvider()
            } label: {
                Label("Save and Connect", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSave)
        }
    }

    private var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch kind {
        case .m3u:
            return !playlistURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .xtream:
            return !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !password.isEmpty
        }
    }

    private func saveProvider() {
        do {
            let id: UUID
            switch kind {
            case .m3u:
                id = try service.saveConfiguration(name: name, playlistURL: playlistURL, xmltvURL: xmltvURL)
            case .xtream:
                id = try service.saveXtreamConfiguration(
                    name: name, serverURL: serverURL, username: username, password: password
                )
            }
            localError = nil
            password = ""
            Task { await service.refresh(providerID: id) }
        } catch {
            localError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

private struct TVLiveTVProviderFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: 24))
            .padding(.horizontal, 18)
            .frame(minHeight: 58)
            .background(Color.siloSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct TVLiveTVGuideView: View {
    @Bindable var service: LiveTVService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.timeZone) private var timeZone
    @State private var timeline = LiveTVGuideTimeline(now: .now, timeZone: .current, lookBack: 30 * 60,
                                                      lookAhead: 6 * 60 * 60, pointsPerMinute: 3)
    @State private var category: String?
    @State private var favoritesOnly = false
    @State private var rows: [LiveTVChannel] = []
    @State private var detail: TVLiveTVGuideDetail?
    @State private var navigationState = TVLiveTVGuideNavigationState()
    @FocusState private var focusedChannelID: String?

    private let channelWidth: CGFloat = 310
    private let rowHeight: CGFloat = 112

    var body: some View {
        ZStack {
            TVKyroAmbientBackdrop()
            VStack(alignment: .leading, spacing: 18) {
                guideHeader
                timelineHeader
                guideGrid
            }
            .padding(.horizontal, 58)
            .padding(.vertical, 42)
        }
        .modifier(LiveTVChannelCover(service: service, presenter: .guide, isEnabled: true))
        .onAppear {
            service.presentation.surfaceAppeared(.guide)
            rebuildRows()
        }
        .onDisappear { service.presentation.surfaceDisappeared(.guide) }
        .onChange(of: category) { rebuildRows() }
        .onChange(of: favoritesOnly) { rebuildRows() }
        .onChange(of: service.favoriteChannelIDs) { if favoritesOnly { rebuildRows() } }
        .onChange(of: service.channelCatalogRevision) { rebuildRows() }
        .onChange(of: focusedChannelID) { _, id in
            if let id { navigationState.focus(channelID: id) }
        }
        .onExitCommand { dismiss() }
        .sheet(item: $detail) { detail in
            TVLiveTVProgramDetail(detail: detail) {
                service.choose(detail.channel, from: .guide)
                self.detail = nil
            }
        }
    }

    private var guideHeader: some View {
        HStack(spacing: 16) {
            Button { dismiss() } label: { Label("Back", systemImage: "chevron.left") }
                .buttonStyle(.bordered)
            Text("TV Guide").font(.system(size: 46, weight: .bold))
            Spacer()
            Menu {
                Button("All Categories") { category = nil }
                ForEach(service.categories, id: \.self) { value in
                    Button(value) { category = value }
                }
            } label: {
                Label(category ?? "All Categories", systemImage: "line.3.horizontal.decrease.circle")
            }
            .buttonStyle(.bordered)
            Button {
                favoritesOnly.toggle()
            } label: {
                Label("Favorites", systemImage: favoritesOnly ? "star.fill" : "star")
            }
            .buttonStyle(.bordered)
            Button {
                Task { await service.refreshSelectedProvider() }
            } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            .buttonStyle(.bordered)
            .disabled(service.isLoading || service.isGuideLoading)
        }
    }

    private var timelineHeader: some View {
        HStack(spacing: 0) {
            Text("CHANNEL")
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.siloSecondaryText)
                .frame(width: channelWidth, alignment: .leading)
            ForEach(timeline.ticks) { tick in
                Text(tick.date.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: tick.isHour ? 20 : 17, weight: tick.isHour ? .bold : .medium))
                    .foregroundStyle(tick.isHour ? Color.white : Color.siloSecondaryText)
                    .frame(width: CGFloat(LiveTVGuideTimeline.slot / 60) * timeline.pointsPerMinute,
                           alignment: .leading)
            }
        }
        .frame(height: 38)
    }

    private var guideGrid: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(rows) { channel in
                    guideRow(channel)
                        .task { await service.refreshShortEPG(for: channel) }
                }
            }
        }
        .focusSection()
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView(
                    favoritesOnly ? "No Favorite Channels" : "No Guide Channels",
                    systemImage: favoritesOnly ? "star.slash" : "calendar.badge.exclamationmark",
                    description: Text("Choose another filter or refresh the provider.")
                )
            }
        }
    }

    private func guideRow(_ channel: LiveTVChannel) -> some View {
        HStack(spacing: 0) {
            Button {
                service.choose(channel, from: .guide)
            } label: {
                HStack(spacing: 16) {
                    LiveTVChannelLogo(channel: channel, size: CGSize(width: 80, height: 52))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(channel.name).font(.system(size: 22, weight: .semibold)).lineLimit(1)
                        Text(channel.category).font(.system(size: 16)).foregroundStyle(Color.siloSecondaryText).lineLimit(1)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .frame(width: channelWidth, height: rowHeight)
                .background(Color.siloSurface, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(TVCardFocusButtonStyle(scale: 1.025))
            .focused($focusedChannelID, equals: channel.id)

            programTimeline(for: channel)
        }
    }

    @ViewBuilder
    private func programTimeline(for channel: LiveTVChannel) -> some View {
        let programs = service.guidePrograms(for: channel, overlapping: timeline.interval)
        let cells = LiveTVGuideCell.cells(for: programs, in: timeline)
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.22))
            if cells.isEmpty {
                Button {
                    service.choose(channel, from: .guide)
                } label: {
                    Text("No guide information · Watch channel")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Color.siloSecondaryText)
                        .frame(width: 520, height: rowHeight - 8, alignment: .leading)
                        .padding(.horizontal, 18)
                }
                .buttonStyle(TVBrowsePanelRowStyle())
            } else {
                ForEach(cells) { cell in
                    Button {
                        if LiveTVGuideAction(cell.program, at: .now) == .tune {
                            service.choose(channel, from: .guide)
                        } else {
                            detail = TVLiveTVGuideDetail(channel: channel, program: cell.program)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(cell.program.title)
                                .font(.system(size: 21, weight: .semibold))
                                .lineLimit(1)
                            Text("\(cell.program.start.formatted(date: .omitted, time: .shortened))–\(cell.program.end.formatted(date: .omitted, time: .shortened))")
                                .font(.system(size: 16))
                                .foregroundStyle(Color.siloSecondaryText)
                        }
                        .padding(.horizontal, 15)
                        .frame(width: max(cell.width - 6, 80), height: rowHeight - 8, alignment: .leading)
                        .background(programColor(cell.program), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(TVCardFocusButtonStyle(scale: 1.025))
                    .offset(x: cell.x)
                }
            }

            TimelineView(.periodic(from: .now, by: 60)) { context in
                if timeline.interval.contains(context.date) {
                    Rectangle()
                        .fill(KyroTheme.live)
                        .frame(width: 3, height: rowHeight)
                        .offset(x: timeline.x(for: context.date))
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(width: timeline.width, height: rowHeight)
    }

    private func programColor(_ program: EPGProgram) -> Color {
        switch LiveTVGuideProgramState(program, at: .now) {
        case .past: LiveTVSurface.pastProgram
        case .current: KyroTheme.depth.opacity(0.88)
        case .upcoming: LiveTVSurface.upcomingProgram
        }
    }

    private func rebuildRows() {
        rows = LiveTVChannelFiltering.filter(
            service.channels,
            query: "",
            category: category,
            favoritesOnly: favoritesOnly,
            favoriteIDs: service.favoriteChannelIDs
        )
        navigationState.reconcile(visibleChannelIDs: rows.map(\.id))
        if let target = navigationState.focusedChannelID { focusedChannelID = target }
    }
}

private struct TVLiveTVGuideDetail: Identifiable {
    let channel: LiveTVChannel
    let program: EPGProgram
    var id: String { program.id }
}

private struct TVLiveTVProgramDetail: View {
    let detail: TVLiveTVGuideDetail
    let watch: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(detail.program.title).font(.system(size: 42, weight: .bold))
            Text(detail.channel.name).font(.system(size: 24, weight: .semibold)).foregroundStyle(KyroTheme.accentInk)
            Text("\(detail.program.start.formatted(date: .omitted, time: .shortened))–\(detail.program.end.formatted(date: .omitted, time: .shortened))")
                .font(.system(size: 22)).foregroundStyle(Color.siloSecondaryText)
            if let summary = detail.program.summary, !summary.isEmpty {
                Text(summary).font(.system(size: 22)).foregroundStyle(Color.siloSecondaryText).lineLimit(8)
            }
            HStack(spacing: 18) {
                Button("Watch Channel", action: watch).buttonStyle(.borderedProminent)
                Button("Close") { dismiss() }.buttonStyle(.bordered)
            }
        }
        .padding(70)
        .frame(minWidth: 900, minHeight: 520, alignment: .topLeading)
        .background(TVKyroAmbientBackdrop())
    }
}
#endif
