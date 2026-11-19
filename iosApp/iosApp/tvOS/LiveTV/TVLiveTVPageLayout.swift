#if os(tvOS)
import SwiftUI

/// Live TV page grid geometry (Build 99). Columns are adaptive, so a narrower viewport shows
/// fewer, equally sized cards instead of squeezing a fixed five.
enum TVLiveTVPageLayout {
    static let minimumCardWidth: CGFloat = 300
    static let columnSpacing: CGFloat = 28
    static let rowSpacing: CGFloat = 28
    static let channelRowSpacing: CGFloat = 32

    static let categoryColumns = [
        GridItem(.adaptive(minimum: minimumCardWidth, maximum: 460), spacing: columnSpacing)
    ]
    static let channelColumns = [
        GridItem(.adaptive(minimum: minimumCardWidth, maximum: 460), spacing: columnSpacing)
    ]

    /// Category card content height: a two-line 27 pt title over the 20 pt channel count. Every
    /// card uses it, so rows stay even whether a title wraps or not.
    static let categoryCardContentHeight: CGFloat = 96
    static let categoryCardPadding: CGFloat = 20
    static var categoryCardHeight: CGFloat { categoryCardContentHeight + 2 * categoryCardPadding }

    static func columnCount(width: CGFloat) -> Int {
        TVScreenLayout.adaptiveColumnCount(width: width, minimum: minimumCardWidth, spacing: columnSpacing)
    }
}

/// A category card's face. Build 98 stacked the icon above the title (about 190 pt tall); the
/// icon now leads the title, so the same text fits in a 136 pt card.
struct TVLiveTVCategoryCardLabel: View {
    let title: String
    let count: Int
    let isAllChannels: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            Image(systemName: isAllChannels ? "rectangle.stack" : "square.grid.2x2")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(KyroTheme.accentInk)
                .frame(width: 44, height: 40)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 27, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(count) channels")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.siloSecondaryText)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: TVLiveTVPageLayout.categoryCardContentHeight,
               maxHeight: TVLiveTVPageLayout.categoryCardContentHeight, alignment: .topLeading)
        .padding(TVLiveTVPageLayout.categoryCardPadding)
        .background(Color.siloSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
#endif
