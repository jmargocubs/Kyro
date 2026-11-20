#if os(tvOS)
import SwiftUI

/// A disabled control cannot take focus on tvOS, so it must also look
/// unavailable: otherwise a row that Down skips reads as a broken remote.
/// Every custom tvOS button style applies this; `TVKyroChipStyle` uses the
/// same 0.45 opacity.
struct TVDisabledAppearance: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    func body(content: Content) -> some View {
        content.opacity(isEnabled ? 1 : 0.45)
    }
}

extension View {
    func tvDisabledAppearance() -> some View { modifier(TVDisabledAppearance()) }

    /// A read-only row that takes focus so the remote can scroll through it
    /// (statistics, news, loading text). Bare `.focusable()` draws nothing on
    /// tvOS, which reads as a remote that stopped responding. The ring sits
    /// outside the row's bounds, so layout does not change.
    func tvReadableRowFocus(cornerRadius: CGFloat = 14) -> some View {
        modifier(TVReadableRowFocus(cornerRadius: cornerRadius))
    }
}

struct TVReadableRowFocus: ViewModifier {
    let cornerRadius: CGFloat
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(isFocused ? 0.10 : 0))
                    .padding(-10)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(TVKyroFocus.ring, lineWidth: TVKyroFocus.ringWidth)
                    .padding(-10)
                    .opacity(isFocused ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: TVKyroFocus.duration), value: isFocused)
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
    }
}

/// Kyro's Siri Remote focus treatment for Live TV, the guide, Sports and provider screens.
///
/// Focus is shown by shape and size as well as color: a thick bright-cyan ring with a dark inner
/// keyline (readable on light artwork and dark surfaces alike), a small lift and a shadow.
/// Selected items use a filled background and a checkmark; the playing item uses a labelled
/// badge. The three states never share a cue, so they stay distinguishable without color.
enum TVKyroFocus {
    /// Bright cyan, about 12:1 against Kyro's black page.
    static let ring = Color(hex: "#22E5FF")
    static let ringWidth: CGFloat = 4
    static let keyline = Color.black.opacity(0.85)
    static let keylineWidth: CGFloat = 2
    static let selectedFill = KyroTheme.accent.opacity(0.42)
    static let duration: Double = 0.12

    enum Role: Equatable {
        case card
        case chip
    }

    /// Lift for each role, kept small so dense grids do not overlap their neighbours.
    static func scale(for role: Role, focused: Bool, reduceMotion: Bool) -> CGFloat {
        guard focused, !reduceMotion else { return 1 }
        switch role {
        case .card: return 1.04
        case .chip: return 1.06
        }
    }
}

/// The ring itself, drawn on top of the content so it is never clipped by the content's own shape.
private struct TVKyroFocusRing: View {
    let cornerRadius: CGFloat
    let isFocused: Bool

    var body: some View {
        if isFocused {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(TVKyroFocus.ring, lineWidth: TVKyroFocus.ringWidth)
                RoundedRectangle(cornerRadius: max(cornerRadius - TVKyroFocus.ringWidth, 0), style: .continuous)
                    .strokeBorder(TVKyroFocus.keyline, lineWidth: TVKyroFocus.keylineWidth)
                    .padding(TVKyroFocus.ringWidth)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// Cards, program cells, channel rows and list rows. The label supplies its own background.
struct TVKyroCardFocusStyle: ButtonStyle {
    var cornerRadius: CGFloat = 16

    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration, cornerRadius: cornerRadius)
    }

    private struct StyledBody: View {
        let configuration: ButtonStyleConfiguration
        let cornerRadius: CGFloat
        @Environment(\.isFocused) private var isFocused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .overlay { TVKyroFocusRing(cornerRadius: cornerRadius, isFocused: isFocused) }
                .scaleEffect(TVKyroFocus.scale(for: .card, focused: isFocused, reduceMotion: reduceMotion)
                             * (configuration.isPressed ? 0.98 : 1))
                .shadow(color: .black.opacity(isFocused ? 0.55 : 0.25), radius: isFocused ? 18 : 6, y: isFocused ? 8 : 3)
                .zIndex(isFocused ? 1 : 0)
                .focusEffectDisabled()
                .animation(.easeOut(duration: TVKyroFocus.duration), value: isFocused)
        }
    }
}

/// Filters, sections, tabs and toolbar-style buttons: a capsule with text and an optional icon.
/// `isSelected` fills it and prefixes a checkmark, so a selected chip reads differently from a
/// focused one even in grayscale.
struct TVKyroChipStyle: ButtonStyle {
    var isSelected = false
    var isDestructive = false
    var fontSize: CGFloat = 24
    var minHeight: CGFloat = 58
    var horizontalPadding: CGFloat = 24

    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration, isSelected: isSelected, isDestructive: isDestructive,
                   fontSize: fontSize, minHeight: minHeight, horizontalPadding: horizontalPadding)
    }

    private struct StyledBody: View {
        let configuration: ButtonStyleConfiguration
        let isSelected: Bool
        let isDestructive: Bool
        let fontSize: CGFloat
        let minHeight: CGFloat
        let horizontalPadding: CGFloat
        @Environment(\.isFocused) private var isFocused
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            HStack(spacing: 10) {
                if isSelected {
                    Image(systemName: "checkmark").font(.system(size: 20, weight: .heavy))
                }
                configuration.label
            }
            .font(.system(size: fontSize, weight: isSelected || isFocused ? .bold : .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, horizontalPadding)
            .frame(minHeight: minHeight)
            .background(background, in: Capsule())
            .overlay {
                if isFocused {
                    Capsule().strokeBorder(TVKyroFocus.ring, lineWidth: TVKyroFocus.ringWidth)
                    Capsule().strokeBorder(TVKyroFocus.keyline, lineWidth: TVKyroFocus.keylineWidth)
                        .padding(TVKyroFocus.ringWidth)
                }
            }
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(TVKyroFocus.scale(for: .chip, focused: isFocused, reduceMotion: reduceMotion)
                         * (configuration.isPressed ? 0.97 : 1))
            .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: 12, y: 6)
            .zIndex(isFocused ? 1 : 0)
            .focusEffectDisabled()
            .animation(.easeOut(duration: TVKyroFocus.duration), value: isFocused)
        }

        private var foreground: Color {
            if isDestructive { return isFocused ? .white : KyroTheme.live }
            return .white
        }

        private var background: Color {
            if isFocused { return isSelected ? KyroTheme.accent : Color.white.opacity(0.22) }
            return isSelected ? TVKyroFocus.selectedFill : Color.white.opacity(0.08)
        }
    }
}

/// A labelled "PLAYING" badge for whatever the shared player is tuned to. Text plus an icon, so
/// it never relies on color.
struct TVKyroPlayingBadge: View {
    var body: some View {
        Label("PLAYING", systemImage: "play.fill")
            .font(.system(size: 15, weight: .black))
            .foregroundStyle(.black)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.white, in: Capsule())
            .accessibilityLabel("Now playing")
    }
}
#endif
