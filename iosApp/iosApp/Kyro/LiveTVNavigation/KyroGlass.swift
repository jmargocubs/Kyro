import SwiftUI

/// Kyro's clear dark glass: native material with a crimson tint,
/// with a thin silver rim. Reduce Transparency swaps the material for an
/// opaque fill. iOS 18 APIs only.
private struct KyroGlassBackground<S: InsettableShape>: ViewModifier {
    let shape: S
    var glow: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    #if os(iOS)
    private let appearance = KyroAppAppearanceStore.shared
    #endif

    private var opaqueFill: Color {
        #if os(iOS)
        if appearance.selection == .signature { return KyroSignature.navigation }
        #endif
        return KyroTheme.glassOpaque
    }

    private var wash: Color {
        #if os(iOS)
        if appearance.selection == .signature { return KyroSignature.burgundy.opacity(0.62) }
        #endif
        return KyroTheme.glassTint
    }

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    if reduceTransparency {
                        shape.fill(opaqueFill)
                    } else {
                        shape.fill(.ultraThinMaterial)
                        shape.fill(LinearGradient(colors: [wash, Color.black.opacity(0.38)],
                                                  startPoint: .top, endPoint: .bottom))
                    }
                    shape.strokeBorder(KyroTheme.glassRim, lineWidth: 1)
                }
                .environment(\.colorScheme, .dark)
                .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
                .shadow(color: KyroTheme.accent.opacity(glow ? 0.4 : 0.16), radius: 20)
            }
    }
}

extension View {
    func kyroGlass<S: InsettableShape>(_ shape: S, glow: Bool = false) -> some View {
        modifier(KyroGlassBackground(shape: shape, glow: glow))
    }
}
