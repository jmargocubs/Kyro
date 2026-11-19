#if os(tvOS)
import XCTest
@testable import Silo

@MainActor
final class KyroTVVisibilityTests: XCTestCase {
    private func channel(_ id: String, category: String = "News") -> LiveTVChannel {
        LiveTVChannel(id: id, guideID: nil, name: "Channel \(id)",
                      streamURL: URL(string: "https://example.invalid/\(id)")!,
                      logoURL: nil, category: category)
    }

    func testHiddenChannelsFilterBrowseSearchFavoritesAndGuideInputsWithoutDeletingCatalog() {
        let defaults = UserDefaults(suiteName: "kyro-visibility-\(UUID().uuidString)")!
        let store = TVLiveTVVisibilityStore(defaults: defaults)
        let scope = TVLiveTVVisibilityScope(profileID: "profile-A", providerID: UUID())
        let source = [channel("one"), channel("two")]
        store.hide(source[0], in: scope)
        let snapshot = store.snapshot(for: scope)
        XCTAssertEqual(snapshot.visibleChannels(source).map(\.id), ["two"])
        XCTAssertEqual(source.count, 2, "The IPTV catalog is not changed")
        XCTAssertEqual(snapshot.channels["one"]?.name, "Channel one")
        store.restoreChannel("one", in: scope)
        XCTAssertEqual(store.snapshot(for: scope).visibleChannels(source).count, 2)
    }

    func testHiddenPreferencesSurviveRestartAndRemainProfileAndProviderScoped() {
        let defaults = UserDefaults(suiteName: "kyro-visibility-\(UUID().uuidString)")!
        let provider = UUID()
        let scope = TVLiveTVVisibilityScope(profileID: "profile-A", providerID: provider)
        let first = TVLiveTVVisibilityStore(defaults: defaults)
        first.hide(channel("one"), in: scope)
        first.hideCategory("News", in: scope)
        let reloaded = TVLiveTVVisibilityStore(defaults: defaults)
        let snapshot = reloaded.snapshot(for: scope)
        XCTAssertTrue(snapshot.hiddenChannelIDs.contains("one"))
        XCTAssertEqual(snapshot.visibleCategories(["News", "Sports"]), ["Sports"])
        // "one" is hidden itself, "two" by its hidden News category; Sports stays visible.
        XCTAssertEqual(snapshot.visibleChannels([channel("one"), channel("two"), channel("three", category: "Sports")])
            .map(\.id), ["three"])
        XCTAssertTrue(reloaded.snapshot(for: .init(profileID: "profile-B", providerID: provider)).hiddenChannelIDs.isEmpty)
        XCTAssertTrue(reloaded.snapshot(for: .init(profileID: "profile-A", providerID: UUID())).hiddenChannelIDs.isEmpty)
    }

    func testRestoreAllIsScopedToOneProfileAndProvider() {
        let defaults = UserDefaults(suiteName: "kyro-visibility-\(UUID().uuidString)")!
        let store = TVLiveTVVisibilityStore(defaults: defaults)
        let provider = UUID()
        let first = TVLiveTVVisibilityScope(profileID: "one", providerID: provider)
        let second = TVLiveTVVisibilityScope(profileID: "two", providerID: provider)
        store.hideCategory("News", in: first)
        store.hide(channel("other"), in: second)
        XCTAssertTrue(store.snapshot(for: first).visibleCategories(["News"]).isEmpty)
        store.restoreAll(in: first)
        XCTAssertEqual(store.snapshot(for: first).visibleCategories(["News"]), ["News"])
        XCTAssertTrue(store.snapshot(for: second).hiddenChannelIDs.contains("other"))
    }

    // MARK: Build 98: hidden categories hide their channels everywhere

    private func stream(_ id: String, category: String, streamID: Int? = nil, url: String? = nil) -> LiveTVChannel {
        var value = LiveTVChannel(id: id, guideID: nil, name: "Channel \(id)",
                                  streamURL: URL(string: url ?? "https://example.invalid/\(id)")!,
                                  logoURL: nil, category: category)
        value.streamID = streamID
        return value
    }

    private var catalog: [LiveTVChannel] {
        [
            stream("nfhs-1", category: "NFHS Network", streamID: 101),
            stream("nfhs-2", category: "NFHS Network", streamID: 102),
            // The same NFHS stream also listed under a visible category.
            stream("sports-101", category: "Sports", streamID: 101),
            // The same M3U URL in two groups.
            stream("m3u-a", category: "NFHS Network", url: "https://example.invalid/shared"),
            stream("m3u-b", category: "Local", url: "https://example.invalid/shared"),
            stream("news-1", category: "News", streamID: 201),
            stream("sports-1", category: "Sports", streamID: 301),
        ]
    }

    func testHiddenCategoryHidesItsChannelsFromEveryBrowsingSurface() {
        var snapshot = TVLiveTVVisibilitySnapshot()
        snapshot.categories = ["NFHS Network"]
        let policy = TVLiveTVVisibilityPolicy(snapshot: snapshot, catalog: catalog)
        let visible = policy.visibleChannels(catalog).map(\.id)
        XCTAssertEqual(visible, ["news-1", "sports-1"],
                       "Category members and the same streams listed elsewhere are hidden")

        // All Channels, category browsing, Favorites, search and TV Guide all filter the same input.
        let favorites: Set<String> = ["nfhs-1", "sports-101", "news-1"]
        let input = policy.visibleChannels(catalog)
        XCTAssertEqual(LiveTVChannelFiltering.filter(input, query: "", category: nil, favoritesOnly: false,
                                                     favoriteIDs: []).map(\.id), ["news-1", "sports-1"])
        XCTAssertEqual(LiveTVChannelFiltering.filter(input, query: "", category: "Sports", favoritesOnly: false,
                                                     favoriteIDs: []).map(\.id), ["sports-1"])
        XCTAssertEqual(LiveTVChannelFiltering.filter(input, query: "", category: nil, favoritesOnly: true,
                                                     favoriteIDs: favorites).map(\.id), ["news-1"])
        XCTAssertEqual(LiveTVChannelFiltering.filter(input, query: "channel nfhs", category: nil, favoritesOnly: false,
                                                     favoriteIDs: []).count, 0)
        XCTAssertEqual(policy.categoryCounts(catalog), ["News": 1, "Sports": 1])
        XCTAssertEqual(policy.visibleCategories(["NFHS Network", "News", "Sports"]), ["News", "Sports"])
        // Stale search results or caches pass through the same rule before display.
        XCTAssertEqual(policy.visibleChannels([catalog[0], catalog[5]]).map(\.id), ["news-1"])
        XCTAssertEqual(catalog.count, 7, "Hiding never deletes catalog records")
    }

    func testNewlyImportedChannelsInAHiddenCategoryStayHidden() {
        var snapshot = TVLiveTVVisibilitySnapshot()
        snapshot.categories = ["NFHS Network"]
        let refreshed = catalog + [stream("nfhs-new", category: "NFHS Network", streamID: 999)]
        let policy = TVLiveTVVisibilityPolicy(snapshot: snapshot, catalog: refreshed)
        XCTAssertFalse(policy.isVisible(refreshed.last!))
    }

    func testChannelAndCategoryRulesStayIndependentWhenRestoring() {
        let defaults = UserDefaults(suiteName: "kyro-visibility-\(UUID().uuidString)")!
        let store = TVLiveTVVisibilityStore(defaults: defaults)
        let scope = TVLiveTVVisibilityScope(profileID: "profile-A", providerID: UUID())
        store.hide(catalog[1], in: scope)               // nfhs-2 hidden on its own
        store.hideCategory("NFHS Network", in: scope)
        store.hideCategory("Sports", in: scope)

        store.restoreCategory("NFHS Network", in: scope)
        var policy = TVLiveTVVisibilityPolicy(snapshot: store.snapshot(for: scope), catalog: catalog)
        XCTAssertTrue(policy.isVisible(catalog[3]), "Restoring a category returns its channels")
        XCTAssertFalse(policy.isVisible(catalog[1]), "An individually hidden channel stays hidden")
        XCTAssertFalse(policy.isVisible(catalog[2]), "Still hidden by the other hidden category")
        XCTAssertFalse(policy.isVisible(catalog[0]), "Its stream is also listed under hidden Sports")

        store.restoreAll(in: scope)
        policy = TVLiveTVVisibilityPolicy(snapshot: store.snapshot(for: scope), catalog: catalog)
        XCTAssertEqual(policy.visibleChannels(catalog).count, catalog.count)
    }

    func testHiddenCategoryRulesSurviveRestartAndStayScoped() {
        let defaults = UserDefaults(suiteName: "kyro-visibility-\(UUID().uuidString)")!
        let provider = UUID()
        let scope = TVLiveTVVisibilityScope(profileID: "profile-A", providerID: provider)
        TVLiveTVVisibilityStore(defaults: defaults).hideCategory("NFHS Network", in: scope)
        let reloaded = TVLiveTVVisibilityStore(defaults: defaults)
        XCTAssertEqual(TVLiveTVVisibilityPolicy(snapshot: reloaded.snapshot(for: scope), catalog: catalog)
            .visibleChannels(catalog).map(\.id), ["news-1", "sports-1"])
        let otherProfile = TVLiveTVVisibilityScope(profileID: "profile-B", providerID: provider)
        XCTAssertEqual(TVLiveTVVisibilityPolicy(snapshot: reloaded.snapshot(for: otherProfile), catalog: catalog)
            .visibleChannels(catalog).count, catalog.count)
    }

    func testEmptyRulesReturnTheCatalogUnchanged() {
        let policy = TVLiveTVVisibilityPolicy(snapshot: .init(), catalog: catalog)
        XCTAssertEqual(policy.visibleChannels(catalog), catalog)
    }
}
#endif
