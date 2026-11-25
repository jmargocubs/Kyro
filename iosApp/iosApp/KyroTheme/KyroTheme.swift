import SwiftUI

/// Kyro X's approved Crimson Noir palette as semantic roles (Build 121; it
/// replaces the C3 electric blue). Live TV, Kyro's floating navigation and
/// glass, Sports Hub, Home controls and the iPhone app shell all draw from
/// here, so Media Server and Live TV read as one app. Values come from the
/// independent Kyro X theme (`KyroThemePalette.crimsonNoir`).
///
/// Kyro-owned and platform-neutral (it sits outside `Kyro/`, which only the
/// iOS target builds), because Live TV also compiles for tvOS and macOS.
/// These are Kyro tokens, not upstream ones. Artwork, channel logos and provider branding are never
/// tinted with these, and the warning, error and success colours stay Silo's.
enum KyroTheme {
    // MARK: Brand values

    /// Crimson (`accent`): filled controls with white content (white on it 8.6:1).
    static let accent = Color(hex: "#8C263B")
    /// Crimson Noir highlight for text, icons, tints and thin indicators on
    /// black (7.1:1 on black, 4.6:1 on #2C2C2E). `accent` itself is too dark
    /// for text on black.
    static let accentInk = Color(hex: "#F06A7C")
    /// Crimson Noir secondary accent: selected fills and gradients.
    static let secondary = Color(hex: "#B53B4D")
    /// Deep crimson for glass depth and glows.
    static let depth = Color(hex: "#4A1424")
    /// Pink-red, reserved for LIVE.
    static let live = Color(hex: "#F50B4F")
    /// Orange, a restrained secondary highlight (favorites). Never navigation.
    static let highlight = Color(hex: "#FD7403")

    // MARK: Surfaces

    /// Cinematic black.
    static let background = Color(hex: "#000000")
    /// Opaque glass for Reduce Transparency: Crimson Noir surface.
    static let glassOpaque = Color(hex: "#1F0E14")
    /// The crimson cast laid over clear-glass material.
    static let glassTint = depth.opacity(0.42)
    /// Metallic silver rim shared by every Kyro glass edge.
    static let glassRim = LinearGradient(colors: [Color.white.opacity(0.42), Color.white.opacity(0.08),
                                                  accentInk.opacity(0.3)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)

    // MARK: Text

    /// Primary text and icons: white.
    static let textPrimary = Color.white
    /// Crimson Noir secondary text (9.4:1 on black).
    static let textSecondary = Color(hex: "#C7A5AA")
    /// Metallic silver for brand marks and resting icons.
    static let silver = Color(hex: "#E4E8F0")

    // MARK: Selection

    /// Fill behind a selected chip or pill.
    static let selectedFill = secondary.opacity(0.38)
    /// Border of a selected chip or pill.
    static let selectedBorder = accentInk.opacity(0.55)
    /// The active destination's gradient in Kyro's navigation.
    static let activeGradient = LinearGradient(colors: [secondary, accent], startPoint: .top, endPoint: .bottom)

    /// The interactive tint for the app shell: crimson ink on iPhone and
    /// iPad, Silo's near-white elsewhere (Apple TV focus and the Mac keep theirs).
    static var shellTint: Color {
        #if os(iOS)
        accentInk
        #else
        Color.siloOnSurface
        #endif
    }
}
