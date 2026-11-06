import SwiftUI
import XCTest
@testable import Silo

@MainActor
private final class SettingsMemorySecretStore: LiveTVSecretStore {
    var values: [String: String] = [:]
    func read(account: String) -> String? { values[account] }
    func save(_ value: String, account: String) -> Bool { values[account] = value; return true }
    func remove(account: String) -> Bool { values.removeValue(forKey: account) != nil }
}

/// Live TV inside Silo's own Settings: one header profile menu, one Settings screen, one Live TV
/// subpage that reuses `LiveTVSettingsView`.
@MainActor
final class KyroSettingsIntegrationTests: XCTestCase {
    private func ephemeralDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suite = "KyroSettingsIntegrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (defaults, { defaults.removePersistentDomain(forName: suite) })
    }

    private func makeService(_ defaults: UserDefaults, _ secrets: SettingsMemorySecretStore) -> LiveTVService {
        LiveTVService(defaults: defaults, secretStore: secrets,
                      epg: EPGService(cache: nil, loader: URLSessionEPGFeedLoader.makeDefault(),
                                      fingerprinter: .inMemory()))
    }

    // MARK: Profile menu -> Settings, from every tab

    func testSettingsOpensFromAllFiveTabsAndLeavesTheSelectedTabAlone() throws {
        let (defaults, cleanup) = try ephemeralDefaults()
        defer { cleanup() }
        for destination in KyroGlobalDestination.tabDestinations(fourthTab: .default) {
            let store = KyroGlobalNavigationStore(defaults: defaults)
            let router = AppRouter()
            store.selectedDestination = destination
            KyroShellHeader.openSettings(router: router)
            XCTAssertEqual(router.visiblePushedRoutes, [.settings], "Settings opens from \(destination)")
            XCTAssertEqual(store.selectedDestination, destination, "opening Settings never changes the tab")
            // Settings' own Back (or dismissal) returns to the tab it came from.
            router.goBack()
            XCTAssertTrue(router.visiblePushedRoutes.isEmpty)
            XCTAssertEqual(store.selectedDestination, destination, "back on \(destination)")
        }
    }

    func testSearchOpensTheExistingSiloSearchFromTheSharedHeader() {
        let router = AppRouter()
        KyroShellHeader.openSearch(router: router)
        XCTAssertEqual(router.visiblePushedRoutes, [.search])
    }

    func testTheProfileMenuHasNoLiveTVOrSettingsCopyOfItsOwnUnderTheUnifiedShell() {
        XCTAssertFalse(KyroLiveTVEntry.profileMenuOffersLiveTV(unifiedShell: true))
        XCTAssertTrue(KyroLiveTVEntry.profileMenuOffersLiveTV(unifiedShell: false), "legacy shell keeps its entry")
    }

    // MARK: Settings -> Live TV

    func testLiveTVIsOneLabelledSettingsEntryThatSearchFinds() {
        XCTAssertEqual(KyroLiveTVSettingsEntry.title, "Live TV")
        for query in ["", "live", "IPTV", "playlist", "M3U", "xtream", "epg", "guide", "provider"] {
            XCTAssertTrue(KyroLiveTVSettingsEntry.matches(query), "\"\(query)\" finds Live TV")
        }
        XCTAssertFalse(KyroLiveTVSettingsEntry.matches("subtitles"))
    }

    func testTheSettingsRowSaysWhichProviderIsActiveOrThatNoneIsSetUp() {
        let a = LiveTVProvider(id: UUID(), name: "Home IPTV", channelCount: 10, lastRefreshed: nil)
        let b = LiveTVProvider(id: UUID(), name: "Backup", channelCount: 5, lastRefreshed: nil)
        XCTAssertEqual(KyroLiveTVSettingsEntry.summary(providers: [], selectedProviderID: nil), "Not set up")
        XCTAssertEqual(KyroLiveTVSettingsEntry.summary(providers: [a], selectedProviderID: a.id), "Home IPTV")
        XCTAssertEqual(KyroLiveTVSettingsEntry.summary(providers: [a, b], selectedProviderID: b.id), "Backup +1")
        XCTAssertEqual(KyroLiveTVSettingsEntry.summary(providers: [a, b], selectedProviderID: nil), "Home IPTV +1")
    }

    func testAPushedLiveTVSubpageUsesTheSystemBackAndStaysAfterSavingAProvider() {
        XCTAssertFalse(LiveTVSettingsPresentation.pushed.showsDoneButton, "one Back button only")
        XCTAssertFalse(LiveTVSettingsPresentation.pushed.dismissesAfterSavingProvider,
                       "saving must not pop or dismiss Settings")
    }

    func testTheSheetKeepsItsDoneButtonAndClosesAfterSavingForFirstTimeSetupAndLegacyLiveTV() {
        XCTAssertTrue(LiveTVSettingsPresentation.sheet.showsDoneButton)
        XCTAssertTrue(LiveTVSettingsPresentation.sheet.dismissesAfterSavingProvider)
    }

    // MARK: Obsolete navigation picker

    func testTheNavigationStylePickerIsHiddenUnderTheUnifiedShellOnly() {
        XCTAssertFalse(KyroLiveTVNavigationSettingsPolicy.offersStylePicker(unifiedShellActive: true, isSupported: true),
                       "Glass Dock and Thumb Fan are not connected to the unified shell")
        XCTAssertTrue(KyroLiveTVNavigationSettingsPolicy.offersStylePicker(unifiedShellActive: false, isSupported: true),
                      "the legacy shell, where the picker works, keeps it")
        XCTAssertFalse(KyroLiveTVNavigationSettingsPolicy.offersStylePicker(unifiedShellActive: false, isSupported: false),
                       "not on iPad")
    }

    func testHidingThePickerLeavesSavedNavigationPreferencesUntouched() throws {
        let (defaults, cleanup) = try ephemeralDefaults()
        defer { cleanup() }
        var legacy = KyroLiveTVNavigationPreferences()
        legacy.style = .thumbFan
        defaults.set(try JSONEncoder().encode(legacy), forKey: KyroLiveTVNavigationStore.defaultsKey)
        _ = KyroLiveTVSettingsEntry.summary(providers: [], selectedProviderID: nil)
        let stored = try XCTUnwrap(defaults.data(forKey: KyroLiveTVNavigationStore.defaultsKey))
        XCTAssertEqual(try JSONDecoder().decode(KyroLiveTVNavigationPreferences.self, from: stored).style, .thumbFan)
        XCTAssertEqual(KyroLiveTVNavigationStore(defaults: defaults).preferences.style, .thumbFan)
    }

    // MARK: First-time setup and persistence

    func testAUserWithNoProviderCanSetOneUpThroughTheSameService() throws {
        let (defaults, cleanup) = try ephemeralDefaults()
        defer { cleanup() }
        let secrets = SettingsMemorySecretStore()
        let service = makeService(defaults, secrets)
        XCTAssertTrue(service.providers.isEmpty)
        XCTAssertEqual(KyroLiveTVSettingsEntry.summary(providers: service.providers,
                                                       selectedProviderID: service.selectedProviderID), "Not set up")

        let id = try service.saveConfiguration(name: "First", playlistURL: "https://example.test/a.m3u",
                                               xmltvURL: "https://example.test/a.xml")
        XCTAssertEqual(service.providers.map(\.id), [id])
        XCTAssertEqual(service.selectedProviderID, id, "the first provider becomes active")
        XCTAssertEqual(KyroLiveTVSettingsEntry.summary(providers: service.providers,
                                                       selectedProviderID: service.selectedProviderID), "First")

        _ = try service.saveXtreamConfiguration(name: "Second", serverURL: "https://xtream.example.test",
                                                username: "user", password: "secret")
        XCTAssertEqual(service.providers.count, 2, "Settings can add more providers")
    }

    func testProvidersFavoritesAndRecentsSurviveARelaunch() throws {
        let (defaults, cleanup) = try ephemeralDefaults()
        defer { cleanup() }
        let secrets = SettingsMemorySecretStore()
        let first = makeService(defaults, secrets)
        let id = try first.saveConfiguration(name: "Kept", playlistURL: "https://example.test/k.m3u", xmltvURL: nil)
        let channelID = "\(id.uuidString):news.one"
        defaults.set([channelID], forKey: "liveTV.favorites.v1")
        let recent = try XCTUnwrap(LiveTVRecentChannel(providerID: id, channelID: channelID))
        let history = LiveTVRecentHistoryStore(defaults: defaults)
        history.save([recent])
        history.flush()

        // A new service on the same stores is what the app builds on its next launch.
        let relaunched = makeService(defaults, secrets)
        XCTAssertEqual(relaunched.providers.map(\.id), [id])
        XCTAssertEqual(relaunched.providers.first?.name, "Kept")
        XCTAssertEqual(relaunched.selectedProviderID, id)
        XCTAssertEqual(relaunched.favoriteChannelIDs, [channelID], "favorites keep their key and format")
        XCTAssertEqual(relaunched.recentlyWatchedRecords, [recent], "recently watched keeps its key and format")
        XCTAssertNotNil(secrets.values["provider.\(id.uuidString)"], "the playlist address stays in the secret store")
    }

    func testSettingsDoesNotChangeTheStoredKeys() throws {
        let (defaults, cleanup) = try ephemeralDefaults()
        defer { cleanup() }
        let service = makeService(defaults, SettingsMemorySecretStore())
        _ = try service.saveConfiguration(name: "Keys", playlistURL: "https://example.test/k.m3u", xmltvURL: nil)
        XCTAssertNotNil(defaults.data(forKey: "liveTV.providers.v1"))
        XCTAssertEqual(KyroGlobalNavigationStore.defaultsKey, "kyro.navigation.global.v1")
        XCTAssertEqual(KyroLiveTVNavigationStore.defaultsKey, "kyro.liveTV.navigation.v1")
    }
}
