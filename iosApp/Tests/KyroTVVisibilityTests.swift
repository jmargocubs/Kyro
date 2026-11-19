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
        XCTAssertEqual(snapshot.visibleChannels([channel("one"), channel("two")]).map(\.id), ["two"])
        XCTAssertTrue(reloaded.snapshot(for: .init(profileID: "profile-B", providerID: provider)).hiddenChannelIDs.isEmpty)
        XCTAssertTrue(reloaded.snapshot(for: .init(profileID: "profile-A", providerID: UUID())).hiddenChannelIDs.isEmpty)
    }

    func testHidingCategoryDoesNotHideItsChannelsAndRestoreAllIsScoped() {
        let defaults = UserDefaults(suiteName: "kyro-visibility-\(UUID().uuidString)")!
        let store = TVLiveTVVisibilityStore(defaults: defaults)
        let provider = UUID()
        let first = TVLiveTVVisibilityScope(profileID: "one", providerID: provider)
        let second = TVLiveTVVisibilityScope(profileID: "two", providerID: provider)
        store.hideCategory("News", in: first)
        store.hide(channel("other"), in: second)
        XCTAssertEqual(store.snapshot(for: first).visibleChannels([channel("one")]).count, 1)
        XCTAssertTrue(store.snapshot(for: first).visibleCategories(["News"]).isEmpty)
        store.restoreAll(in: first)
        XCTAssertEqual(store.snapshot(for: first).visibleCategories(["News"]), ["News"])
        XCTAssertTrue(store.snapshot(for: second).hiddenChannelIDs.contains("other"))
    }
}
#endif
