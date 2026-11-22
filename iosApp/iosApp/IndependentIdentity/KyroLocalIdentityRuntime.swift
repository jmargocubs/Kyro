import Foundation
import KyroFoundation
import KyroIdentity
import KyroProviders

enum KyroLocalIdentityDefaults {
    static let householdIDKey = "kyro.identity.household-id"
    static let activeProfileIDKey = "kyro.identity.active-profile-id"

    static var activeProfileID: String? {
        UserDefaults.standard.string(forKey: activeProfileIDKey)
    }
}

/// Kyro's own household and profiles, stored on the device. They back Who's Watching whenever
/// no Silo session is signed in, and outlive every provider: connecting, switching or signing
/// out of Silo, or adding and removing IPTV, never deletes them. Silo sessions remain owned
/// by AuthService.
@MainActor
final class KyroLocalIdentityRuntime {
    static let shared = KyroLocalIdentityRuntime()

    private let database: SQLiteDatabase?
    private let identity: IdentityStore?
    private let defaults: UserDefaults
    private(set) var startupError: Error?

    init(databaseURL: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let key = KyroLocalIdentityDefaults.householdIDKey
        let householdID: HouseholdID
        if let value = defaults.string(forKey: key),
           let uuid = UUID(uuidString: value) {
            householdID = HouseholdID(rawValue: uuid)
        } else {
            householdID = HouseholdID()
            defaults.set(householdID.description, forKey: key)
        }
        do {
            let databasePath: URL
            if let databaseURL {
                databasePath = databaseURL
            } else {
                let root = try FileManager.default.url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                ).appendingPathComponent("Kyro", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                databasePath = root.appendingPathComponent("identity.sqlite")
            }
            try FileManager.default.createDirectory(
                at: databasePath.deletingLastPathComponent(), withIntermediateDirectories: true)
            let database = try SQLiteDatabase(path: databasePath)
            self.database = database
            identity = IdentityStore(database: database, household: householdID)
        } catch {
            startupError = error
            database = nil
            identity = nil
        }
    }

    /// The household's provider accounts, in the same database as its profiles. Nil when local
    /// storage could not be opened.
    func providerRegistry() -> ProviderRegistry? {
        identity.map { ProviderRegistry(identity: $0) }
    }

    /// Profiles are created by the person in Kyro's first-run setup or with Add Profile, never
    /// silently: an empty household is what tells Who's Watching to start setup. Existing
    /// profiles, including a "Home" profile made by Build 113, are kept as they are.
    @discardableResult
    func createProfile(name: String, isChild: Bool, avatarEmoji: String?, pin: String?) async throws -> UserProfile {
        guard let identity else { throw startupError ?? RuntimeError.storageUnavailable }
        let profile = KyroProfile(
            name: name,
            kind: isChild ? .kids : .standard,
            avatarEmoji: avatarEmoji
        )
        try await identity.create(profile)
        if let pin, !pin.isEmpty {
            do {
                try await identity.setPIN(pin, for: profile.id)
            } catch {
                try? await identity.delete(profile.id)
                throw error
            }
        }
        return UserProfile(
            id: profile.id.description,
            name: profile.name,
            avatarEmoji: profile.avatarEmoji,
            hasPin: pin?.isEmpty == false,
            isChild: isChild,
            isPrimary: false
        )
    }

    func profiles() async throws -> [UserProfile] {
        guard let identity else { throw startupError ?? RuntimeError.storageUnavailable }
        var result: [UserProfile] = []
        for profile in try await identity.profiles() {
            result.append(UserProfile(
                id: profile.id.description,
                name: profile.name,
                avatarEmoji: profile.avatarEmoji,
                hasPin: try await identity.hasPIN(for: profile.id),
                isChild: profile.kind == .kids,
                isPrimary: false
            ))
        }
        return result
    }

    func select(_ profile: UserProfile, pin: String?) async throws {
        guard let identity,
              let uuid = UUID(uuidString: profile.id) else { throw RuntimeError.profileUnavailable }
        let profileID = KyroProfileID(rawValue: uuid)
        if profile.hasPin {
            guard let pin, try await identity.verifyPIN(pin, for: profileID) else {
                throw RuntimeError.incorrectPIN
            }
        }
        defaults.set(profile.id, forKey: KyroLocalIdentityDefaults.activeProfileIDKey)
    }

    /// First-run setup selects the profile its person just created (and set any PIN for)
    /// without asking for that PIN again. Every later selection goes through `select`.
    func activateNewProfile(_ profile: UserProfile) {
        defaults.set(profile.id, forKey: KyroLocalIdentityDefaults.activeProfileIDKey)
    }

    func verify(_ pin: String, profileID: UUID) async throws -> Bool {
        guard let identity else { throw startupError ?? RuntimeError.storageUnavailable }
        return try await identity.verifyPIN(pin, for: KyroProfileID(rawValue: profileID))
    }

    enum RuntimeError: LocalizedError {
        case storageUnavailable, profileUnavailable, incorrectPIN
        var errorDescription: String? {
            switch self {
            case .storageUnavailable: "Kyro couldn't open local profile storage."
            case .profileUnavailable: "This Kyro profile is no longer available."
            case .incorrectPIN: "The profile PIN is incorrect."
            }
        }
    }
}
