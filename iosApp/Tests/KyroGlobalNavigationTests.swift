#if os(iOS)
import XCTest
@testable import Silo

final class KyroGlobalNavigationTests: XCTestCase {
    func testGlobalDestinationIdentityIsTheRequiredFive() {
        XCTAssertEqual(KyroGlobalDestination.allCases, [.home, .movies, .series, .forYou, .liveTV])
        XCTAssertEqual(KyroGlobalDestination.requiredDestinations, [.home, .movies, .series, .forYou, .liveTV])
        XCTAssertEqual(Set(KyroGlobalDestination.allCases.map(\.id)).count, 5)
        XCTAssertEqual(KyroGlobalDestination.liveTV.id, "liveTV")
    }

    @MainActor
    func testFreshPreferencesAndSelectionDefaultToClassicAndHome() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: Self.suiteName) }

        let store = KyroGlobalNavigationStore(defaults: defaults)
        XCTAssertEqual(store.preferences.style, .classic)
        XCTAssertEqual(store.selectedDestination, .home)
        XCTAssertEqual(KyroNavigationPresentationStyle.allCases, [.classic, .glassDock, .thumbFan])
    }

    @MainActor
    func testExistingGlassDockPreferenceMigratesCompatibleValuesAndLeavesLegacyDataUntouched() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: Self.suiteName) }

        let legacyData = Data((#"{"style":"glassDock","order":["search","guide","home"],"hidden":["guide"],"#
            + #""autoCollapse":false,"idleBehavior":"collapseAndFade","hapticsEnabled":false,"thumbScrubbing":false,"#
            + #""allowsDragging":false,"startingEdge":"left","dockAnchor":{"edge":"top","position":0.2},"#
            + #""fanAnchor":{"edge":"bottom","position":0.8}}"#).utf8)
        defaults.set(legacyData, forKey: KyroGlobalNavigationStore.legacyLiveTVDefaultsKey)

        let store = KyroGlobalNavigationStore(defaults: defaults)
        XCTAssertEqual(store.preferences.style, .glassDock)
        XCTAssertFalse(store.preferences.autoCollapse)
        XCTAssertEqual(store.preferences.idleBehavior, .collapseAndFade)
        XCTAssertFalse(store.preferences.hapticsEnabled)
        XCTAssertFalse(store.preferences.thumbScrubbing)
        XCTAssertFalse(store.preferences.allowsDragging)
        XCTAssertEqual(store.preferences.startingEdge, .left)
        XCTAssertEqual(store.preferences.anchor(for: .glassDock), KyroNavigationAnchor(edge: .top, position: 0.2))
        XCTAssertEqual(store.preferences.anchor(for: .thumbFan), KyroNavigationAnchor(edge: .bottom, position: 0.8))

        XCTAssertEqual(defaults.data(forKey: KyroGlobalNavigationStore.legacyLiveTVDefaultsKey), legacyData,
                       "Migration must not remove or rewrite the rollback source")
        let migratedData = try XCTUnwrap(defaults.data(forKey: KyroGlobalNavigationStore.defaultsKey))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: migratedData) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, KyroGlobalNavigationPreferences.currentSchemaVersion)
        XCTAssertNil(json["order"], "Live TV-only ordering is not global navigation preference")
        XCTAssertNil(json["hidden"], "Live TV-only visibility is not global navigation preference")
    }

    @MainActor
    func testThumbFanStyleMigratesAndClassicStillKeepsSavedFloatingAnchors() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: Self.suiteName) }

        let legacyData = Data((#"{"style":"thumbFan","startingEdge":"right","dockAnchor":{"edge":"left","position":0.25},"#
            + #""fanAnchor":{"edge":"top","position":0.7}}"#).utf8)
        defaults.set(legacyData, forKey: KyroGlobalNavigationStore.legacyLiveTVDefaultsKey)

        let thumbFanStore = KyroGlobalNavigationStore(defaults: defaults)
        XCTAssertEqual(thumbFanStore.preferences.style, .thumbFan)
        XCTAssertEqual(thumbFanStore.preferences.anchor(for: .glassDock), KyroNavigationAnchor(edge: .left, position: 0.25))
        XCTAssertEqual(thumbFanStore.preferences.anchor(for: .thumbFan), KyroNavigationAnchor(edge: .top, position: 0.7))

        // A user who later chooses Classic must not lose their saved floating
        // positions; the legacy schema may also have stored anchors while
        // Classic was selected.
        let classicData = Data((#"{"style":"classic","startingEdge":"right","dockAnchor":{"edge":"left","position":0.25},"#
            + #""fanAnchor":{"edge":"top","position":0.7}}"#).utf8)
        defaults.removeObject(forKey: KyroGlobalNavigationStore.defaultsKey)
        defaults.set(classicData, forKey: KyroGlobalNavigationStore.legacyLiveTVDefaultsKey)
        let classicStore = KyroGlobalNavigationStore(defaults: defaults)
        XCTAssertEqual(classicStore.preferences.style, .classic)
        XCTAssertEqual(classicStore.preferences.anchor(for: .glassDock), KyroNavigationAnchor(edge: .left, position: 0.25))
        XCTAssertEqual(classicStore.preferences.anchor(for: .thumbFan), KyroNavigationAnchor(edge: .top, position: 0.7))
    }

    @MainActor
    func testPreferenceUpdatesPersistAndReload() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: Self.suiteName) }

        let store = KyroGlobalNavigationStore(defaults: defaults)
        store.preferences.style = .thumbFan
        store.preferences.startingEdge = .bottom
        store.preferences.setAnchor(KyroNavigationAnchor(edge: .right, position: 0.33), for: .thumbFan)

        let reloaded = KyroGlobalNavigationStore(defaults: defaults)
        XCTAssertEqual(reloaded.preferences.style, .thumbFan)
        XCTAssertEqual(reloaded.preferences.startingEdge, .bottom)
        XCTAssertEqual(reloaded.preferences.anchor(for: .thumbFan), KyroNavigationAnchor(edge: .right, position: 0.33))
    }

    @MainActor
    func testMalformedPreferenceDataFallsBackSafelyAndPartialDataUsesDefaults() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: Self.suiteName) }

        defaults.set(Data("not-json".utf8), forKey: KyroGlobalNavigationStore.defaultsKey)
        let malformedStore = KyroGlobalNavigationStore(defaults: defaults)
        XCTAssertEqual(malformedStore.preferences, KyroGlobalNavigationPreferences())

        defaults.set(Data(#"{"schemaVersion":1,"style":"unknown-style","idleBehavior":"unknown"}"#.utf8),
                     forKey: KyroGlobalNavigationStore.defaultsKey)
        let partialStore = KyroGlobalNavigationStore(defaults: defaults)
        XCTAssertEqual(partialStore.preferences.style, .classic)
        XCTAssertEqual(partialStore.preferences.idleBehavior, .collapse)
        XCTAssertTrue(partialStore.preferences.hapticsEnabled)
        XCTAssertEqual(partialStore.preferences.startingEdge, .right)
    }

    func testAllGlobalDestinationsAreRequiredAndThereIsNoVisibilityPreference() throws {
        let defaults = KyroGlobalNavigationPreferences()
        XCTAssertEqual(defaults.schemaVersion, KyroGlobalNavigationPreferences.currentSchemaVersion)
        XCTAssertEqual(defaults.style, .classic)
        XCTAssertEqual(KyroGlobalDestination.requiredDestinations.count, 5)
        XCTAssertEqual(Set(KyroGlobalDestination.requiredDestinations), Set(KyroGlobalDestination.allCases))

        let encoded = try JSONEncoder().encode(defaults)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(json["hidden"])
        XCTAssertNil(json["order"])
    }

    private static let suiteName = "KyroGlobalNavigationTests.\(UUID().uuidString)"

    private func makeDefaults() throws -> UserDefaults {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: Self.suiteName))
        defaults.removePersistentDomain(forName: Self.suiteName)
        return defaults
    }
}
#endif
