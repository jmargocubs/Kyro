#if os(iOS)
import SwiftUI

/// One local editor for server-owned Silo content and Kyro's six shelves.
struct KyroHomeCustomizationView: View {
    var host: KyroHomeShelfHost = .shared
    @Environment(\.editMode) private var editMode
    @State private var isLoadingSections = false
    @State private var sectionsUnavailable = false

    /// Silo's sections as Home last loaded them.
    private var sections: [KyroHomeSiloSection] { host.siloSections }
    private var entries: [KyroHomeEntry] { host.arrangement.allEntries(for: sections) }
    private var titles: [String: String] {
        Dictionary(sections.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        List {
            Section {
                ForEach(entries, id: \.self) { entry in
                    row(entry)
                }
                .onMove { offsets, destination in
                    var updated = entries
                    updated.move(fromOffsets: offsets, toOffset: destination)
                    host.update { $0.setOrder(updated) }
                }
            } header: {
                Text("Home order")
            } footer: {
                Text("Drag any row to reorder it. Empty or unavailable server rows retain their settings; nothing changes on the server.")
            }

            if isLoadingSections {
                Section { ProgressView("Loading Silo shelves") }
            } else if sectionsUnavailable {
                Section { Text("Silo shelves are unavailable. Your saved arrangement remains intact.") }
            } else if sections.isEmpty {
                Section { Text("No Silo shelves are available for this profile yet.") }
            }

            Section {
                Button("Reset to Default Arrangement", role: .destructive) { host.resetArrangement() }
                    .disabled(host.arrangement.isDefault)
            } footer: {
                Text("Default: Continue Watching, Next Up, then Sports Today, Recently Watched Live TV, Favorite Live TV Channels, My Teams, My Leagues and Upcoming Sports, then the rest of your server's rows.")
            }

            sportsFavoritesSections

            Section {
                ForEach(host.diagnostics()) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.shelf.title).font(.subheadline)
                        Text(item.summary).font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("Shelf status")
            }
        }
        .tint(KyroTheme.accentInk)
        .navigationTitle("Customize Home")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .primaryAction) { EditButton() } }
        .onAppear { host.refreshScope(); host.favorites.reload() }
        .task { await loadSectionsIfNeeded() }
    }

    private func loadSectionsIfNeeded() async {
        host.refreshScope()
        let activeScope = host.scope
        let hasScopedCache = host.siloSectionsScope == activeScope
        isLoadingSections = !hasScopedCache
        do {
            let response = try await StartupContentPrefetcher.fetchHomeSections()
            guard host.scope == activeScope else { isLoadingSections = false; return }
            host.setSiloSections(response.sections.map {
                KyroHomeSiloSection(id: $0.id, type: $0.sectionType, title: $0.displayTitle(in: .current))
            }, scope: activeScope)
        } catch {
            if host.scope == activeScope && !hasScopedCache { sectionsUnavailable = true }
        }
        isLoadingSections = false
    }

    @ViewBuilder
    private func row(_ entry: KyroHomeEntry) -> some View {
        switch entry {
        case .silo(let id):
            HStack(spacing: 12) {
                Image(systemName: "server.rack").foregroundStyle(.secondary).frame(width: 24)
                Toggle(titles[id].flatMap { $0.isEmpty ? nil : $0 } ?? "Unavailable Silo shelf", isOn: Binding(
                    get: { !host.arrangement.hiddenSilo.contains(id) },
                    set: { shown in host.update { $0.setHiddenSilo(id, !shown) } }))
                Text("Silo").font(.caption2).foregroundStyle(.tertiary)
                if editMode?.wrappedValue != .active { moveButtons(entry) }
            }
            .accessibilityHint("Silo shelf; local visibility and order")
            .accessibilityAction(named: Text("Move up")) { move(entry, by: -1) }
            .accessibilityAction(named: Text("Move down")) { move(entry, by: 1) }
        case .kyro(let shelf):
            HStack(spacing: 12) {
                Image(systemName: shelf.isLiveTV ? "dot.radiowaves.left.and.right" : "sportscourt")
                    .foregroundStyle(KyroTheme.accentInk).frame(width: 24)
                Toggle(shelf.title, isOn: Binding(
                    get: { !host.arrangement.hidden.contains(shelf) },
                    set: { shown in host.update { $0.setHidden(shelf, !shown) } }))
                Text("Kyro").font(.caption2).foregroundStyle(.tertiary)
                if editMode?.wrappedValue != .active {
                    moveButtons(entry)
                }
            }
            .accessibilityHint("Kyro shelf; local visibility and order")
            .accessibilityAction(named: Text("Move up")) { move(entry, by: -1) }
            .accessibilityAction(named: Text("Move down")) { move(entry, by: 1) }
        }
    }

    private func moveButtons(_ entry: KyroHomeEntry) -> some View {
        let index = entries.firstIndex(of: entry) ?? 0
        let title: String
        switch entry {
        case .silo(let id): title = titles[id] ?? "Silo shelf"
        case .kyro(let shelf): title = shelf.title
        }
        return HStack(spacing: 4) {
            Button { move(entry, by: -1) } label: { Image(systemName: "chevron.up") }
                .disabled(index == 0)
                .accessibilityLabel("Move \(title) up")
            Button { move(entry, by: 1) } label: { Image(systemName: "chevron.down") }
                .disabled(index == entries.count - 1)
                .accessibilityLabel("Move \(title) down")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(KyroTheme.accentInk)
    }

    private func move(_ entry: KyroHomeEntry, by delta: Int) {
        host.update { $0.move(entry, by: delta, sections: sections) }
    }

    @ViewBuilder
    private var sportsFavoritesSections: some View {
        let favorites = host.favorites
        Section {
            NavigationLink("Manage Favorite Teams") { KyroHomeFavoritePicker(shelf: .myTeams, host: host) }
            NavigationLink("Manage Favorite Leagues") { KyroHomeFavoritePicker(shelf: .myLeagues, host: host) }
        }
        Section {
            ForEach(KyroSportLeague.allCases) { league in
                Toggle(league.displayName, isOn: Binding(
                    get: { favorites.preferences.leagues.contains(league.rawValue) },
                    set: { _ in favorites.toggle(league) }))
            }
        } header: {
            Text("Favorite leagues")
        } footer: {
            Text("My Leagues shows these leagues' live and upcoming events.")
        }
        Section {
            if favorites.preferences.teams.isEmpty {
                Text("No favorite teams yet").foregroundStyle(.secondary)
            }
            ForEach(favorites.preferences.teams.sorted(), id: \.self) { key in
                HStack {
                    Text(KyroSportsFavorites.storedName(key))
                    Spacer()
                    Button("Remove") { favorites.preferences.teams.remove(key) }
                        .buttonStyle(.borderless)
                        .foregroundStyle(KyroTheme.accentInk)
                }
            }
        } header: {
            Text("Favorite teams")
        } footer: {
            Text("Touch and hold an event in Sports Hub or on Home to favorite its teams or league. Sports Hub and Home share these favorites.")
        }
    }
}

/// Favorite actions for an event card (Sports Hub and Home context menus).
struct KyroSportsFavoriteActions: View {
    let game: KyroSportsGame
    @State private var favorites = KyroSportsFavoritesStore.shared
    var body: some View {
        Button(favorites.preferences.leagues.contains(game.league.rawValue)
               ? "Unfavorite \(game.league.displayName)" : "Favorite \(game.league.displayName)",
               systemImage: "star") { favorites.toggle(game.league) }
        teamButton(game.home.team)
        teamButton(game.away.team)
    }
    private func teamButton(_ team: KyroSportsTeam) -> some View {
        Button(favorites.preferences.includes(team) ? "Unfavorite \(team.fullName)" : "Favorite \(team.fullName)",
               systemImage: "star") { favorites.toggle(team) }
    }
}

/// Searchable league and team choices opened from the Home quick-add cards.
/// Writes go through `KyroHomeQuickAdd.select`, which uses the shared store.
struct KyroHomeFavoritePicker: View {
    @Environment(\.dismiss) private var dismiss
    let shelf: KyroHomeShelf
    var host: KyroHomeShelfHost
    private let directory = KyroSportsDirectory.shared
    private let scheduleProvider = ESPNSportsProvider()
    @State private var query = ""
    @State private var request = DirectoryRequest()
    @State private var isLoading = false
    @State private var fallbackGames: [String: [KyroSportsGame]] = [:]
    @State private var failedSchedules: Set<String> = []

    private enum LoadAction: Hashable, Sendable { case automatic, more, retry }
    private struct DirectoryRequest: Hashable, Sendable {
        var scope = KyroSportsDirectoryScope()
        var action = LoadAction.automatic
        var revision = 0
    }

    private var scope: KyroSportsDirectoryScope { request.scope }
    private var results: [KyroSportsDirectoryEntry] {
        directory.results(in: scope, matching: query,
            schedules: host.today.games + host.followed.games + fallbackGames.values.flatMap { $0 })
    }
    private var missing: [KyroSportsDirectoryRoute] { scope.routes.filter { $0.hasTeamDirectory && directory.entries[$0.id] == nil } }
    private var canRetry: Bool {
        scope.routes.contains { directory.failures.contains($0.id) || failedSchedules.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            List {
                if shelf == .myLeagues {
                    leagueRows
                } else {
                    KyroSportsDirectoryFilters(scope: Binding(get: { scope }, set: {
                        request = DirectoryRequest(scope: $0, revision: request.revision + 1)
                    }))
                    followingRows
                    resultRows
                }
            }
            .searchable(text: $query, prompt: shelf == .myTeams ? "Search teams" : "Search leagues")
            .navigationTitle(KyroHomeQuickAdd.title(for: shelf))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: request) { [request] in await load(request) }
        }
        .tint(KyroTheme.accentInk)
    }

    private func load(_ current: DirectoryRequest) async {
        guard shelf == .myTeams, current == request, !Task.isCancelled else { return }
        isLoading = true
        defer { if request == current { isLoading = false } }
        let routes = current.scope.routes
        let batch: [KyroSportsDirectoryRoute]
        switch current.action {
        case .automatic:
            batch = routes.count == 1 ? routes :
                Array(directory.undiscovered(in: current.scope).prefix(8)) + routes.filter { !$0.hasTeamDirectory }
        case .more:
            batch = Array(directory.undiscovered(in: current.scope).prefix(8))
        case .retry:
            batch = Array(routes.filter {
                directory.failures.contains($0.id) || failedSchedules.contains($0.id)
            }.prefix(8))
        }
        let directory = directory
        await withTaskGroup(of: Void.self) { group in
            for route in batch where route.hasTeamDirectory {
                group.addTask { await directory.load(route, force: current.action == .retry) }
            }
        }
        // For broad discovery, use existing schedule data rather than issuing
        // a second round of requests for every unavailable team directory.
        for route in batch where !route.hasTeamDirectory || (routes.count == 1 || current.action == .retry) {
            guard current == request, !Task.isCancelled else { return }
            if directory.entries[route.id] == nil {
                await loadSchedule(route, request: current)
            }
        }
    }

    private func loadSchedule(_ route: KyroSportsDirectoryRoute, request current: DirectoryRequest) async {
        guard fallbackGames[route.id] == nil || current.action == .retry else { return }
        do {
            let now = Date()
            let competition = route.league == .soccer ? route.slug : nil
            let payload = try await scheduleProvider.client.fetchScoreboard(league: route.league,
                dates: ESPNSportsProvider.espnDayString(for: now), policy: .today, competitionKey: competition)
            let games = try scheduleProvider.mapValidated(payload.response, league: route.league,
                competitionKey: competition, competitionName: competition == nil ? nil : route.title)
            guard request == current, !Task.isCancelled else { return }
            fallbackGames[route.id] = games
            failedSchedules.remove(route.id)
        } catch {
            guard request == current, !Task.isCancelled else { return }
            failedSchedules.insert(route.id)
        }
    }

    private func start(_ action: LoadAction) {
        request = DirectoryRequest(scope: scope, action: action, revision: request.revision + 1)
    }

    @ViewBuilder
    private var leagueRows: some View {
        let leagues = KyroHomeQuickAdd.leagues(matching: query)
        if leagues.isEmpty {
            Text("No matching leagues").foregroundStyle(.secondary)
        }
        ForEach(leagues) { league in
            Toggle(league.displayName, isOn: Binding(
                get: { host.favorites.preferences.leagues.contains(league.rawValue) },
                set: { wants in KyroHomeQuickAdd.select(league, favorites: host.favorites, wants: wants) }))
        }
    }

    @ViewBuilder
    private var followingRows: some View {
        let entries = directory.allEntries
        Section("Following") {
            if host.favorites.preferences.teams.isEmpty {
                Text("No favorites yet").foregroundStyle(.secondary)
            }
            ForEach(host.favorites.preferences.teams.sorted(), id: \.self) { key in
                let entry = entries.first {
                    var single = host.favorites.preferences
                    single.teams = [key]
                    return single.includes($0.team)
                }
                HStack {
                    if let entry { teamLabel(entry.team, affiliation: entry.affiliation) }
                    else { Text(KyroSportsFavorites.storedName(key)) }
                    Spacer()
                    Button("Remove") { host.favorites.preferences.teams.remove(key) }.buttonStyle(.borderless)
                }
            }
        }
    }

    private var resultRows: some View {
        let entries = results
        let includesTennis = scope.routes.contains { !$0.hasTeamDirectory }
        let loading = isLoading || scope.routes.contains { directory.loading.contains($0.id) }
        return Section("Teams and players") {
            if loading { ProgressView("Loading teams and players…") }
            if entries.isEmpty && !loading {
                Text(missing.isEmpty && !includesTennis ? "No matching teams" : "No matches in available results")
                    .foregroundStyle(.secondary)
            }
            if !missing.isEmpty {
                Text(scope.routeID == nil
                     ? "Some leagues aren’t loaded. Results may be incomplete."
                     : "The team directory isn’t loaded. Available schedule results are shown.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if includesTennis {
                Text("Tennis players come from available match schedules.").font(.footnote).foregroundStyle(.secondary)
            }
            if !loading && !directory.undiscovered(in: scope).isEmpty {
                Button("Search More Leagues") { start(.more) }
            }
            if !loading && canRetry {
                Button("Retry Unavailable Leagues") { start(.retry) }
            }
            ForEach(entries) { entry in
                teamToggle(entry.team, affiliation: entry.affiliation)
            }
        }
    }

    private func teamToggle(_ team: KyroSportsTeam, affiliation: String) -> some View {
        Toggle(isOn: Binding(get: { host.favorites.preferences.includes(team) },
            set: { KyroHomeQuickAdd.select(team, favorites: host.favorites, wants: $0) })) {
                teamLabel(team, affiliation: affiliation)
            }
            .disabled(!host.favorites.preferences.includes(team) && host.favorites.preferences.teams.count >= 64)
    }

    private func teamLabel(_ team: KyroSportsTeam, affiliation: String) -> some View {
        HStack {
            KyroSportsTeamLogo(team: team, size: 32)
            VStack(alignment: .leading) {
                Text(team.fullName)
                Text(affiliation).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct KyroSportsDirectoryFilters: View {
    @Binding var scope: KyroSportsDirectoryScope

    var body: some View {
        Section {
            Picker("Sport", selection: Binding(get: { scope.sport }, set: {
                scope = .init(sport: $0)
            })) {
                Text("All Sports").tag(nil as KyroSportsDirectorySport?)
                ForEach(KyroSportsDirectorySport.allCases, id: \.self) { sport in
                    Text(sport.title).tag(Optional(sport))
                }
            }
            if let sport = scope.sport {
                Picker("League", selection: $scope.routeID) {
                    Text("All Leagues").tag(nil as String?)
                    ForEach(KyroSportsDirectoryScope(sport: sport).routes) { route in
                        Text(route.title).tag(Optional(route.id))
                    }
                }
            }
        }
    }
}
#endif
