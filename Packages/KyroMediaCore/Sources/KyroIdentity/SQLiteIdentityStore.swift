import Foundation
import KyroFoundation

public actor SQLiteIdentityStore {
    private let writer: SQLiteWriter
    public init(writer: SQLiteWriter) { self.writer = writer }
    public func save(_ profile: KyroProfile, pin: PINVerifier? = nil) async throws {
        let values: [SQLiteValue] = [.text(profile.id.description),.text(profile.householdID.description),.text(profile.name),.text(profile.kind.rawValue),pin.map{.blob($0.salt)} ?? .null,pin.map{.blob($0.derivedKey)} ?? .null,profile.tombstonedAt.map{.real($0.timeIntervalSince1970)} ?? .null]
        _ = try await writer.execute("INSERT INTO profiles(id,household_id,name,kind,pin_salt,pin_hash,tombstoned_at) VALUES(?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,kind=excluded.kind,pin_salt=COALESCE(excluded.pin_salt,profiles.pin_salt),pin_hash=COALESCE(excluded.pin_hash,profiles.pin_hash),tombstoned_at=excluded.tombstoned_at",bindings:values)
    }
    public func tombstone(_ id: KyroProfileID, at date: Date = .now) async throws { _ = try await writer.execute("UPDATE profiles SET tombstoned_at=? WHERE id=?",bindings:[.real(date.timeIntervalSince1970),.text(id.description)]) }
    public func profile(_ id: KyroProfileID) async throws -> KyroProfile? {
        guard let row = try await writer.query("SELECT id,household_id,name,kind,tombstoned_at FROM profiles WHERE id=?",bindings:[.text(id.description)]).first,
              case let .text(household)?=row["household_id"],case let .text(name)?=row["name"],case let .text(kind)?=row["kind"],let profileKind=KyroProfileKind(rawValue:kind) else{return nil}
        let tombstone:Date?;if case let .real(seconds)?=row["tombstoned_at"]{tombstone=Date(timeIntervalSince1970:seconds)}else{tombstone=nil}
        return KyroProfile(id:id,householdID:HouseholdID(UUID(uuidString:household) ?? UUID()),name:name,kind:profileKind,tombstonedAt:tombstone)
    }
    public func addAccount(_ account: ProviderAccount) async throws {
        let data=try JSONEncoder().encode(account)
        _ = try await writer.execute("INSERT OR REPLACE INTO provider_accounts(id,provider,subject,scope,metadata) VALUES(?,?,?,?,?)",bindings:[.text(account.id.description),.text(account.provider),.text(account.subject),.text(account.scope),.blob(data)])
    }
    public func grant(_ grant: SourceGrant) async throws {
        guard let account=try await writer.query("SELECT provider,subject,scope FROM provider_accounts WHERE id=?",bindings:[.text(grant.accountID.description)]).first,
              case let .text(provider)?=account["provider"],case let .text(subject)?=account["subject"],case let .text(scope)?=account["scope"] else{throw IdentityError.missingPrincipal}
        if grant.canWrite {
            let conflict=try await writer.query("SELECT profile_id FROM provider_subject_writers WHERE provider=? AND subject=? AND scope=? AND profile_id<>?",bindings:[.text(provider),.text(subject),.text(scope),.text(grant.profileID.description)])
            guard conflict.isEmpty else{throw IdentityError.exclusiveWriteConflict}
        }
        var tx:[(String,[SQLiteValue])]=[("INSERT INTO profile_source_grants(profile_id,account_id,can_write) VALUES(?,?,?) ON CONFLICT(profile_id,account_id) DO UPDATE SET can_write=excluded.can_write",[.text(grant.profileID.description),.text(grant.accountID.description),.integer(grant.canWrite ? 1:0)])]
        tx.append(("DELETE FROM provider_subject_writers WHERE provider=? AND subject=? AND scope=? AND profile_id=?",[.text(provider),.text(subject),.text(scope),.text(grant.profileID.description)]))
        if grant.canWrite { tx.append(("INSERT INTO provider_subject_writers(provider,subject,scope,profile_id,account_id) VALUES(?,?,?,?,?)",[.text(provider),.text(subject),.text(scope),.text(grant.profileID.description),.text(grant.accountID.description)])) }
        try await writer.transaction(tx)
    }
}
