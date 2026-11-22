#if os(iOS)
import Foundation
import Observation
import KyroProviders
import KyroSourceJellyfin

/// Where the provider-qualified Movies/Series catalog meets the rest of the app (Kyro Labs M2):
/// which media-server accounts contribute, the catalog providers that can be synced, and how a
/// title of one of those accounts is opened. Silo and IPTV keep their own paths.
enum KyroProviderCatalogBridge {
    /// The old catalog path stays one switch away until the provider arm is validated on a device.
    /// On by default; turning it off removes the provider arm from every grid and sync, leaving
    /// exactly Build 110's Silo and IPTV catalog.
    static let enabledDefaultsKey = "kyro.unified.providerCatalog.enabled"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledDefaultsKey) as? Bool ?? true
    }

    /// Registered media-server accounts of this household. Needs no Silo session, and never throws:
    /// an unreadable registry contributes nothing rather than hiding Silo or IPTV titles.
    @MainActor
    static func registeredAccounts(runtime: KyroLocalIdentityRuntime? = nil,
                                   connectedJellyfin: Set<ProviderAccountRef>? = nil) async -> [ProviderAccountRef] {
        let runtime = runtime ?? .shared
        guard isEnabled, let registry = runtime.providerRegistry(),
              let records = try? await registry.accounts() else { return [] }
        guard let linked = try? await runtime.linkedAccountsForActiveProfile() else { return [] }
        let connected = connectedJellyfin ?? KyroJellyfinConnections.shared.connectedAccounts
        return records.map(\.ref).filter {
            $0.kind.isMediaServer && !$0.kind.isProjected && linked.contains($0)
                && ($0.kind != .jellyfin || connected.contains($0))
        }
    }

    /// The account the active Silo server projects to, which labels Silo rows in the index.
    @MainActor
    static func siloAccountKey() -> String? {
        ServerRegistry.shared.activeServerId.map { ProviderAccountRef.derived(kind: .silo, key: $0).description }
    }

    static func sources(_ accounts: [ProviderAccountRef]) -> [UnifiedProviderSource] {
        accounts.map { UnifiedProviderSource(account: $0.description) }
    }

    /// Opens a media-server title. Nil until a provider milestone supplies a detail screen; a card
    /// whose primary source is a media-server title then falls back to its IPTV alternate, if any.
    @MainActor static var detailPresenter: ((ContentRef) -> Void)?

    static func contentRef(account: String, contentID: String) -> ContentRef? {
        guard let ref = ProviderAccountRef(description: account) else { return nil }
        return try? ContentRef(account: ref, remoteID: contentID)
    }

    static func mediaKind(_ kind: XtreamVODKind) -> MediaKind { kind == .movie ? .movie : .series }

    /// Called by a future Jellyfin connection flow after registering the account and restoring
    /// or authenticating its per-account client. No existing Silo or IPTV path is changed.
    @MainActor
    static func registerJellyfinCatalog(account: ProviderAccountRef, client: JellyfinClient) throws {
        ProviderCatalogMirror.shared.register(try JellyfinProviderAdapter(account: account, client: client))
    }
}

/// Syncs the catalog of every media-server account that has a registered provider, into the
/// provider arm of the unified index. A registered account with no provider (offline, signed out
/// of that server, or a kind this build cannot reach yet) simply keeps its last synced titles.
@MainActor
@Observable
final class ProviderCatalogMirror {
    static let shared = ProviderCatalogMirror()

    /// Bumps when provider rows were published or purged, so browse grids re-read.
    private(set) var revision = 0
    /// Bumps when a provider is registered or removed, so grids reconfigure.
    private(set) var accountsRevision = 0
    /// "kind:account" walks currently running, for the grid's sync status.
    private(set) var syncing: Set<String> = []

    @ObservationIgnored private var providers: [String: any CatalogProviding] = [:]
    @ObservationIgnored private var epochs: [String: Int] = [:]
    @ObservationIgnored private var running: [String: Task<Bool, Never>] = [:]

    nonisolated static let freshness: TimeInterval = 6 * 60 * 60

    func isSyncing(kind: XtreamVODKind) -> Bool { syncing.contains { $0.hasPrefix(kind.rawValue + ":") } }

    /// Registers (or replaces) the catalog reader for an account. Walks of the previous reader stop.
    func register(_ provider: any CatalogProviding) {
        let key = provider.account.description
        invalidate(key)
        providers[key] = provider
        accountsRevision &+= 1
    }

    /// Forgets an account's reader and removes every title it contributed. Other accounts, Silo and
    /// IPTV rows, and the household's profiles are untouched.
    func remove(_ account: ProviderAccountRef, store: XtreamVODCatalogStore? = nil) async {
        let key = account.description
        invalidate(key)
        providers[key] = nil
        let target: XtreamVODCatalogStore?
        if let store { target = store } else { target = await XtreamVODService.shared.unifiedStore() }
        if let target { try? await target.purgeProvider(account: key) }
        revision &+= 1
        accountsRevision &+= 1
    }

    private func invalidate(_ key: String) {
        epochs[key, default: 0] &+= 1
        for (walk, task) in running where walk.hasSuffix(":" + key) { task.cancel() }
        running = running.filter { !$0.key.hasSuffix(":" + key) }
        syncing = syncing.filter { !$0.hasSuffix(":" + key) }
    }

    /// Walks each listed account's libraries that are stale (or all of them when `force`). Returns
    /// whether any part failed. An account with no registered reader is skipped without error.
    func sync(kind: XtreamVODKind, accounts: [String], force: Bool, store: XtreamVODCatalogStore? = nil) async -> Bool {
        let resolved: XtreamVODCatalogStore?
        if let store { resolved = store } else { resolved = await XtreamVODService.shared.unifiedStore() }
        guard let store = resolved else { return !accounts.isEmpty }
        var failed = false
        for account in accounts {
            guard !Task.isCancelled, let provider = providers[account] else { continue }
            let key = "\(kind.rawValue):\(account)"
            let task = running[key] ?? startWalk(key: key, account: account, provider: provider, kind: kind,
                                                 store: store, force: force)
            if await task.value { failed = true }
        }
        return failed
    }

    private func startWalk(key: String, account: String, provider: any CatalogProviding, kind: XtreamVODKind,
                           store: XtreamVODCatalogStore, force: Bool) -> Task<Bool, Never> {
        let startedEpoch = epochs[account, default: 0]
        let mediaKind = KyroProviderCatalogBridge.mediaKind(kind)
        let ref = provider.account
        let isCurrent: @Sendable () async -> Bool = { [weak self] in
            await MainActor.run { self?.epochs[account, default: 0] == startedEpoch && self?.providers[account] != nil }
        }
        let task = Task<Bool, Never> {
            let failed = await UnifiedProviderSyncEngine.syncAccount(
                store: store, account: account, kind: kind, freshness: force ? nil : Self.freshness,
                isCurrent: isCurrent,
                onProgress: { [weak self] in
                    await MainActor.run {
                        guard let self, self.epochs[account, default: 0] == startedEpoch else { return }
                        self.revision &+= 1
                    }
                },
                libraries: {
                    try await provider.libraries().filter { $0.kinds.contains(mediaKind) }.map(\.ref.remoteID)
                },
                first: { library in
                    Self.page(try await provider.catalogPage(library: try LibraryRef(account: ref, remoteID: library),
                                                             kind: mediaKind, cursor: nil), account: ref, kind: mediaKind)
                },
                next: { library, cursor in
                    Self.page(try await provider.catalogPage(library: try LibraryRef(account: ref, remoteID: library),
                                                             kind: mediaKind, cursor: cursor), account: ref, kind: mediaKind)
                })
            await MainActor.run {
                if self.epochs[account, default: 0] == startedEpoch { self.revision &+= 1 }
            }
            return failed
        }
        running[key] = task
        syncing.insert(key)
        Task {
            _ = await task.value
            if self.running[key] == task {
                self.running[key] = nil
                self.syncing.remove(key)
            }
        }
        return task
    }

    /// A page reduced to index records. A record of another account or kind is dropped, so a
    /// provider can never write into a neighbouring account's rows.
    private nonisolated static func page(_ page: ProviderCatalogPage, account: ProviderAccountRef,
                                         kind: MediaKind) -> UnifiedProviderSyncPage<String> {
        let records = page.records.compactMap { record -> UnifiedProviderRecord? in
            guard record.ref.account == account, record.kind == kind else { return nil }
            return UnifiedProviderRecord(contentID: record.ref.remoteID, title: record.title, year: record.year,
                                         poster: record.posterURL, payload: record.payload)
        }
        return UnifiedProviderSyncPage(records: records, next: page.next, startsOver: page.startsOver)
    }
}
#endif
