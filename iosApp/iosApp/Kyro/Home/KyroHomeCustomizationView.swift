#if os(iOS)
import SwiftUI

/// Customize Home (Build 121). Lists Home in its real order: Silo's server
/// sections stay where the server puts them and cannot be edited here; Kyro's
/// six shelves can be shown, hidden and moved among them. Everything is saved
/// on this device for the current server, account and profile, and backed up
/// with Settings Backup; nothing is written to the Silo server.
struct KyroHomeCustomizationView: View {
    var host: KyroHomeShelfHost = .shared
    @Environment(\.editMode) private var editMode

    /// Silo's sections as Home last loaded them.
    private var sections: [KyroHomeSiloSection] { host.siloSections }
    /// Before Home has loaded this session the server rows are unknown, and a
    /// move would lose each shelf's place among them; show/hide still works.
    private var canMove: Bool { !sections.isEmpty }

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
                    guard canMove else { return }
                    var updated = entries
                    updated.move(fromOffsets: offsets, toOffset: destination)
                    host.update { $0.setOrder(updated) }
                }
            } header: {
                Text("Home order")
            } footer: {
                Text(canMove
                     ? "Kyro shelves can sit anywhere among your server's rows. Server rows keep the order set on the server. Empty shelves hide themselves and keep their place."
                     : "Open Home once to move shelves among your server's rows. You can show or hide shelves here now.")
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
        .onAppear { host.favorites.reload() }
    }

    @ViewBuilder
    private func row(_ entry: KyroHomeEntry) -> some View {
        switch entry {
        case .silo(let id):
            HStack(spacing: 12) {
                Image(systemName: "server.rack").foregroundStyle(.secondary).frame(width: 24)
                Text(titles[id].flatMap { $0.isEmpty ? nil : $0 } ?? "Server row")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Server").font(.caption).foregroundStyle(.tertiary)
            }
            .moveDisabled(true)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Set by your server")
        case .kyro(let shelf):
            HStack(spacing: 12) {
                Image(systemName: shelf.isLiveTV ? "dot.radiowaves.left.and.right" : "sportscourt")
                    .foregroundStyle(KyroTheme.accentInk).frame(width: 24)
                Toggle(shelf.title, isOn: Binding(
                    get: { !host.arrangement.hidden.contains(shelf) },
                    set: { shown in host.update { $0.setHidden(shelf, !shown) } }))
                if canMove, editMode?.wrappedValue != .active {
                    moveButtons(shelf)
                }
            }
            .moveDisabled(!canMove)
            .accessibilityAction(named: Text("Move up")) { move(shelf, by: -1) }
            .accessibilityAction(named: Text("Move down")) { move(shelf, by: 1) }
        }
    }

    private func moveButtons(_ shelf: KyroHomeShelf) -> some View {
        let index = entries.firstIndex(of: .kyro(shelf)) ?? 0
        return HStack(spacing: 4) {
            Button { move(shelf, by: -1) } label: { Image(systemName: "chevron.up") }
                .disabled(index == 0)
                .accessibilityLabel("Move \(shelf.title) up")
            Button { move(shelf, by: 1) } label: { Image(systemName: "chevron.down") }
                .disabled(index == entries.count - 1)
                .accessibilityLabel("Move \(shelf.title) down")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(KyroTheme.accentInk)
    }

    private func move(_ shelf: KyroHomeShelf, by delta: Int) {
        guard canMove else { return }
        host.update { $0.move(shelf, by: delta, sections: sections) }
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
