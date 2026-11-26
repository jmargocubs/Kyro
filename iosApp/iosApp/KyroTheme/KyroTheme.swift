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

#if os(iOS)
/// The approved Build 135 Podcast finish, shared by app presentation only.
/// Player themes use the same pigments without observing app appearance.
enum KyroSignature {
    static let crimson = Color(red: 0.90, green: 0.14, blue: 0.23)
    static let crimsonDeep = Color(red: 0.56, green: 0.055, blue: 0.12)
    static let burgundy = Color(red: 0.23, green: 0.03, blue: 0.06)
    static let night = Color(red: 0.04, green: 0.016, blue: 0.024)
    static let card = Color(red: 0.17, green: 0.035, blue: 0.06)
    static let ink = KyroTheme.accentInk
    static let primary = Color.white
    static let secondary = Color.white.opacity(0.76)
    static let border = Color.white.opacity(0.16)
    static let separator = Color.white.opacity(0.12)
    static let navigation = card
    static let button = crimsonDeep
    static let search = Color.white.opacity(0.08)
    static let selected = crimsonDeep
    static let discovery = LinearGradient(stops: [
        .init(color: crimsonDeep, location: 0), .init(color: burgundy, location: 0.45),
        .init(color: night, location: 1)
    ], startPoint: .top, endPoint: .bottom)
    static let spotlight = RadialGradient(colors: [crimson.opacity(0.32), .clear], center: .top,
                                           startRadius: 0, endRadius: 380)
    static let feature = LinearGradient(stops: [
        .init(color: burgundy, location: 0), .init(color: card, location: 0.35),
        .init(color: night, location: 0.85)
    ], startPoint: .top, endPoint: .bottom)
    static let dense = LinearGradient(colors: [card, night, night], startPoint: .top, endPoint: .bottom)
}

enum KyroPageFinish { case dense, feature, discovery }

struct KyroSignatureBackdrop: View {
    var finish: KyroPageFinish

    var body: some View {
        Group {
            switch finish {
            case .dense: KyroSignature.dense
            case .feature: KyroSignature.feature
            case .discovery: KyroSignature.discovery.overlay { KyroSignature.spotlight }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Shared button/search chrome. A leaf reader, not a shell preference.
struct KyroControlSurface: View {
    var selected = false
    var cornerRadius: CGFloat = 14
    private let appearance = KyroAppAppearanceStore.shared

    var body: some View {
        let signature = appearance.selection == .signature
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        shape.fill(selected ? (signature ? KyroSignature.selected : KyroTheme.selectedFill)
                            : (signature ? KyroSignature.search : Color.siloChromeRestingFill))
            .overlay(shape.strokeBorder(signature ? KyroSignature.border : Color.siloChromeRestingBorder))
    }
}

struct KyroAppAppearancePicker: View {
    private let appearance = KyroAppAppearanceStore.shared

    var body: some View {
        Picker("App Appearance", selection: Binding(get: { appearance.selection }, set: appearance.select)) {
            ForEach(KyroAppAppearance.allCases) { Text($0.title).tag($0) }
        }
        .accessibilityIdentifier("kyroAppAppearance")
    }
}
#endif
