import SwiftUI
import UIKit

/// Approved independent Kyro X artwork and Crimson Noir brand surfaces.
/// The original Silo content theme and upstream attribution remain unchanged.
enum KyroBrand {
    static let wordmarkImageName = "KyroXWordmark"
    static let logoImageName = "KyroXLogo"

    /// Preserve the introduction's existing portrait layout coordinates.
    static let backdropPixelSize = CGSize(width: 1320, height: 2868)
    /// Approved wordmark aspect, glow padding included.
    static let wordmarkAspect: CGFloat = 500.0 / 1850.0

    // Crimson Noir palette from the independent Kyro X theme. Brand surfaces only;
    // Silo's content, controls and user-selected theme keep their existing colors.
    static let blue = Color(hex: "#8C263B")
    static let violet = Color(hex: "#B53B4D")
    static let pink = Color(hex: "#F06A7C")
    static let orange = Color(hex: "#8C263B")

    /// Existing introduction symbols now use the approved crimson palette.
    static let haloGradient = LinearGradient(
        colors: [blue, violet, pink, orange],
        startPoint: .leading,
        endPoint: .trailing
    )

    /// The cinematic splash and the introduction are drawn for the
    /// approved portrait iPhone artwork. iPad, Apple TV and Mac keep the
    /// existing Silo startup.
    @MainActor
    static var usesCinematicStartup: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }
}

/// Maps points in the backdrop artwork to the screen, matching the
/// aspect-fill crop `KyroBackdrop` draws with.
struct KyroBackdropGeometry {
    let container: CGSize

    private var scale: CGFloat {
        let art = KyroBrand.backdropPixelSize
        guard art.width > 0, art.height > 0 else { return 1 }
        return max(container.width / art.width, container.height / art.height)
    }

    /// The artwork's rendered size on screen.
    var renderedSize: CGSize {
        CGSize(
            width: KyroBrand.backdropPixelSize.width * scale,
            height: KyroBrand.backdropPixelSize.height * scale
        )
    }

    /// Screen y for a fraction of the artwork's height.
    func y(_ fraction: CGFloat) -> CGFloat {
        let overflow = (renderedSize.height - container.height) / 2
        return fraction * renderedSize.height - overflow
    }

    /// Screen length for a fraction of the artwork's width.
    func width(_ fraction: CGFloat) -> CGFloat {
        fraction * renderedSize.width
    }
}

/// Background presentation reused from independent KyroStartupView, using
/// its Crimson Noir palette rather than importing the universal app theme.
struct KyroBackdrop: View {
    var body: some View {
        ZStack {
            Color(red: 16.0 / 255, green: 9.0 / 255, blue: 12.0 / 255)
            RadialGradient(colors: [KyroBrand.blue.opacity(0.28), .clear],
                           center: .init(x: 0.76, y: 0.36), startRadius: 4, endRadius: 280)
            RadialGradient(colors: [KyroBrand.violet.opacity(0.16), .clear],
                           center: .init(x: 0.2, y: 0.72), startRadius: 4, endRadius: 300)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// The metallic KYRO wordmark, with an optional single shimmer pass. The
/// shimmer is a soft highlight masked to the letters that crosses once
/// when `shimmerProgress` animates from 0 to 1, then rests off the mark.
struct KyroWordmark: View {
    var shimmerProgress: CGFloat = 1

    var body: some View {
        Image(KyroBrand.wordmarkImageName)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    let band = proxy.size.width * 0.35
                    LinearGradient(
                        colors: [.white.opacity(0), .white.opacity(0.55), .white.opacity(0)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: band)
                    .rotationEffect(.degrees(18))
                    .offset(x: -band + (proxy.size.width + band) * shimmerProgress)
                    .blendMode(.plusLighter)
                }
                .mask {
                    Image(KyroBrand.wordmarkImageName)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
                .allowsHitTesting(false)
            }
            .accessibilityLabel("Kyro X")
    }
}

/// A soft bloom over the halo's rim, for the splash's single breath.
struct KyroHaloBloom: View {
    let geometry: KyroBackdropGeometry
    var intensity: Double

    var body: some View {
        RadialGradient(
            colors: [
                KyroBrand.violet.opacity(0.32 * intensity),
                KyroBrand.blue.opacity(0.14 * intensity),
                .clear,
            ],
            center: UnitPoint(x: 0.5, y: geometry.y(0.40) / max(geometry.container.height, 1)),
            startRadius: 0,
            endRadius: geometry.width(0.62)
        )
        .blendMode(.plusLighter)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
