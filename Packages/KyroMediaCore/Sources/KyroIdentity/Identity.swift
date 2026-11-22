import Foundation
import CommonCrypto
import KyroFoundation

public enum KyroProfileKind: String, Codable, Sendable { case standard, kids }
public struct KyroProfile: Codable, Sendable, Identifiable, Hashable {
    public let id: KyroProfileID; public let householdID: HouseholdID; public var name: String; public let kind: KyroProfileKind; public var tombstonedAt: Date?
    public init(id: KyroProfileID = .init(), householdID: HouseholdID, name: String, kind: KyroProfileKind = .standard, tombstonedAt: Date? = nil) { self.id=id; self.householdID=householdID; self.name=name; self.kind=kind; self.tombstonedAt=tombstonedAt }
}
public struct PINVerifier: Codable, Sendable {
    public let salt: Data; public let derivedKey: Data; public let rounds: Int
    public init(pin: String, rounds: Int = 210_000) throws {
        guard !pin.isEmpty, rounds >= 100_000 else { throw PINError.invalidParameters }
        let localSalt = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }); salt=localSalt; self.rounds=rounds
        var result = [UInt8](repeating: 0, count: 32)
        let localRounds=rounds
        let status = pin.withCString { CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), $0, strlen($0), [UInt8](localSalt), localSalt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(localRounds), &result, result.count) }
        guard status == kCCSuccess else { throw PINError.derivationFailed }; derivedKey=Data(result)
    }
    public func verifies(_ pin: String) -> Bool {
        var candidate=[UInt8](repeating: 0, count: derivedKey.count)
        let status = pin.withCString { CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), $0, strlen($0), [UInt8](salt), salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds), &candidate, candidate.count) }
        return status == kCCSuccess && zip(candidate, derivedKey).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
public enum PINError: Error, Sendable { case invalidParameters, derivationFailed }
public struct ProviderAccount: Codable, Sendable, Identifiable, Hashable { public let id: ProviderAccountID; public let provider: String; public let subject: String; public let scope: String; public init(id: ProviderAccountID = .init(), provider: String, subject: String, scope: String) { self.id=id; self.provider=provider; self.subject=subject; self.scope=scope } }
public struct SourceGrant: Codable, Sendable, Hashable { public let profileID: KyroProfileID; public let accountID: ProviderAccountID; public let canWrite: Bool; public init(profileID: KyroProfileID, accountID: ProviderAccountID, canWrite: Bool) { self.profileID=profileID; self.accountID=accountID; self.canWrite=canWrite } }
public actor IdentityRegistry {
    private var profiles: [KyroProfileID: KyroProfile] = [:]; private var accounts: [ProviderAccountID: ProviderAccount] = [:]; private var grants: Set<SourceGrant> = []
    public init() {}
    public func createProfile(householdID: HouseholdID, name: String, kind: KyroProfileKind = .standard) -> KyroProfile { let p=KyroProfile(householdID: householdID,name:name,kind:kind); profiles[p.id]=p; return p }
    public func deleteProfile(_ id: KyroProfileID, at date: Date = .now) { guard var p=profiles[id] else{return}; p.tombstonedAt=date; profiles[id]=p; grants=grants.filter{$0.profileID != id} }
    public func profile(_ id: KyroProfileID) -> KyroProfile? { profiles[id] }
    public func addAccount(_ account: ProviderAccount) { accounts[account.id]=account }
    public func grant(_ grant: SourceGrant) throws {
        guard profiles[grant.profileID]?.tombstonedAt == nil, accounts[grant.accountID] != nil else { throw IdentityError.missingPrincipal }
        if grant.canWrite, let account=accounts[grant.accountID], grants.contains(where: { $0.canWrite && $0.accountID != grant.accountID && accounts[$0.accountID]?.provider == account.provider && accounts[$0.accountID]?.subject == account.subject }) { throw IdentityError.exclusiveWriteConflict }
        grants.insert(grant)
    }
    public func mayWrite(profileID: KyroProfileID, accountID: ProviderAccountID) -> Bool { grants.contains { $0.profileID == profileID && $0.accountID == accountID && $0.canWrite } }
}
public enum IdentityError: Error, Sendable { case missingPrincipal, exclusiveWriteConflict }
