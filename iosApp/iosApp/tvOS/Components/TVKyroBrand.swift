#if os(tvOS)
import SwiftUI

/// Kyro's television brand treatment. It reuses the approved metallic
/// wordmark, but composes it against a restrained 16:9 halo instead of
/// stretching the portrait iPhone splash artwork onto a television.
struct TVKyroWordmarkView: View {
    var width: CGFloat

    var body: some View {
        Image("KyroTVWordmark")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: width)
            .accessibilityLabel(AppBrand.name)
    }
}

/// A low-energy brand wash shared by Home's ambient hero plane and Settings.
/// Media artwork remains the dominant color source; this only keeps empty and
/// loading states from falling back to an unrelated flat Silo canvas.
struct TVKyroAmbientBackdrop: View {
    var body: some View {
        ZStack {
            KyroTheme.background

            RadialGradient(
                colors: [KyroTheme.depth.opacity(0.48), .clear],
                center: UnitPoint(x: 0.18, y: 0.08),
                startRadius: 0,
                endRadius: 820
            )

            RadialGradient(
                colors: [KyroTheme.live.opacity(0.09), KyroTheme.highlight.opacity(0.04), .clear],
                center: UnitPoint(x: 0.92, y: 0.94),
                startRadius: 0,
                endRadius: 700
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Native TV startup presentation. The app continues its existing startup
/// work underneath and uses the same completion contract as the legacy splash.
struct TVKyroStartupSplashView: View {
    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false
    @State private var glowScale: CGFloat = 0.92

    var body: some View {
        ZStack {
            TVKyroAmbientBackdrop()

            EllipticalGradient(
                colors: [KyroTheme.accentInk.opacity(0.22), KyroTheme.depth.opacity(0.12), .clear],
                center: .center,
                endRadiusFraction: 0.48
            )
            .scaleEffect(glowScale)
            .blendMode(.plusLighter)

            TVKyroWordmarkView(width: 540)
                .opacity(isVisible ? 1 : 0)
                .scaleEffect(isVisible || reduceMotion ? 1 : 0.96)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading Kyro")
        .task { await play() }
    }

    private func play() async {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.65)) {
            isVisible = true
            glowScale = 1.04
        }
        try? await Task.sleep(for: reduceMotion ? .milliseconds(700) : .milliseconds(1500))
        guard !Task.isCancelled else { return }
        onFinished()
    }
}
#endif
