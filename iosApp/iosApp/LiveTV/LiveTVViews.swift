import SwiftUI

private enum LiveTVAccent {
    static let orchid = Color(hex: "#713B88")
    static let orchidLight = Color(hex: "#C59BDB")
}

struct LiveTVView: View {
    @Bindable var service: LiveTVService
    @State private var searchText = ""
    @State private var searchModel = LiveTVChannelSearchModel()
    @State private var selectedCategory: String?
    @State private var favoritesOnly = false
    @State private var selectedChannel: LiveTVChannel?
    @State private var isShowingSettings = false

    var body: some View {
        List {
            if let provider = service.selectedProvider {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.title2)
                            .foregroundStyle(LiveTVAccent.orchidLight)
                            .frame(width: 44, height: 44)
                            .background(LiveTVAccent.orchid.opacity(0.28), in: RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(provider.name).font(.headline)
                            Text("\(service.channels.count) channels")
                                .font(.caption).foregroundStyle(Color.siloSecondaryText)
                        }
                        Spacer()
                        if service.isLoading { ProgressView().tint(LiveTVAccent.orchidLight) }
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Color.siloSurface)
                }
            }

            if service.isLoading && service.channels.isEmpty {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Loading channels…").foregroundStyle(Color.siloSecondaryText)
                    }
                    .listRowBackground(Color.siloSurface)
                }
            } else if let error = service.errorMessage {
                Section {
                    ContentUnavailableView {
                        Label("Couldn’t Load Channels", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try Again") { Task { await service.refreshSelectedProvider() } }
                            .tint(LiveTVAccent.orchidLight)
                    }
                    .listRowBackground(Color.siloSurface)
                }
            } else if service.providers.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("Set Up Live TV", systemImage: "antenna.radiowaves.left.and.right")
                    } description: {
                        Text("Add an M3U playlist or Xtream Codes account to browse live channels.")
                    } actions: {
                        Button("Add Playlist") { isShowingSettings = true }
                            .buttonStyle(.borderedProminent)
                            .tint(LiveTVAccent.orchid)
                    }
                    .listRowBackground(Color.siloSurface)
                }
            } else if service.channels.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No Channels",
                        systemImage: "tv",
                        description: Text("Refresh the playlist or check its settings.")
                    )
                    .listRowBackground(Color.siloSurface)
                }
            } else {
                if !service.providers.isEmpty {
                    Section {
                        HStack(spacing: 10) {
                            Menu {
                                Button("All Categories") { selectedCategory = nil }
                                ForEach(service.categories, id: \.self) { category in
                                    Button(category) { selectedCategory = category }
                                }
                            } label: {
                                Label(selectedCategory ?? "All Categories", systemImage: "line.3.horizontal.decrease")
                                    .foregroundStyle(LiveTVAccent.orchidLight)
                            }
                            Spacer()
                            Button {
                                favoritesOnly.toggle()
                            } label: {
                                Label(favoritesOnly ? "Favorites" : "All", systemImage: favoritesOnly ? "star.fill" : "star")
                                    .foregroundStyle(favoritesOnly ? LiveTVAccent.orchidLight : Color.siloSecondaryText)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(favoritesOnly ? "Show all channels" : "Show favorites only")
                        }
                        .listRowBackground(Color.siloSurface)
                    }

                    if searchModel.resultCount == 0 {
                        Section {
                            ContentUnavailableView.search(text: searchText)
                                .listRowBackground(Color.siloSurface)
                        }
                    } else {
                        ForEach(searchModel.orderedCategories, id: \.self) { category in
                            Section(category) {
                                ForEach(searchModel.groups[category] ?? []) { channel in
                                    channelRow(channel)
                                }
                            }
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.siloBackground)
        .tint(LiveTVAccent.orchidLight)
        .navigationTitle("Live TV")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search channels")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if service.providers.count > 1 {
                    Menu {
                        ForEach(service.providers) { provider in
                            Button {
                                selectedCategory = nil
                                service.selectProvider(provider.id)
                                Task { if service.channels.isEmpty { await service.refresh(providerID: provider.id) } }
                            } label: {
                                if provider.id == service.selectedProviderID {
                                    Label(provider.name, systemImage: "checkmark")
                                } else { Text(provider.name) }
                            }
                        }
                    } label: {
                        Image(systemName: "rectangle.2.swap")
                    }
                    .accessibilityLabel("Switch Live TV provider")
                }
                Button {
                    isShowingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Live TV settings")
                if !service.providers.isEmpty {
                    Button {
                        Task { await service.refreshSelectedProvider() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(service.isLoading)
                    .accessibilityLabel("Refresh playlist")
                }
            }
        }
        .refreshable { await service.refreshSelectedProvider() }
        .sheet(isPresented: $isShowingSettings) {
            NavigationStack {
                LiveTVSettingsView(service: service)
            }
            .tint(LiveTVAccent.orchidLight)
        }
        .fullScreenCover(item: $selectedChannel) { channel in
            LiveTVPlayerView(channel: channel, channels: service.channels, session: service.playerSession)
        }
        .task(id: service.selectedProviderID) {
            updateSearch()
            if service.channels.isEmpty, service.selectedProviderID != nil {
                await service.refreshSelectedProvider()
            }
        }
        .onAppear { updateSearch() }
        .onDisappear { searchModel.cancel() }
        .onChange(of: searchText) { updateSearch() }
        .onChange(of: selectedCategory) { updateSearch() }
        .onChange(of: favoritesOnly) { updateSearch() }
        .onChange(of: service.favoriteChannelIDs) { updateSearch() }
        .onChange(of: service.channelCatalogRevision) { updateSearch() }
    }

    private func updateSearch() {
        searchModel.update(channels: service.channels, query: searchText, category: selectedCategory,
                           favoritesOnly: favoritesOnly, favoriteIDs: service.favoriteChannelIDs)
    }

    private func channelRow(_ channel: LiveTVChannel) -> some View {
        HStack(spacing: 12) {
            Button {
                selectedChannel = channel
                Task { await service.refreshShortEPG(for: channel) }
            } label: {
                HStack(spacing: 12) {
                    channelLogo(channel)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(channel.name)
                            .font(.body.weight(.medium))
                            .foregroundStyle(Color.siloOnSurface)
                            .lineLimit(1)
                        if !service.isGuideStale {
                            let pair = service.programPair(for: channel)
                            if let current = pair.current {
                                Text("Now · \(current.title)")
                                    .font(.caption)
                                    .foregroundStyle(Color.siloSecondaryText)
                                    .lineLimit(1)
                            }
                            if let next = pair.next {
                                Text("Next · \(next.title)")
                                    .font(.caption2)
                                    .foregroundStyle(Color.siloSecondaryText.opacity(0.8))
                                    .lineLimit(1)
                            }
                        } else if service.guideMessage != nil || service.isGuideStale {
                            Text("Program guide unavailable")
                                .font(.caption)
                                .foregroundStyle(Color.siloSecondaryText)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "play.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(LiveTVAccent.orchidLight)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play \(channel.name)")

            Button {
                service.toggleFavorite(channel)
            } label: {
                Image(systemName: service.isFavorite(channel) ? "star.fill" : "star")
                    .foregroundStyle(service.isFavorite(channel) ? LiveTVAccent.orchidLight : Color.siloSecondaryText)
                    .frame(width: 40, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(service.isFavorite(channel) ? "Remove \(channel.name) from favorites" : "Add \(channel.name) to favorites")
        }
        .listRowBackground(Color.siloSurface)
    }

    @ViewBuilder
    private func channelLogo(_ channel: LiveTVChannel) -> some View {
        if let logoURL = channel.logoURL {
            AsyncImageView(url: logoURL.absoluteString, targetSize: CGSize(width: 50, height: 42),
                           contentMode: .fit, placeholderSymbol: "tv")
            .frame(width: 50, height: 42)
            .accessibilityHidden(true)
        } else {
            logoPlaceholder
        }
    }

    private var logoPlaceholder: some View {
        Image(systemName: "tv")
            .font(.title3)
            .foregroundStyle(LiveTVAccent.orchidLight)
            .frame(width: 50, height: 42)
            .background(Color.siloSurfaceElevated, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)
    }
}

struct LiveTVSettingsView: View {
    @Bindable var service: LiveTVService
    @Environment(\.dismiss) private var dismiss
    @State private var providerName = "My Playlist"
    @State private var playlistURL = ""
    @State private var xmltvURL = ""
    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var providerKind: LiveTVProviderKind = .m3u
    @State private var errorMessage: String?
    @State private var providerToRemove: LiveTVProvider?

    var body: some View {
        Form {
            Section("Providers") {
                if service.providers.isEmpty {
                    Text("No providers configured.")
                        .foregroundStyle(Color.siloSecondaryText)
                }
                ForEach(service.providers) { provider in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(provider.name)
                            Text("\(provider.kind == .m3u ? "M3U" : "Xtream") · \(provider.channelCount) channels")
                                .font(.caption).foregroundStyle(Color.siloSecondaryText)
                        }
                        Spacer()
                        if provider.id == service.selectedProviderID {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(LiveTVAccent.orchidLight)
                        }
                        Button(role: .destructive) { providerToRemove = provider } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(provider.name)")
                    }
                }
            }

            Section("Add IPTV Provider") {
                Picker("Provider type", selection: $providerKind) {
                    Text("M3U Playlist").tag(LiveTVProviderKind.m3u)
                    Text("Xtream Codes").tag(LiveTVProviderKind.xtream)
                }
                .pickerStyle(.segmented)
                TextField("Provider name", text: $providerName)
                    .textContentType(.name)
                if providerKind == .m3u {
                    TextField("Playlist URL (HTTP or HTTPS)", text: $playlistURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("XMLTV guide URL (optional)", text: $xmltvURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    Text("Playlist and guide addresses are stored in Keychain.")
                } else {
                    TextField("Server URL (HTTP or HTTPS, optional port)", text: $serverURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("Credentials are stored in Keychain and sent only to this provider. HTTP connections are not encrypted.")
                }
                Text("Provider settings are fetched only when added or when you refresh Live TV.")
                    .font(.footnote)
                    .foregroundStyle(Color.siloSecondaryText)
                if let errorMessage {
                    Text(errorMessage).font(.footnote).foregroundStyle(.red)
                }
                Button("Save Provider") { saveProvider() }
                    .disabled(providerKind == .m3u
                              ? playlistURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              : serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || username.isEmpty || password.isEmpty)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.siloBackground)
        .navigationTitle("Live TV Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .confirmationDialog(
            "Remove \(providerToRemove?.name ?? "provider")?",
            isPresented: Binding(
                get: { providerToRemove != nil },
                set: { if !$0 { providerToRemove = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Provider", role: .destructive) {
                if let providerToRemove { service.removeProvider(providerToRemove.id) }
                providerToRemove = nil
            }
        }
    }

    private func saveProvider() {
        do {
            if providerKind == .m3u {
                _ = try service.saveConfiguration(name: providerName, playlistURL: playlistURL, xmltvURL: xmltvURL)
            } else {
                _ = try service.saveXtreamConfiguration(name: providerName, serverURL: serverURL,
                                                       username: username, password: password)
            }
            dismiss()
        } catch let error as LiveTVError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = "The provider could not be saved."
        }
    }
}
