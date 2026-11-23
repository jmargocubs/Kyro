import Foundation
import KyroFoundation
import KyroIdentity
import XCTest

@MainActor final class IdentityBoundaryTests: XCTestCase {
  func testLocalProfileEditsAndPINsRemainIndependentAfterReopen() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("identity.sqlite")
    let household = HouseholdID()
    let db = try SQLiteDatabase(path: url)
    let store = IdentityStore(database: db, household: household)
    let first = KyroProfile(name: "Alex", kind: .standard)
    let second = KyroProfile(name: "Sam", kind: .standard)
    try await store.create(first)
    try await store.create(second)
    try await store.setPIN("1234", for: first.id)
    try await store.setPIN("5678", for: second.id)
    do {
      try await store.edit(first.id, name: "Wrong", kind: .kids, avatarEmoji: "🦊",
                           currentPIN: "0000", newPIN: "4321")
      XCTFail("Wrong PIN must not edit")
    } catch { XCTAssertTrue(error is IdentityStore.IdentityError) }
    try await store.edit(first.id, name: "Alex Jr", kind: .kids, avatarEmoji: "🦊",
                         currentPIN: "1234", newPIN: "4321")
    try await db.close()
    let reopened = try SQLiteDatabase(path: url)
    let persisted = IdentityStore(database: reopened, household: household)
    let profiles = try await persisted.profiles()
    XCTAssertEqual(profiles.first(where: { $0.id == first.id })?.name, "Alex Jr")
    XCTAssertEqual(profiles.first(where: { $0.id == first.id })?.kind, .kids)
    XCTAssertEqual(profiles.first(where: { $0.id == first.id })?.avatarEmoji, "🦊")
    let firstPINValid = try await persisted.verifyPIN("4321", for: first.id)
    let secondPINValid = try await persisted.verifyPIN("5678", for: second.id)
    XCTAssertTrue(firstPINValid)
    XCTAssertTrue(secondPINValid)
    try await persisted.edit(first.id, name: "Alex", kind: .standard, avatarEmoji: nil,
                             currentPIN: "4321", newPIN: "")
    let firstHasPIN = try await persisted.hasPIN(for: first.id)
    let secondHasPIN = try await persisted.hasPIN(for: second.id)
    XCTAssertFalse(firstHasPIN)
    XCTAssertTrue(secondHasPIN)
    try await reopened.close()
  }
  func testPINAttemptLimitSurvivesReopen() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("identity.sqlite")
    let household = HouseholdID()
    let profile = KyroProfile(name: "Adult", kind: .standard)
    let db = try SQLiteDatabase(path: url)
    let store = IdentityStore(database: db, household: household)
    try await store.create(profile)
    try await store.setPIN("5837", for: profile.id)
    let hasPIN = try await store.hasPIN(for: profile.id)
    XCTAssertTrue(hasPIN)
    let now = Date(timeIntervalSince1970: 1_000)
    for _ in 0..<5 {
      let valid = try await store.verifyPIN("0000", for: profile.id, now: now)
      XCTAssertFalse(valid)
    }
    try await db.close()
    let reopened = try SQLiteDatabase(path: url)
    let persisted = IdentityStore(database: reopened, household: household)
    let blocked = try await persisted.verifyPIN("5837", for: profile.id, now: now)
    XCTAssertFalse(blocked)
    let allowed = try await persisted.verifyPIN(
      "5837", for: profile.id, now: now.addingTimeInterval(61))
    XCTAssertTrue(allowed)
    try await reopened.close()
  }
  func testConcurrentWritableGrantHasOnlyOneOwner() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let db = try SQLiteDatabase(path: folder.appendingPathComponent("identity.sqlite"))
    let store = IdentityStore(database: db, household: .init())
    let account = ProviderAccount(provider: "synthetic", label: "Test")
    try await store.register(account)
    let profiles = (0..<10).map { KyroProfile(name: "Profile \($0)", kind: .standard) }
    for profile in profiles { try await store.create(profile) }
    let owners = await withTaskGroup(of: Int.self) { group in
      for profile in profiles {
        group.addTask {
          do {
            try await store.grant(
              SourceGrant(profile: profile.id, account: account.id, subject: "same", writable: true)
            )
            return 1
          } catch { return 0 }
        }
      }
      var count = 0
      for await value in group { count += value }
      return count
    }
    XCTAssertEqual(owners, 1)
    try await db.close()
  }
}
