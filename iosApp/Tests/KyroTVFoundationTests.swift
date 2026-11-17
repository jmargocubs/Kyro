#if os(tvOS)
import XCTest
@testable import Silo

final class KyroTVFoundationTests: XCTestCase {
    func testPhaseTwoMenuExposesReadyKyroDestinations() {
        let libraries = [
            Library(id: 1, name: "Movies", type: "movies", sortOrder: 0, posterUrl: nil),
            Library(id: 2, name: "Series", type: "series", sortOrder: 1, posterUrl: nil),
            Library(id: 3, name: "Music", type: "music", sortOrder: 2, posterUrl: nil),
        ]
        let stored: [PrimaryMenuItem] = [
            .builtin(.calendar),
            .builtin(.series),
            .builtin(.music),
            .builtin(.movies),
            .builtin(.forYou),
            .library(libraryId: 1, label: "Movie Library"),
        ]

        XCTAssertEqual(
            TVPrimaryMenuProjection.roots(for: stored, libraries: libraries),
            [.home, .libraryType(.series), .libraryType(.movies), .liveTV, .sports]
        )
    }

    func testUnavailableMediaRootsStayHidden() {
        XCTAssertEqual(
            TVPrimaryMenuProjection.roots(
                for: [.builtin(.movies), .builtin(.series)],
                libraries: []
            ),
            [.home, .liveTV, .sports]
        )
    }

    func testAppleTVUsesKyroIdentity() {
        XCTAssertEqual(AppBrand.name, "Kyro")
    }
}
#endif
