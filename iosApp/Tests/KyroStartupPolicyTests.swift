import Foundation
import XCTest
@testable import Silo

/// Kyro owns startup; Silo is an optional provider (Kyro Labs device regression, 2026-11-22:
/// a saved but signed-out Silo server forced Connect to Server → Sign In → Who's Watching).
@MainActor
final class KyroStartupPolicyTests: XCTestCase {
    // MARK: Independent startup

    func testColdLaunchWithoutSiloEntersKyroProfiles() {
        // No server saved.
        XCTAssertEqual(KyroStartupPolicy.launchRoute(forSilo: .needsServerSetup), .needsProfile)
        // A saved server that is signed out (the recording's "Recent: Cubbiehub").
        XCTAssertEqual(KyroStartupPolicy.launchRoute(forSilo: .needsLogin), .needsProfile)
        XCTAssertTrue(KyroStartupPolicy.usesLocalProfiles(isSiloSignedIn: false))
    }

    func testColdLaunchNeverLandsOnASiloAuthScreen() {
        let siloStates: [AppRouter.AuthState] = [
            .needsServerSetup, .needsLogin, .needsProfile, .authenticated,
        ]
        for state in siloStates {
            let route = KyroStartupPolicy.launchRoute(forSilo: state)
            XCTAssertNotEqual(route, .needsServerSetup, "\(state)")
            XCTAssertNotEqual(route, .needsLogin, "\(state)")
        }
    }

    func testSignedOutServerStillResolvesToKyroProfilesThroughTheResolverStates() {
        let silo = RestoredSessionAuthResolver.localState(
            hasServer: true, hasAccessToken: false, hasProfile: false)
        XCTAssertEqual(silo, .needsLogin, "the Silo provider still reports its own state")
        XCTAssertEqual(KyroStartupPolicy.launchRoute(forSilo: silo), .needsProfile)
    }

    // MARK: Optional Silo connection

    func testSignedInSiloKeepsTheExistingSiloFlow() {
        XCTAssertEqual(KyroStartupPolicy.launchRoute(forSilo: .authenticated), .authenticated)
        XCTAssertEqual(KyroStartupPolicy.launchRoute(forSilo: .needsProfile), .needsProfile)
        XCTAssertEqual(KyroStartupPolicy.launchRoute(forSilo: .loading), .loading)
        XCTAssertFalse(KyroStartupPolicy.usesLocalProfiles(isSiloSignedIn: true))
        let recovery = AppRouter.AuthState.serverRecovery(.serverNotRecognized)
        XCTAssertEqual(KyroStartupPolicy.launchRoute(forSilo: recovery), recovery)
    }

    func testSiloSignOutReturnsToKyroUnlessSigningInAgain() {
        XCTAssertEqual(
            KyroStartupPolicy.routeAfterSiloSignOut(hasActiveServer: true, continuesToSignIn: false),
            .needsProfile)
        XCTAssertEqual(
            KyroStartupPolicy.routeAfterSiloSignOut(hasActiveServer: false, continuesToSignIn: false),
            .needsProfile)
        XCTAssertEqual(
            KyroStartupPolicy.routeAfterSiloSignOut(hasActiveServer: false, continuesToSignIn: true),
            .needsProfile)
        XCTAssertEqual(
            KyroStartupPolicy.routeAfterSiloSignOut(hasActiveServer: true, continuesToSignIn: true),
            .needsLogin, "switching account or server continues to that server's sign-in")
    }

    func testExpiredSiloSessionNeverStrandsKyro() {
        XCTAssertEqual(KyroStartupPolicy.routeAfterSiloSessionExpired(hasActiveServer: true), .needsLogin)
        XCTAssertEqual(KyroStartupPolicy.routeAfterSiloSessionExpired(hasActiveServer: false), .needsProfile)
    }

    func testSiloSetupHasAWayBackToWhoIsWatching() {
        let router = AppRouter()
        router.resetToServerSetup()
        XCTAssertEqual(router.authState, .needsServerSetup)
        router.navigate(to: .settings)
        router.leaveSiloSetup()
        XCTAssertEqual(router.authState, .needsProfile)
        XCTAssertTrue(router.path.isEmpty)
    }

    // MARK: Session persistence

    func testLocalProfileIsUsedOnlyWithoutASiloSession() {
        XCTAssertEqual(
            KyroStartupPolicy.activeProfileID(
                siloProfileID: nil, localProfileID: "local", isSiloSignedIn: { false }),
            "local")
        XCTAssertNil(
            KyroStartupPolicy.activeProfileID(
                siloProfileID: nil, localProfileID: "local", isSiloSignedIn: { true }),
            "a Silo account choosing its profile never sends a Kyro profile ID")
        XCTAssertEqual(
            KyroStartupPolicy.activeProfileID(
                siloProfileID: "silo", localProfileID: "local", isSiloSignedIn: { true }),
            "silo")
    }

    func testSiloProfileLookupSkipsTheSessionCheck() {
        var checked = false
        _ = KyroStartupPolicy.activeProfileID(
            siloProfileID: "silo", localProfileID: "local", isSiloSignedIn: { checked = true; return true })
        XCTAssertFalse(checked, "the common signed-in path reads no Keychain item")
    }

    func testLocalHouseholdAndSelectedProfileSurviveRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KyroStartupPolicyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suiteName = "KyroStartupPolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let databaseURL = directory.appendingPathComponent("identity.sqlite")

        let first = KyroLocalIdentityRuntime(databaseURL: databaseURL, defaults: defaults)
        try await first.ensureInitialProfile()
        let household = defaults.string(forKey: KyroLocalIdentityDefaults.householdIDKey)
        let firstProfiles = try await first.profiles()
        let home = try XCTUnwrap(firstProfiles.first)
        try await first.select(home, pin: nil)

        let relaunched = KyroLocalIdentityRuntime(databaseURL: databaseURL, defaults: defaults)
        try await relaunched.ensureInitialProfile()
        let profiles = try await relaunched.profiles()
        XCTAssertEqual(profiles.map(\.id), [home.id], "relaunch adds no second Home profile")
        XCTAssertEqual(defaults.string(forKey: KyroLocalIdentityDefaults.householdIDKey), household)
        XCTAssertEqual(defaults.string(forKey: KyroLocalIdentityDefaults.activeProfileIDKey), home.id)
    }

    // MARK: Empty provider list

    func testNoProvidersStillYieldsAUsableProfile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KyroStartupPolicyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suiteName = "KyroStartupPolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let runtime = KyroLocalIdentityRuntime(
            databaseURL: directory.appendingPathComponent("identity.sqlite"), defaults: defaults)
        try await runtime.ensureInitialProfile()
        let profiles = try await runtime.profiles()
        XCTAssertEqual(profiles.count, 1)
        XCTAssertFalse(try XCTUnwrap(profiles.first).hasPin, "the first profile opens without a PIN")
        XCTAssertEqual(KyroStartupPolicy.launchRoute(forSilo: .needsServerSetup), .needsProfile)
    }
}
