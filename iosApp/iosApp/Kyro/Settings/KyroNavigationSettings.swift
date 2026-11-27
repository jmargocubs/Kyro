import SwiftUI

/// Settings → Navigation: primary destination selection and order.
enum KyroNavigationSettingsEntry {
    static let title = "Navigation"
    static let subtitle = "Choose and reorder primary destinations"
    static let systemImage = "square.grid.3x1.below.line.grid.1x2"

    /// Words that find this row in the Settings search field.
    static let searchTerms = ["navigation", "tab", "tab bar", "primary destinations", "movies", "series", "live tv", "sports", "for you", "favorites", "radio", "podcasts"]

    static func matches(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return searchTerms.contains { $0.localizedCaseInsensitiveContains(trimmed) }
    }
}

extension KyroFourthTab {
    var settingsSummary: String {
        switch self {
        case .sports: "Scores, schedules and your teams."
        case .forYou: "Personal recommendations. Also in the profile menu."
        case .favorites: "Everything you marked as a favorite."
        case .radio: "Internet radio, favorite stations, and listening history."
        case .podcasts: "Discover, subscribe, and listen to podcasts."
        }
    }
}

#if os(iOS)
/// The Navigation row in the Settings overview.
struct KyroNavigationSettingsRow: View {
    @State private var store = KyroGlobalNavigationStore.shared

    var body: some View {
        NavigationLink {
            KyroNavigationSettingsView(store: store)
        } label: {
            SettingsOverviewRow(
                title: KyroNavigationSettingsEntry.title,
                subtitle: KyroNavigationSettingsEntry.subtitle,
                systemImage: KyroNavigationSettingsEntry.systemImage,
                value: "\(store.tabDestinations.count) tabs"
            )
        }
        .accessibilityIdentifier("kyroSettingsNavigation")
    }
}

struct KyroNavigationSettingsSection: View {
    var body: some View {
        Section { KyroNavigationSettingsRow() }
    }
}

struct KyroNavigationSettingsView: View {
    @Bindable var store: KyroGlobalNavigationStore
    private var items: [KyroGlobalDestination] { store.preferences.primaryTabs.destinations }

    var body: some View {
        Form {
            Section("Preview") {
                HStack(alignment: .top, spacing: 4) {
                    ForEach(store.tabDestinations) { destination in
                        VStack(spacing: 5) {
                            Image(systemName: destination.presentation.icon).font(.title3)
                            Text(destination.presentation.title).font(.caption2).lineLimit(2)
                        }
                        .frame(maxWidth: .infinity)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            Section("Primary Destinations") {
                HStack {
                    destinationLabel(.home)
                    Spacer()
                    Image(systemName: "lock").foregroundStyle(.secondary).accessibilityLabel("Fixed first tab")
                }
                ForEach(Array(items.enumerated()), id: \.element) { index, destination in
                    selectedRow(destination, at: index)
                }
            }
            Section {
                ForEach(KyroGlobalDestination.moreDestinations(primary: store.tabDestinations)) { destination in
                    Button {
                        store.preferences.primaryTabs.add(destination)
                    } label: {
                        HStack {
                            destinationLabel(destination)
                            Spacer()
                            Image(systemName: "plus.circle").accessibilityHidden(true)
                        }
                    }
                    .accessibilityLabel("Add \(destination.presentation.title)")
                    .disabled(items.count >= KyroPrimaryTabs.limit)
                }
            } header: { Text("In More") } footer: {
                Text(items.count == KyroPrimaryTabs.limit
                     ? "Remove a primary destination before adding another. Removed destinations stay available in More."
                     : "Add up to four destinations. Home always stays first.")
            }
            Section {
                Button("Reset to Default") { store.preferences.primaryTabs = .standard }
                    .disabled(store.preferences.primaryTabs == .standard)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.siloBackground.ignoresSafeArea())
        .navigationTitle(KyroNavigationSettingsEntry.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func selectedRow(_ destination: KyroGlobalDestination, at index: Int) -> some View {
        HStack(spacing: 4) {
            destinationLabel(destination)
            Spacer(minLength: 8)
            Button("Move \(destination.presentation.title) up", systemImage: "chevron.up") {
                store.preferences.primaryTabs.move(destination, by: -1)
            }.disabled(index == 0)
            Button("Move \(destination.presentation.title) down", systemImage: "chevron.down") {
                store.preferences.primaryTabs.move(destination, by: 1)
            }.disabled(index == items.count - 1)
            Button("Move \(destination.presentation.title) to More", systemImage: "minus.circle") {
                store.preferences.primaryTabs.remove(destination)
            }
        }
        .buttonStyle(.borderless)
        .labelStyle(.iconOnly)
    }

    private func destinationLabel(_ destination: KyroGlobalDestination) -> some View {
        Label(destination.presentation.title, systemImage: destination.presentation.icon)
            .labelStyle(.titleAndIcon)
    }
}
#endif
