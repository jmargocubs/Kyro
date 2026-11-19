#if os(tvOS)
import SwiftUI

/// Shared page geometry for tvOS root pages (Build 99).
///
/// Apple TV lays out every display at 1920×1080 points. The system safe area is 60 pt at the top
/// and bottom and 80 pt at the sides (a 1760×960 viewport), which keeps text clear of TV
/// overscan. The shell ignores the top and side safe areas so the menu bar and backdrops reach
/// the edges; pages then place their own content.
///
/// Build 98 and earlier stacked padding on top of the safe area: a 188 pt top inset (68 pt of air
/// under a bar that ends at 120 pt), 38 pt of bottom padding above the 60 pt bottom safe area, and
/// scroll views clipped at that 98 pt line, so the last grid row was cut off with empty screen
/// below it. Here, text and resting content still respect the safe area, but scroll views run
/// to the screen's side and bottom edges, and their content margins hold the resting position
/// inside the safe area. Rows scrolling past show through the overscan band instead of
/// stopping at a hard edge, and a focused card's lift, ring and shadow are never clipped.
enum TVScreenLayout {
    /// The 1080p layout canvas every Apple TV uses.
    static let referenceScreen = CGSize(width: 1920, height: 1080)
    /// The system safe area at `referenceScreen`. Text and resting content stay inside it.
    static let overscan = EdgeInsets(top: 60, leading: 80, bottom: 60, trailing: 80)

    /// Page side inset, equal to the side safe area. Build 98 used 72, 80 and 88 on different pages.
    static let pageHorizontalInset: CGFloat = overscan.leading
    /// Clearance under the top menu bar (it ends at `barTopInset + barHeight` = 120 pt).
    static let menuBarClearance: CGFloat = 28
    /// Top of page content on root pages without a hero.
    static let contentTopInset: CGFloat =
        SiloTheme.Skyline.barTopInset + SiloTheme.Skyline.barHeight + menuBarClearance
    /// Room for a focused card: the 1.04 lift, the 4 pt ring and the 18 pt shadow at y + 8.
    static let focusRoom: CGFloat = 26
    /// Space between page sections (header, control row, content).
    static let sectionSpacing: CGFloat = 18

    /// Bottom content margin for a scroll view that runs to the bottom edge of the screen. The
    /// last row comes to rest above the bottom safe area with room for its focus lift.
    /// `measuredOverscan` is the safe-area inset the scroll view extends through; the system value
    /// is the floor so a missing measurement can never park content in the overscan band.
    static func scrollBottomMargin(measuredOverscan: CGFloat) -> CGFloat {
        max(measuredOverscan, overscan.bottom) + focusRoom
    }

    /// The column count SwiftUI's adaptive grid item produces for a width: as many minimum-width
    /// columns as fit, never fewer than one. Used by tests to pin the counts each page shows.
    static func adaptiveColumnCount(width: CGFloat, minimum: CGFloat, spacing: CGFloat) -> Int {
        guard width > 0, minimum > 0 else { return 1 }
        return max(1, Int(((width + spacing) / (minimum + spacing)).rounded(.down)))
    }
}

/// A vertical page scroll view that reaches the screen edges while its content rests inside the
/// safe area. Apply it to the `ScrollView` itself, not to a parent stack.
///
/// - `horizontalBleed`: how far the page's own side padding should be undone. The scroll view
///   widens by that much on each side and gives it back as content margin, so cards stay aligned
///   with the page while a focused card in the first or last column has room to lift.
/// - The bottom safe area is ignored for this scroll view only. Its content margin restores the
///   resting position (`TVScreenLayout.scrollBottomMargin`).
struct TVEdgeToEdgeScroll: ViewModifier {
    var horizontalBleed: CGFloat = 0
    var topRoom: CGFloat = TVScreenLayout.focusRoom
    @State private var measuredOverscan: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .contentMargins(.horizontal, horizontalBleed, for: .scrollContent)
            .contentMargins(.top, topRoom, for: .scrollContent)
            .contentMargins(.bottom, TVScreenLayout.scrollBottomMargin(measuredOverscan: measuredOverscan),
                            for: .scrollContent)
            .padding(.horizontal, -horizontalBleed)
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { measuredOverscan = $0 }
            .ignoresSafeArea(.container, edges: .bottom)
    }
}

extension View {
    func tvEdgeToEdgeScroll(horizontalBleed: CGFloat = 0,
                            topRoom: CGFloat = TVScreenLayout.focusRoom) -> some View {
        modifier(TVEdgeToEdgeScroll(horizontalBleed: horizontalBleed, topRoom: topRoom))
    }
}
#endif
