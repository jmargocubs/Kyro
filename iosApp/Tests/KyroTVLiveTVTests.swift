#if os(tvOS)
import XCTest
@testable import Silo

@MainActor
final class KyroTVLiveTVTests: XCTestCase {
    private let channels = [
        LiveTVChannel(
            id: "news",
            guideID: "news-guide",
            name: "City News",
            streamURL: URL(string: "https://example.com/news.m3u8")!,
            logoURL: nil,
            category: "News"
        ),
        LiveTVChannel(
            id: "sports",
            guideID: "sports-guide",
            name: "Arena Sports",
            streamURL: URL(string: "https://example.com/sports.m3u8")!,
            logoURL: nil,
            category: "Sports"
        ),
    ]

    func testProviderConfigurationRetainsSupportedTypes() throws {
        let configurations = [
            LiveTVSourceConfiguration(
                playlistURL: "https://example.com/channels.m3u",
                xmltvURL: "https://example.com/guide.xml"
            ),
            LiveTVSourceConfiguration(
                playlistURL: nil,
                xmltvURL: nil,
                kind: .xtream,
                serverURL: "https://example.com",
                username: "viewer",
                password: "secret"
            ),
        ]

        let data = try JSONEncoder().encode(configurations)
        XCTAssertEqual(try JSONDecoder().decode([LiveTVSourceConfiguration].self, from: data), configurations)
    }

    func testChannelFilteringIntersectsSearchCategoryAndFavorites() {
        XCTAssertEqual(
            LiveTVChannelFiltering.filter(
                channels,
                query: "arena",
                category: "Sports",
                favoritesOnly: true,
                favoriteIDs: ["sports"]
            ).map(\.id),
            ["sports"]
        )
    }

    func testGuideFocusRestoresToFirstVisibleChannelWhenFilterRemovesSelection() {
        var state = TVLiveTVGuideNavigationState()
        state.focus(channelID: "sports")
        state.reconcile(visibleChannelIDs: ["news"])
        XCTAssertEqual(state.focusedChannelID, "news")
    }

    func testPlaybackSelectionKeepsOnePresentedGuideChannel() {
        let presentation = LiveTVPresentation(scheduler: LiveTVTaskScheduler())
        XCTAssertEqual(presentation.select(channels[0], from: .guide), .present)
        XCTAssertEqual(presentation.select(channels[1], from: .guide), .present)
        XCTAssertEqual(presentation.channel(for: .guide)?.id, "sports")
        XCTAssertNil(presentation.channel(for: .list))
    }

    func testLiveTVSectionsExposeOnlyWorkingDestinations() {
        XCTAssertEqual(TVLiveTVSection.allCases, [.channels, .categories, .favorites])
    }
}
#endif
