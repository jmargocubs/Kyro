#if os(iOS)
import SwiftUI

/// Adapted from independent Kyro X's UniversalHomeCustomization. Silo's
/// server-owned rows are never edited. Empty local shelves stay configurable.
struct KyroHomeCustomizationView: View {
    @AppStorage(KyroHomePreferences.key) private var stored = Data()
    @State private var favorites = KyroSportsFavoritesStore.shared
    private var preferences: KyroHomePreferences { .init(data: stored) }
    var body: some View {
        List {
            Section {
                ForEach(preferences.order) { shelf in
                    Toggle(shelf.title, isOn: Binding(
                        get: { !preferences.hidden.contains(shelf) },
                        set: { enabled in
                            var updated = preferences
                            if enabled { updated.hidden.remove(shelf) } else { updated.hidden.insert(shelf) }
                            stored = updated.data
                        }))
                        .accessibilityAction(named: Text("Move up")) { move(shelf, by: -1) }
                        .accessibilityAction(named: Text("Move down")) { move(shelf, by: 1) }
                }
                .onMove { offsets, destination in
                    var updated = preferences
                    updated.order.move(fromOffsets: offsets, toOffset: destination)
                    stored = updated.data
                }
            } header: { Text("Additional Home shelves") } footer: {
                Text("Use Edit to reorder these shelves below Silo Home. Empty shelves hide automatically and keep their settings. Sports covers today and tomorrow.")
            }
            Button("Reset Kyro Home Shelves") { stored = KyroHomePreferences().data }
            Section("Favorite leagues") {
                ForEach(KyroSportLeague.allCases) { league in
                    Toggle(league.displayName, isOn: Binding(
                        get: { favorites.preferences.leagues.contains(league.rawValue) },
                        set: { _ in favorites.toggle(league) }))
                }
            }
            Section {
                ForEach(favorites.preferences.teams.sorted(), id: \.self) { key in
                    HStack {
                        Text(key.replacingOccurrences(of: "|", with: " · "))
                        Spacer()
                        Button("Remove") { favorites.preferences.teams.remove(key) }.buttonStyle(.borderless)
                    }
                }
            } header: { Text("Favorite teams") } footer: {
                Text("Touch and hold a Sports Hub or Home event to favorite its teams or league. My Teams and My Leagues show their events, not unrelated recommendations.")
            }
        }
        .navigationTitle("Kyro Home Shelves")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .primaryAction) { EditButton() } }
        .onAppear { favorites.reload() }
        .onReceive(NotificationCenter.default.publisher(for: .kyroSettingsDidRestore)) { _ in favorites.reload() }
    }

    private func move(_ shelf: KyroHomeShelf, by delta: Int) {
        var updated = preferences
        guard let index = updated.order.firstIndex(of: shelf), updated.order.indices.contains(index + delta) else { return }
        updated.order.swapAt(index, index + delta)
        stored = updated.data
    }
}

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
