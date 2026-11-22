import Foundation
import XCTest
import KyroProviders
import KyroIdentity
import KyroFoundation
@testable import Silo

@MainActor
final class KyroLocalIdentityRuntimeTests: XCTestCase {
    func testInterruptedProjectedRemovalReconcilesAfterRelaunchWithoutDeletingOtherLinks() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KyroLinkRecovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "KyroLinkRecovery.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let path = directory.appendingPathComponent("identity.sqlite")
        let runtime = KyroLocalIdentityRuntime(databaseURL: path, defaults: defaults)
        let profile = try await runtime.createProfile(name: "Alex", isChild: false,
                                                      avatarEmoji: nil, pin: "4826")
        let gone = ProviderAccountRef.derived(kind: .silo, key: "gone")
        let keep = ProviderAccountRef.derived(kind: .silo, key: "keep")
        let household = HouseholdID(rawValue: try XCTUnwrap(UUID(uuidString:
            try XCTUnwrap(defaults.string(forKey: KyroLocalIdentityDefaults.householdIDKey)))))
        let database = try SQLiteDatabase(path: path)
        let identity = IdentityStore(database: database, household: household)
        let profileID = KyroProfileID(rawValue: try XCTUnwrap(UUID(uuidString: profile.id)))
        try await identity.link(ProviderUserLink(profile: profileID, account: gone.id,
                                                provider: gone.kind.rawValue, remoteUserID: "old-user"),
                                projected: true)
        try await identity.link(ProviderUserLink(profile: profileID, account: keep.id,
                                                provider: keep.kind.rawValue, remoteUserID: "keep-user"),
                                projected: true)
        runtime.markProjectedRemovalPending(gone)
        let reopened = KyroLocalIdentityRuntime(databaseURL: path, defaults: defaults)
        await reopened.reconcilePendingRemovals(availableAccounts: [])
        let profilesAfterRecovery = try await reopened.profiles()
        XCTAssertEqual(profilesAfterRecovery.map(\.id), [profile.id])
        let linksAfterRecovery = try await identity.links(for: profileID)
        XCTAssertEqual(linksAfterRecovery.map(\.remoteUserID), ["keep-user"])
        // A rollback leaves the account projected and clears its pending journal record.
        reopened.markProjectedRemovalPending(keep)
        await reopened.reconcilePendingRemovals(availableAccounts: [
            ProviderAccountRecord(ref: keep, label: "Keep", origin: .projected,
                                  connection: .saved)])
        let linksAfterRollback = try await identity.links(for: profileID)
        XCTAssertEqual(linksAfterRollback.map(\.remoteUserID), ["keep-user"])
        let profilesAfterRollback = try await reopened.profiles()
        XCTAssertEqual(profilesAfterRollback.first?.hasPin, true)
        try await database.close()
    }
    func testStandaloneProfilesPersistAndVerifyPINWithoutSiloSession() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KyroLocalIdentityTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let suiteName = "KyroLocalIdentityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let databaseURL = directory.appendingPathComponent("identity.sqlite")
        let runtime = KyroLocalIdentityRuntime(databaseURL: databaseURL, defaults: defaults)

        let initialProfiles = try await runtime.profiles()
        XCTAssertEqual(initialProfiles, [], "no profile is created behind the person's back")

        try await runtime.createProfile(name: "Alex", isChild: false, avatarEmoji: nil, pin: nil)
        let created = try await runtime.createProfile(
            name: "Kids", isChild: true, avatarEmoji: "preset:dicebear:adventurer:otter", pin: "4826")
        XCTAssertEqual(created.name, "Kids")
        XCTAssertTrue(created.hasPin)
        let profiles = try await runtime.profiles()
        XCTAssertEqual(profiles.count, 2)
        XCTAssertTrue(profiles.contains(created))
        let kids = try XCTUnwrap(profiles.first(where: { $0.name == "Kids" }))
        XCTAssertTrue(kids.isChild)
        XCTAssertTrue(kids.hasPin)
        XCTAssertEqual(kids.avatarEmoji, "preset:dicebear:adventurer:otter")

        let wrongPINAccepted = try await runtime.verify("0000", profileID: try XCTUnwrap(UUID(uuidString: kids.id)))
        XCTAssertFalse(wrongPINAccepted)
        try await runtime.select(kids, pin: "4826")
        XCTAssertEqual(defaults.string(forKey: KyroLocalIdentityDefaults.activeProfileIDKey), kids.id)

        let reopened = KyroLocalIdentityRuntime(databaseURL: databaseURL, defaults: defaults)
        let reopenedProfiles = try await reopened.profiles()
        XCTAssertEqual(reopenedProfiles, profiles)
    }
}
