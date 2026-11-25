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
    let shelf: KyroHomeShelf
    var host: KyroHomeShelfHost
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var routeID = KyroSportsDirectoryRoute.all[0].id
    private let directory = KyroSportsDirectory.shared

    var body: some View {
        NavigationStack {
            List {
                if shelf == .myLeagues {
                    leagueRows
                } else {
                    teamRows
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
            .task(id: routeID) {
                if shelf == .myTeams, let route = KyroSportsDirectoryRoute.all.first(where: { $0.id == routeID }) {
                    await directory.load(route)
                    if directory.failures.contains(route.id) { await loadTeamsIfNeeded() }
                }
            }
        }
        .tint(KyroTheme.accentInk)
    }

    private func loadTeamsIfNeeded() async {
        guard shelf == .myTeams else { return }
        await host.today.load()
        let leagues = host.favorites.preferences.relevantLeagues
        guard !leagues.isEmpty else { return }
        await host.followed.load(leagues: leagues)
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
    private var teamRows: some View {
        Section("Following") {
            ForEach(host.favorites.preferences.teams.sorted(), id: \.self) { key in
                let entry = directory.allEntries.first {
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
        Section("Browse by sport and league") {
            Picker("Directory", selection: $routeID) {
                ForEach(KyroSportsDirectoryRoute.all) { route in Text(route.title).tag(route.id) }
            }
            Button("Refresh selected directory (once per minute)") {
                if let route = KyroSportsDirectoryRoute.all.first(where: { $0.id == routeID }) {
                    Task { await directory.load(route, force: true) }
                }
            }
            .disabled(directory.loading.contains(routeID))
            if directory.loading.contains(routeID) { ProgressView("Loading directory") }
            if directory.failures.contains(routeID) {
                Text("Directory unavailable. Cached teams and loaded schedule teams remain available.").foregroundStyle(.secondary)
            }
            Text("Search includes all downloaded directories and loaded schedules. Choose a league to download its directory. ATP and WTA players are available from loaded matches only. Up to 64 favorites are supported.").font(.caption).foregroundStyle(.secondary)
            Button("Load schedule teams & tennis players") { Task { await loadTeamsIfNeeded() } }
        }
        Section("Teams and players") {
            let records = query.isEmpty ? directory.entries[routeID] ?? [] : directory.allEntries
            ForEach(records.filter { $0.matches(query) }, id: \.id) { entry in
                teamToggle(entry.team, affiliation: entry.affiliation)
            }
            let choices = KyroHomeQuickAdd.teams(in: host.today.games + host.followed.games, matching: query)
            ForEach(choices.filter { choice in !records.contains { $0.team.id == choice.team.id } }) { choice in
                teamToggle(choice.team, affiliation: choice.team.league.displayName + " · Schedule")
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
#endif
