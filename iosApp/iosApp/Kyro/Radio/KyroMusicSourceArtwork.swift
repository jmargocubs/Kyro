#if os(iOS) || KYRO_STANDALONE_TESTS
/// Local identities, not official logos. No logo license or external art
/// service is required. nil is the existing Internet Radio card.
struct KyroMusicSourceArtwork: Equatable {
    let highlight: UInt32
    let shadow: UInt32
    let accent: UInt32
    let symbol: String

    static func style(for collection: KyroMusicCollection?) -> Self {
        switch collection {
        case nil: .init(highlight: 0xAE1939, shadow: 0x250A16, accent: 0xFFABBA, symbol: "radio")
        case .siriusXM: .init(highlight: 0x284CAA, shadow: 0x07142D, accent: 0xA7E2FF, symbol: "dot.radiowaves.left.and.right")
        case .musicChoice: .init(highlight: 0x713BA3, shadow: 0x24153C, accent: 0xF6A5F8, symbol: "music.note.list")
        case .stingray: .init(highlight: 0x007E79, shadow: 0x082E32, accent: 0x8CF5D8, symbol: "waveform")
        case .otherRadio: .init(highlight: 0x8C581C, shadow: 0x321C15, accent: 0xFFE0A1, symbol: "antenna.radiowaves.left.and.right")
        case .otherMusic: .init(highlight: 0x315C48, shadow: 0x101E2B, accent: 0xD0EEA2, symbol: "music.note")
        }
    }
}
#endif

#if os(iOS)
import SwiftUI

struct KyroMusicSourceCover: View {
    let style: KyroMusicSourceArtwork

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        let accent = color(style.accent)
        shape
            .fill(LinearGradient(colors: [color(style.highlight), color(style.shadow)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(alignment: .bottomTrailing) {
                ForEach(0..<3) { ring in
                    Circle().strokeBorder(accent.opacity(0.25 - 0.05 * Double(ring)), lineWidth: 1)
                        .frame(width: 78 + 25 * CGFloat(ring), height: 78 + 25 * CGFloat(ring))
                        .offset(x: 40, y: 42)
                }
            }
            .overlay {
                Image(systemName: style.symbol)
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 78, height: 78)
                    .background(.black.opacity(0.19), in: .circle)
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(KyroSignature.border))
            .frame(width: 132, height: 132)
            .accessibilityHidden(true)
    }

    private func color(_ rgb: UInt32) -> Color {
        Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255,
              blue: Double(rgb & 255) / 255)
    }
}
#endif
