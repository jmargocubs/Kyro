import SwiftUI

/// Where Kyro's Live TV entry points lead. With the unified navigation
/// prototype on (iPhone, `KyroUnifiedNavigation`), Live TV is a tab and is
/// never pushed, so exactly one Live TV screen exists. Otherwise Live TV is
/// pushed onto the main stack, as in Build 17.
@MainActor
enum KyroLiveTVEntry {
    /// The profile menu's Live TV item.
    static func open(router: AppRouter) {
        #if os(iOS)
        if KyroUnifiedNavigation.isActive {
            KyroGlobalNavigationStore.shared.selectedDestination = .liveTV
            return
        }
        #endif
        router.navigate(to: .liveTV)
    }

    /// Picture in Picture needs a Live TV screen to put the player on.
    static func bringForward(router: AppRouter) {
        #if os(iOS)
        if KyroUnifiedNavigation.isActive {
            KyroUnifiedNavigation.bringLiveTVForward(router: router)
            return
        }
        #endif
        router.navigate(to: .liveTV)
    }
}
