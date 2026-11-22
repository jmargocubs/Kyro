import Foundation
import KyroIdentity
import XCTest
@testable import KyroProviders

private struct LegacyIdentityState: Encodable, Sendable {
  let profiles: [KyroProfile]
  let accounts: [ProviderAccount]
  let grants: [SourceGrant]
}

@MainActor final class ProfileLinkRegistryTests: XCTestCase {
  private func fixture() throws -> (SQLiteDatabase, URL, HouseholdID, IdentityStore) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("identity.sqlite")
    let db = try SQLiteDatabase(path: url)
    let household = HouseholdID()
    return (db, url, household, IdentityStore(database: db, household: household))
  }

  func testLinksPersistAcrossReopenAndRemainInTheirHousehold() async throws {
    let (db, url, household, identity) = try fixture()
    let profile = KyroProfile(name: "Alex", kind: .standard)
    try await identity.create(profile)
    try await identity.setPIN("4826", for: profile.id)
    let registry = ProviderRegistry(identity: identity)
    let account = try await registry.register(kind: .jellyfin, label: "Home")
    let links = ProfileLinkRegistry(identity: identity)
    try await links.link(profile: profile.id, to: account, remoteUserID: "j-user",
                         availableAccounts: try await registry.accounts())
    let linked = try await links.profile(for: account, remoteUserID: "j-user")
    XCTAssertEqual(linked, profile.id)
    try await db.close()

    let reopened = try SQLiteDatabase(path: url)
    let same = IdentityStore(database: reopened, household: household)
    let persistedLinks = try await ProfileLinkRegistry(identity: same).links(for: profile.id)
    XCTAssertEqual(persistedLinks.count, 1)
    let pinValid = try await same.verifyPIN("4826", for: profile.id)
    XCTAssertTrue(pinValid)
    let other = IdentityStore(database: reopened, household: HouseholdID())
    let otherLink = try await ProfileLinkRegistry(identity: other).profile(for: account, remoteUserID: "j-user")
    XCTAssertNil(otherLink)
    try await reopened.close()
  }

  func testMultipleAccountsProviderSwitchAndUnlinkAreIndependent() async throws {
    let (db, _, _, identity) = try fixture()
    let profile = KyroProfile(name: "Alex", kind: .standard)
    let second = KyroProfile(name: "Sam", kind: .standard)
    try await identity.create(profile)
    try await identity.create(second)
    let registry = ProviderRegistry(identity: identity)
    let jellyA = try await registry.register(kind: .jellyfin, label: "A")
    let jellyB = try await registry.register(kind: .jellyfin, label: "B")
    let emby = try await registry.register(kind: .emby, label: "Emby")
    let plex = try await registry.register(kind: .plex, label: "Plex Home")
    let links = ProfileLinkRegistry(identity: identity)
    for account in [jellyA, jellyB, emby, plex] {
      try await links.link(profile: profile.id, to: account, remoteUserID: "same-user",
                           availableAccounts: try await registry.accounts())
    }
    let before = try await links.links(for: profile.id)
    XCTAssertEqual(before.count, 4)
    do {
      try await links.link(profile: second.id, to: jellyA, remoteUserID: "same-user",
                           availableAccounts: try await registry.accounts())
      XCTFail("One remote user must not have two Kyro owners")
    } catch IdentityStore.IdentityError.subjectAlreadyWritable {}
    do {
      try await links.link(profile: second.id, to: jellyA, remoteUserID: profile.id.description,
                           availableAccounts: try await registry.accounts())
      XCTFail("A Kyro profile ID must not become a remote user ID")
    } catch IdentityStore.IdentityError.invalidLink {}
    try await links.unlink(profile: profile.id, from: jellyA)
    let unlinked = try await links.profile(for: jellyA, remoteUserID: "same-user")
    let stillLinked = try await links.profile(for: jellyB, remoteUserID: "same-user")
    XCTAssertNil(unlinked)
    XCTAssertEqual(stillLinked, profile.id)
    try await registry.remove(jellyB)
    let removed = try await links.profile(for: jellyB, remoteUserID: "same-user")
    let remaining = try await links.links(for: profile.id)
    let profiles = try await identity.profiles()
    XCTAssertNil(removed)
    XCTAssertEqual(remaining.count, 2)
    XCTAssertEqual(profiles.count, 2)
    try await db.close()
  }

  func testSiloSignOutProjectedRemovalAndProfileDeletion() async throws {
    let (db, _, _, identity) = try fixture()
    let profile = KyroProfile(name: "Alex", kind: .standard)
    try await identity.create(profile)
    let links = ProfileLinkRegistry(identity: identity)
    let signedIn = ProviderProjection.silo(.init(
      servers: [.init(id: "silo-a", name: "A"), .init(id: "silo-b", name: "B")],
      activeServerID: "silo-a", isActiveServerSignedIn: true))
    let siloA = signedIn[0].ref
    let siloB = signedIn[1].ref
    try await links.link(profile: profile.id, to: siloA, remoteUserID: "remote-silo-profile",
                         availableAccounts: signedIn)
    XCTAssertNotEqual(profile.id.description, "remote-silo-profile")
    do {
      try await links.link(profile: profile.id, to: siloB, remoteUserID: "other",
                           availableAccounts: signedIn)
      XCTFail("Saved Silo server is not authenticated")
    } catch ProviderError.notConnected {}
    let signedOut = ProviderProjection.silo(.init(
      servers: [.init(id: "silo-a", name: "A")], activeServerID: "silo-a",
      isActiveServerSignedIn: false))
    let afterSignOut = try await links.profile(for: siloA, remoteUserID: "remote-silo-profile")
    XCTAssertEqual(afterSignOut, profile.id,
                   "Sign-out must not erase an association or a Kyro profile")
    do {
      try await links.link(profile: profile.id, to: siloA, remoteUserID: "new-user",
                           availableAccounts: signedOut)
      XCTFail("Signed-out Silo cannot establish a new link")
    } catch ProviderError.notConnected {}
    try await links.removedProjectedAccount(siloA)
    let afterRemoval = try await links.profile(for: siloA, remoteUserID: "remote-silo-profile")
    let survivingProfiles = try await identity.profiles()
    XCTAssertNil(afterRemoval)
    XCTAssertEqual(survivingProfiles.count, 1)
    try await links.link(profile: profile.id, to: siloA, remoteUserID: "remote-silo-profile",
                         availableAccounts: signedIn)
    try await identity.delete(profile.id)
    let deletedLinks = try await links.links(for: profile.id)
    let deletedOwner = try await links.profile(for: siloA, remoteUserID: "remote-silo-profile")
    XCTAssertTrue(deletedLinks.isEmpty)
    XCTAssertNil(deletedOwner)
    try await db.close()
  }

  func testLegacyIdentityStateWithoutLinksIsReadableAndExtendedInPlace() async throws {
    let (db, _, household, identity) = try fixture()
    let profile = KyroProfile(name: "Existing", kind: .standard)
    let account = ProviderAccount(provider: ProviderKind.plex.rawValue, label: "Plex Home")
    try await db.save(
      LegacyIdentityState(profiles: [profile], accounts: [account], grants: []),
      key: "identity:" + household.description)
    let registry = ProviderRegistry(identity: identity)
    let ref = ProviderAccountRef(id: account.id, kind: .plex)
    try await ProfileLinkRegistry(identity: identity).link(
      profile: profile.id, to: ref, remoteUserID: "plex-home-user",
      availableAccounts: try await registry.accounts())
    let retained = try await identity.profiles()
    let persistedAccounts = try await identity.accounts()
    XCTAssertEqual(retained.map(\.id), [profile.id])
    XCTAssertEqual(persistedAccounts, [account])
    try await db.close()
  }
}
