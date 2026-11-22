#if os(iOS)
import Foundation
import Observation
import KyroCredentials
import KyroFoundation
import KyroIdentity
import KyroProviders
import KyroSourceJellyfin

/// The app-facing owner of Jellyfin sessions. Account metadata lives in the existing household
/// registry; only the per-account token is in Keychain. A Silo session is never consulted.
@MainActor @Observable
final class KyroJellyfinConnections {
    static let shared = KyroJellyfinConnections()

    enum ConnectionError: LocalizedError {
        case missingProfile, missingAccount, invalidEndpoint, storageUnavailable
        var errorDescription: String? {
            switch self {
            case .missingProfile: "Select a Kyro profile before connecting a server."
            case .missingAccount: "This Jellyfin server is no longer registered."
            case .invalidEndpoint: "Enter a valid Jellyfin http or https server URL."
            case .storageUnavailable: "Kyro couldn't open its local account registry."
            }
        }
    }

    private(set) var connectionErrors: [ProviderAccountRef: String] = [:]
    private(set) var connectedAccounts: Set<ProviderAccountRef> = []
    @ObservationIgnored private var clients: [ProviderAccountRef: JellyfinClient] = [:]
    @ObservationIgnored private var restoring = false
    @ObservationIgnored private var loadedProfileID: UUID?
    @ObservationIgnored private let credentials: any CredentialStore
    @ObservationIgnored private let runtime: KyroLocalIdentityRuntime
    @ObservationIgnored private let defaults: UserDefaults

    init(runtime: KyroLocalIdentityRuntime? = nil,
         credentials: any CredentialStore = AppleKeychainCredentialStore(),
         defaults: UserDefaults = .standard) {
        self.runtime = runtime ?? .shared
        self.credentials = credentials
        self.defaults = defaults
    }

    func client(for account: ProviderAccountRef) -> JellyfinClient? { clients[account] }

    /// Authentication is validated with an authenticated library request before account metadata
    /// or a Kyro profile association is committed. A failed attempt removes its temporary token.
    @discardableResult
    func connect(url rawURL: String, username: String, password: String) async throws -> ProviderAccountRef {
        guard let registry = runtime.providerRegistry() else { throw ConnectionError.storageUnavailable }
        let url = try Self.endpoint(rawURL)
        guard let profileID = activeProfileID else { throw ConnectionError.missingProfile }
        let id = ProviderAccountID()
        let client = try makeClient(url: url, id: id)
        do {
            let session = try await client.authenticate(username: username, password: password)
            _ = try await client.libraries()
            let ref = try await registry.register(kind: .jellyfin,
                                                  label: url.host ?? "Jellyfin",
                                                  endpoint: url.absoluteString, id: id)
            do {
                try await runtime.link(profileID: profileID, to: ref, remoteUserID: session.userID)
                try KyroProviderCatalogBridge.registerJellyfinCatalog(account: ref, client: client)
                clients[ref] = client
                loadedProfileID = profileID
                connectedAccounts.insert(ref)
                connectionErrors[ref] = nil
                return ref
            } catch {
                try? await registry.remove(ref)
                throw error
            }
        } catch {
            try? await client.signOut()
            throw error
        }
    }

    /// Restores each saved account independently. A revoked token leaves its nonsecret account
    /// entry and profile link in place so the user can reconnect without creating a new identity.
    func restore() async {
        guard !restoring, let registry = runtime.providerRegistry() else { return }
        restoring = true
        defer { restoring = false }
        if loadedProfileID != activeProfileID {
            let previous = Array(clients.keys)
            clients.removeAll()
            connectedAccounts.removeAll()
            loadedProfileID = activeProfileID
            for account in previous { await ProviderCatalogMirror.shared.remove(account) }
        }
        guard let accounts = try? await registry.storedAccounts() else { return }
        for account in accounts where account.provider == ProviderKind.jellyfin.rawValue {
            let ref = ProviderAccountRef(id: account.id, kind: .jellyfin)
            if let existing = clients[ref] {
                if (await existing.currentSession) == nil {
                    clients[ref] = nil
                    connectedAccounts.remove(ref)
                    connectionErrors[ref] = "Session expired. Reconnect this Jellyfin server."
                    await ProviderCatalogMirror.shared.remove(ref)
                }
                continue
            }
            guard clients[ref] == nil, let endpoint = account.endpoint,
                  let url = try? Self.endpoint(endpoint),
                  let client = try? makeClient(url: url, id: account.id) else {
                if clients[ref] == nil { connectionErrors[ref] = "Reconnect this Jellyfin server." }
                continue
            }
            do {
                guard let session = try await client.restoreSession() else {
                    connectionErrors[ref] = "Sign in to reconnect this Jellyfin server."
                    continue
                }
                _ = try await client.libraries()
                // A restored token must still refer to the account's linked remote user.
                guard let profileID = activeProfileID,
                      let owner = try await runtime.linkedProfile(for: ref, remoteUserID: session.userID),
                      owner == profileID else {
                    connectionErrors[ref] = "This server belongs to another Kyro profile."
                    continue
                }
                try KyroProviderCatalogBridge.registerJellyfinCatalog(account: ref, client: client)
                clients[ref] = client
                connectedAccounts.insert(ref)
                connectionErrors[ref] = nil
            } catch {
                connectedAccounts.remove(ref)
                if case JellyfinError.unauthorized = error {
                    connectionErrors[ref] = "Session expired. Reconnect this Jellyfin server."
                } else {
                    connectionErrors[ref] = "Jellyfin is unreachable. Pull to retry."
                }
            }
        }
    }

    func reconnect(_ ref: ProviderAccountRef, username: String, password: String) async throws {
        guard ref.kind == .jellyfin, let registry = runtime.providerRegistry(),
              let account = try await registry.storedAccounts().first(where: { $0.id == ref.id && $0.provider == ref.kind.rawValue }),
              let endpoint = account.endpoint else { throw ConnectionError.missingAccount }
        guard let profileID = activeProfileID else { throw ConnectionError.missingProfile }
        let client = try makeClient(url: Self.endpoint(endpoint), id: ref.id)
        if let savedSession = try await client.restoreSession(),
           let owner = try await runtime.linkedProfile(for: ref, remoteUserID: savedSession.userID),
           owner != profileID {
            throw ConnectionError.missingAccount
        }
        let key = Self.credentialKey(ref.id)
        let previousToken = try await credentials.read(key)
        do {
            let session = try await client.authenticate(username: username, password: password)
            _ = try await client.libraries()
            try await runtime.link(profileID: profileID, to: ref, remoteUserID: session.userID)
            try KyroProviderCatalogBridge.registerJellyfinCatalog(account: ref, client: client)
            clients[ref] = client
            loadedProfileID = profileID
            connectedAccounts.insert(ref)
            connectionErrors[ref] = nil
        } catch {
            if let previousToken { try? await credentials.write(previousToken, for: key) }
            else { try? await credentials.remove(key) }
            throw error
        }
    }

    /// Provider removal never deletes a Kyro profile, PIN, IPTV data, or another server's token.
    func remove(_ ref: ProviderAccountRef) async throws {
        guard ref.kind == .jellyfin, let registry = runtime.providerRegistry() else {
            throw ConnectionError.missingAccount
        }
        try await registry.remove(ref) // also unlinks only this registered account
        clients[ref] = nil
        connectedAccounts.remove(ref)
        connectionErrors[ref] = nil
        let credentialRemoval: Result<Void, Error>
        do {
            try await credentials.remove(Self.credentialKey(ref.id))
            credentialRemoval = .success(())
        } catch {
            credentialRemoval = .failure(error)
        }
        await ProviderCatalogMirror.shared.remove(ref)
        try credentialRemoval.get()
    }

    private var activeProfileID: UUID? {
        defaults.string(forKey: KyroLocalIdentityDefaults.activeProfileIDKey).flatMap(UUID.init(uuidString:))
    }

    private func makeClient(url: URL, id: ProviderAccountID) throws -> JellyfinClient {
        let deviceID: String
        if let saved = defaults.string(forKey: "kyro.jellyfin.device-id") { deviceID = saved }
        else {
            deviceID = UUID().uuidString
            defaults.set(deviceID, forKey: "kyro.jellyfin.device-id")
        }
        return try JellyfinClient(baseURL: url,
            clientInfo: JellyfinClientInfo(client: "Kyro", device: "iOS", deviceID: deviceID,
                                           version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1"),
            credentialStore: credentials, credentialKey: Self.credentialKey(id))
    }

    static func credentialKey(_ id: ProviderAccountID) -> String { "kyro.jellyfin.\(id.description)" }

    static func endpoint(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.query == nil, url.fragment == nil,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil
        else { throw ConnectionError.invalidEndpoint }
        return url
    }
}
#endif
