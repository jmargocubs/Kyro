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
                    Text(key.replacingOccurrences(of: "|", with: " · "))
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
#endif
