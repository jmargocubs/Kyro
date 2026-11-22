import Foundation

/// Kyro owns startup, local profiles and navigation. Silo is an optional media provider: its
/// setup, sign-in and Who's Watching screens are reachable when the person asks to connect Silo,
/// but they never gate entry to the app.
///
/// `RestoredSessionAuthResolver` still reports the Silo provider's own state (it also drives
/// explicit server switches, where "needs sign-in" must open sign-in). This policy maps that
/// state to the route Kyro shows when nobody asked for Silo.
enum KyroStartupPolicy {
    /// The first route of a cold launch. A missing server or a signed-out server enters Kyro's
    /// own profile picker; a signed-in Silo session keeps the existing Silo flow unchanged.
    static func launchRoute(forSilo state: AppRouter.AuthState) -> AppRouter.AuthState {
        switch state {
        case .needsServerSetup, .needsLogin:
            return .needsProfile
        case .loading, .serverRecovery, .needsProfile, .authenticated:
            return state
        }
    }

    /// Who's Watching shows Kyro's local profiles whenever no Silo session is signed in, even
    /// when a server is saved. Silo profiles appear only for a signed-in Silo account.
    static func usesLocalProfiles(isSiloSignedIn: Bool) -> Bool {
        !isSiloSignedIn
    }

    /// Where a Silo sign-out lands. Continuing straight to another sign-in (switching account or
    /// server) keeps Silo's login screen; a plain sign-out returns to Kyro.
    static func routeAfterSiloSignOut(
        hasActiveServer: Bool,
        continuesToSignIn: Bool
    ) -> AppRouter.AuthState {
        hasActiveServer && continuesToSignIn ? .needsLogin : .needsProfile
    }

    /// A Silo session that ended on its own asks to sign in again only while that server is still
    /// saved; Kyro's way back stays available from the setup screen.
    static func routeAfterSiloSessionExpired(hasActiveServer: Bool) -> AppRouter.AuthState {
        hasActiveServer ? .needsLogin : .needsProfile
    }

    /// Leaving Silo setup returns to Who's Watching: Kyro profiles, or the Silo profiles of a
    /// session that is still signed in.
    static let routeLeavingSiloSetup: AppRouter.AuthState = .needsProfile

    /// The local profile Kyro uses for requests when no Silo profile is selected. A Silo profile
    /// always wins, and a signed-in Silo session never borrows a local profile ID.
    static func activeProfileID(
        siloProfileID: String?,
        localProfileID: @autoclosure () -> String?,
        isSiloSignedIn: () -> Bool
    ) -> String? {
        if let siloProfileID { return siloProfileID }
        return isSiloSignedIn() ? nil : localProfileID()
    }
}
