#if os(iOS)
import SwiftUI

struct KyroSportsSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    private let settings = KyroSportsDashboardSettings.shared
    private let host = KyroHomeShelfHost.shared
    @AppStorage(LiveTVEmbeddedGuideStyle.defaultsKey) private var guideStyle = LiveTVEmbeddedGuideStyle.list.rawValue
    @State private var categoryPreferences = LiveTVCategoryPreferences.load(providerID: nil)
    var body: some View {
        NavigationStack {
            Form {
                Section("My Favorites") {
                    NavigationLink("Manage Favorite Teams & Players") { KyroHomeFavoritePicker(shelf: .myTeams, host: host) }
                    NavigationLink("Manage Favorite Leagues") { KyroHomeFavoritePicker(shelf: .myLeagues, host: host) }
                }
                Section("Dashboard") {
                    Picker("Default dashboard", selection: Binding(get: { settings.value.defaultLeague }, set: { settings.value.defaultLeague = $0 })) {
                        Text("Last used sport").tag("lastUsed")
                        Text("All Sports").tag("all")
                        ForEach(KyroSportLeague.allCases) { Text($0.displayName).tag($0.rawValue) }
                    }
                    Toggle("Live games", isOn: binding(\.showLive))
                    Toggle("Upcoming games", isOn: binding(\.showUpcoming))
                    Toggle("Completed games", isOn: binding(\.showCompleted))
                    NavigationLink("Enabled leagues & order") { leagueOrder }
                    Picker("Live TV watch guide", selection: $guideStyle) {
                        ForEach(LiveTVEmbeddedGuideStyle.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    Picker("Live TV categories", selection: $categoryPreferences.appearance) {
                        ForEach(LiveTVCategoryAppearance.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Category grouping", selection: $categoryPreferences.grouping) {
                        ForEach(LiveTVCategoryGrouping.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Text("Guide, List, Grid and Categories are Live TV preferences, not Sports Hub layouts. Manage them in Playback & Channels below.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Reset Dashboard Preferences", role: .destructive) {
                        settings.value = .init()
                        for league in KyroSportLeague.allCases { UserDefaults.standard.removeObject(forKey: KyroSportsHubStore.modeKey(league)) }
                    }
                }
                Section("Home Integration") {
                    ForEach([KyroHomeShelf.sportsToday, .myTeams, .myLeagues, .upcomingSports]) { shelf in
                        Toggle(shelf.title, isOn: Binding(get: { !host.arrangement.hidden.contains(shelf) },
                            set: { shown in host.update { $0.setHidden(shelf, !shown) } }))
                    }
                    NavigationLink("Customize Home") { KyroHomeCustomizationView(host: host) }
                }
                Section("Playback & Channels") {
                    NavigationLink("Live TV providers & preferences") { LiveTVSettingsView(service: .shared, presentation: .pushed) }
                    Text("Sports uses your active Live TV provider and automatic event matching. There is no separate matching or sports-player preference store. Use an event’s stream chooser for alternatives; playback controls remain in the player. Scores and directories do not require a provider.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Sports Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .scrollContentBackground(.hidden)
            .background(KyroTheme.background)
        }
        .tint(KyroTheme.accentInk)
        .preferredColorScheme(.dark)
        .onAppear { host.refreshScope(); settings.reload() }
        .onChange(of: categoryPreferences) { _, prefs in prefs.save(providerID: nil) }
    }
    private func binding(_ key: WritableKeyPath<KyroSportsDashboardPreferences, Bool>) -> Binding<Bool> {
        Binding(get: { settings.value[keyPath: key] }, set: { settings.value[keyPath: key] = $0 })
    }
    private var leagueOrder: some View {
        List {
            ForEach(settings.value.order) { league in
                Toggle(league.displayName, isOn: Binding(get: { !settings.value.hidden.contains(league) }, set: { enabled in
                    if enabled { settings.value.hidden.remove(league) } else { settings.value.hidden.insert(league) }
                }))
            }
            .onMove { offsets, destination in settings.value.order.move(fromOffsets: offsets, toOffset: destination) }
        }
        .navigationTitle("Dashboard Leagues")
        .toolbar { EditButton() }
    }
}
#endif
