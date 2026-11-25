import SwiftUI

/// Kyro X's startup splash (Build 121): one centred approved wordmark on the
/// Crimson Noir backdrop. "Kyro" fades up, then the crimson X swings into
/// place beside it, and the mark settles into the unmodified approved artwork.
/// It signals `onFinished` on the same contract as Silo's `StartupSplashView`:
/// it plays once over the app as the app builds underneath, then the shell
/// lifts it with a fade.
///
/// The two moving layers (`KyroXWordmarkKyro`, `KyroXWordmarkX`) are the
/// approved `KyroXWordmark` separated by colour with
/// `scripts/kyro-brand/split_wordmark.swift`; they share its canvas, so at rest
/// they sit exactly where the original draws, and the final frame is the
/// original image itself. No app icon, no second brand mark, no looping.
struct KyroCinematicSplashView: View {
    /// Long enough to read the mark, short enough not to hold anyone up.
    /// Silo's own splash runs 4 s; the app keeps loading underneath either way.
    static let displayDuration: Duration = .milliseconds(2000)
    static let reducedMotionDuration: Duration = .milliseconds(800)

    /// Where the X sits in the wordmark canvas (column ~1360 of 1825): it
    /// turns and scales about its own centre, not the word's.
    static let xAnchor = UnitPoint(x: 0.745, y: 0.5)

    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var backdropVisible = false
    @State private var kyroVisible = false
    @State private var xLanded = false
    /// The layered mark has been replaced by the single approved image.
    @State private var settled = false

    var body: some View {
        GeometryReader { proxy in
            let width = min(proxy.size.width * 0.74, 440)
            ZStack {
                Color(hex: "#10090C")

                KyroBackdrop()
                    .opacity(backdropVisible ? 1 : 0)

                ZStack {
                    layer("KyroXWordmarkKyro")
                        .opacity(kyroVisible ? 1 : 0)
                        .offset(y: kyroVisible ? 0 : 10)
                    layer("KyroXWordmarkX")
                        .scaleEffect(xLanded ? 1 : 1.55, anchor: Self.xAnchor)
                        .rotationEffect(.degrees(xLanded ? 0 : -28), anchor: Self.xAnchor)
                        .offset(x: xLanded ? 0 : width * 0.2)
                        .opacity(xLanded ? 1 : 0)
                }
                .opacity(settled ? 0 : 1)
                .frame(width: width)

                layer(KyroBrand.wordmarkImageName)
                    .frame(width: width)
                    .opacity(settled ? 1 : 0)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading Kyro X")
        .task { await play() }
    }

    private func layer(_ name: String) -> some View {
        Image(name)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
    }

    private func play() async {
        if reduceMotion {
            // No movement: the approved mark fades in once, in place.
            settled = true
            withAnimation(.easeOut(duration: 0.3)) { backdropVisible = true }
            try? await Task.sleep(for: Self.reducedMotionDuration)
        } else {
            let start = ContinuousClock.now
            withAnimation(.easeOut(duration: 0.6)) { backdropVisible = true }
            withAnimation(.easeOut(duration: 0.55).delay(0.15)) { kyroVisible = true }
            withAnimation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.55)) { xLanded = true }
            try? await Task.sleep(for: .milliseconds(1450))
            guard !Task.isCancelled else { return }
            // Identical pixels at rest, so this swap is invisible; it leaves
            // the original artwork on screen for the shell's fade-out.
            withAnimation(.easeInOut(duration: 0.2)) { settled = true }
            try? await Task.sleep(until: start + Self.displayDuration, clock: .continuous)
        }
        guard !Task.isCancelled else { return }
        onFinished()
    }
}
