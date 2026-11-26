import SwiftUI

/// Plain canvas shared by the native Settings experiences, so grouped rows
/// and focus platters carry all of the contrast. Black on iOS and tvOS; the
/// Mac uses its page canvas so Settings matches every other page.
struct SettingsBackdrop: View {
    #if os(iOS)
    private let appearance = KyroAppAppearanceStore.shared
    #endif

    var body: some View {
        #if os(macOS)
        SiloPageBackdrop()
        #elseif os(iOS)
        if appearance.selection == .signature {
            KyroSignatureBackdrop(finish: .dense)
        } else {
            Color.siloBackground.ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
        }
        #else
        Color.siloBackground
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        #endif
    }
}
