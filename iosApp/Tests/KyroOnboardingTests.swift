import Foundation
import XCTest
@testable import Silo

/// Kyro-owned onboarding, profiles and provider scoping (Kyro Labs Build 113 device regression,
/// 2026-11-22: picking the Kyro "Home" profile entered the app and showed "The active server or
/// profile changed. Try again.", because the local profile ID was used as the Silo request
/// profile for a saved, signed-out server).
@MainActor
final class KyroOnboardingTests: XCTestCase {
    // MARK: First launch and returning users

    func testFirstLaunchWithNoKyroProfilesRunsSetup() {
        XCTAssertTrue(KyroFirstRunSetup.needsSetup(isSiloSignedIn: false, localProfileCount: 0))
    }

    func testReturningUserWithSavedKyroProfilesSkipsSetup() {
        XCTAssertFalse(KyroFirstRunSetup.needsSetup(isSiloSignedIn: false, localProfileCount: 1))
        XCTAssertFalse(KyroFirstRunSetup.needsSetup(isSiloSignedIn: false, localProfileCount: 4))
    }

    func testSignedInSiloAccountKeepsSilosProfilePicker() {
        XCTAssertFalse(KyroFirstRunSetup.needsSetup(isSiloSignedIn: true, localProfileCount: 0))
    }

    func testSetupOffersMediaServerAndIPTVWhereLiveTVExists() {
        XCTAssertEqual(KyroFirstRunSetup.sources(supportsLiveTV: true), [.mediaServer, .iptv])
        XCTAssertEqual(KyroFirstRunSetup.sources(supportsLiveTV: false), [.mediaServer],
                       "Apple TV has no Live TV in this build, so it offers no IPTV button")
        #if os(iOS)
        XCTAssertEqual(KyroFirstRunSetup.platformSources, [.mediaServer, .iptv])
        #elseif os(tvOS)
        XCTAssertEqual(KyroFirstRunSetup.platformSources, [.mediaServer])
        #endif
    }

    func testSavingAnIPTVProviderEntersLiveTVAndClosingWithoutSavingDoesNot() {
        XCTAssertTrue(KyroFirstRunSetup.entersLiveTV(providerCountBefore: 0, providerCountAfter: 1))
        XCTAssertFalse(KyroFirstRunSetup.entersLiveTV(providerCountBefore: 0, providerCountAfter: 0))
        XCTAssertFalse(KyroFirstRunSetup.entersLiveTV(providerCountBefore: 2, providerCountAfter: 1))
    }

    func testProfileNameIsTrimmedAndBounded() {
        XCTAssertEqual(KyroFirstRunSetup.validatedName("  Alex \n"), "Alex")
        XCTAssertNil(KyroFirstRunSetup.validatedName("   "))
        XCTAssertNil(KyroFirstRunSetup.validatedName(String(repeating: "x", count: 31)))
        XCTAssertNotNil(KyroFirstRunSetup.validatedName(String(repeating: "x", count: 30)))
    }

    // MARK: Provider states

    func testZeroProvidersShowsKyroHomeAndSendsNoSiloRequests() {
        let state = KyroProviderState(isSiloConnected: false, iptvProviderCount: 0)
        XCTAssertFalse(state.hasAnyProvider)
        XCTAssertEqual(state.homeContent, .kyro)
        XCTAssertFalse(state.loadsSiloLibraries)
        XCTAssertEqual(KyroHomeCopy.lead(state),
                       "Connect a media server or an IPTV provider to start watching.")
    }

    func testIPTVOnlyUsesKyroHomeAndOffersLiveTV() {
        let state = KyroProviderState(isSiloConnected: false, iptvProviderCount: 1)
        XCTAssertTrue(state.hasAnyProvider)
        XCTAssertTrue(state.hasIPTV)
        XCTAssertEqual(state.homeContent, .kyro)
        XCTAssertFalse(state.loadsSiloLibraries)
        XCTAssertTrue(KyroHomeCopy.lead(state).hasPrefix("Watch Live TV now"))
    }

    func testStaleSignedOutServerIsOfferedForSignInNotLoaded() {
        // A saved server without a session is not a connection.
        let state = KyroProviderState(isSiloConnected: false, iptvProviderCount: 0)
        XCTAssertEqual(state.homeContent, .kyro)
        XCTAssertFalse(state.loadsSiloLibraries)
        XCTAssertEqual(KyroHomeCopy.mediaServerTitle(savedServerName: "Cubbiehub"), "Sign in to Cubbiehub")
        XCTAssertEqual(KyroHomeCopy.mediaServerTitle(savedServerName: nil), "Add Media Server")
    }

    func testSignedInSiloKeepsSiloHomeAndLibraries() {
        for iptv in [0, 2] {
            let state = KyroProviderState(isSiloConnected: true, iptvProviderCount: iptv)
            XCTAssertEqual(state.homeContent, .silo)
            XCTAssertTrue(state.loadsSiloLibraries)
        }
    }

    // MARK: Session and provider scoping

    /// The root cause: Silo requests, owner fences and response snapshots read
    /// `AuthService.profileId`. A Kyro profile must never appear there.
    func testKyroProfileNeverBecomesTheSiloRequestProfile() throws {
        let auth = AuthService.shared
        try XCTSkipIf(auth.isLoggedIn || auth.profileId != nil, "test host has a Silo session")
        let defaults = UserDefaults.standard
        let key = KyroLocalIdentityDefaults.activeProfileIDKey
        let previous = defaults.string(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        let localID = UUID().uuidString
        defaults.set(localID, forKey: key)

        XCTAssertNil(auth.profileId, "no Silo profile is sent, cached or fenced for a Kyro profile")
        XCTAssertEqual(auth.kyroProfileId, localID, "Kyro's own data follows the Kyro profile")
        XCTAssertNil(SessionOwner.current(), "a Kyro profile is not a Silo session owner")
    }

    func testSiloProfileWinsForKyroDataWhileSignedIn() {
        XCTAssertEqual(
            KyroStartupPolicy.activeProfileID(
                siloProfileID: "silo-7", localProfileID: "kyro-1", isSiloSignedIn: { true }),
            "silo-7")
    }

    // MARK: Profile persistence and isolation

    func testKyroProfilesSurviveRelaunchAndAreIsolatedPerHousehold() async throws {
        let (first, firstDefaults, firstDB) = try makeRuntime()
        let (other, _, _) = try makeRuntime()

        let alex = try await first.createProfile(name: "Alex", isChild: false, avatarEmoji: nil, pin: nil)
        let kids = try await first.createProfile(name: "Kids", isChild: true, avatarEmoji: nil, pin: "2468")
        try await first.select(alex, pin: nil)

        let otherProfiles = try await other.profiles()
        XCTAssertTrue(otherProfiles.isEmpty, "another household sees none of these profiles")

        let relaunched = KyroLocalIdentityRuntime(databaseURL: firstDB, defaults: firstDefaults)
        let restored = try await relaunched.profiles()
        XCTAssertEqual(Set(restored.map(\.id)), [alex.id, kids.id])
        XCTAssertEqual(firstDefaults.string(forKey: KyroLocalIdentityDefaults.activeProfileIDKey), alex.id)

        // Switching to a PIN profile still needs its PIN; the active profile is unchanged on failure.
        do {
            try await relaunched.select(kids, pin: "0000")
            XCTFail("a wrong PIN must not select the profile")
        } catch {}
        XCTAssertEqual(firstDefaults.string(forKey: KyroLocalIdentityDefaults.activeProfileIDKey), alex.id)
        try await relaunched.select(kids, pin: "2468")
        XCTAssertEqual(firstDefaults.string(forKey: KyroLocalIdentityDefaults.activeProfileIDKey), kids.id)
    }

    func testFirstRunSetupActivatesTheNewProfileWithoutAskingForItsPINAgain() async throws {
        let (runtime, defaults, _) = try makeRuntime()
        let created = try await runtime.createProfile(name: "Jo", isChild: false, avatarEmoji: nil, pin: "1357")
        runtime.activateNewProfile(created)
        XCTAssertEqual(defaults.string(forKey: KyroLocalIdentityDefaults.activeProfileIDKey), created.id)
        XCTAssertTrue(created.hasPin)
    }

    // MARK: Helpers

    private func makeRuntime() throws -> (KyroLocalIdentityRuntime, UserDefaults, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KyroOnboardingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let suiteName = "KyroOnboardingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let databaseURL = directory.appendingPathComponent("identity.sqlite")
        return (KyroLocalIdentityRuntime(databaseURL: databaseURL, defaults: defaults), defaults, databaseURL)
    }
}
