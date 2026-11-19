#if os(iOS) || KYRO_STANDALONE_TESTS
import CryptoKit
import Foundation

/// A captured authenticated destination. Only its one-way fingerprints leave this process.
struct SettingsBackupRemoteOwner: Sendable {
    let request: HTTPRequestIdentity
    let scope: SettingsBackupScope
}

protocol SettingsBackupRemoteTransport: Sendable {
    func prepare() async throws
    func owner() async throws -> SettingsBackupRemoteOwner
    func read(_ keys: [SettingKey], owner: SettingsBackupRemoteOwner) async throws -> EffectiveSettingValuesResponse
    func put(_ key: SettingKey, scope: SettingScopeIdentity, value: SettingJSONValue,
             owner: SettingsBackupRemoteOwner) async throws
    func delete(_ key: SettingKey, scope: SettingScopeIdentity,
                owner: SettingsBackupRemoteOwner) async throws
    func refreshUI() async
}

extension SettingsBackupRemoteTransport {
    func prepare() async throws {}
    func refreshUI() async {}
}

enum SettingsBackupRemoteError: LocalizedError {
    case noVerifiedServer
    case noProfile
    case destinationMismatch
    case unsupportedValue
    case timeout
    case changedOwner
    case unconfirmedWrite

    var errorDescription: String? {
        switch self {
        case .noVerifiedServer: "Connect to a server with a verified identity before backing up synced settings."
        case .noProfile: "Select a profile before backing up or restoring synced settings."
        case .destinationMismatch: "This backup belongs to a different server or profile. Synced settings were skipped."
        case .unsupportedValue: "The server returned a value or scope this Kyro version cannot safely transfer."
        case .timeout: "The server did not respond in time. The change was not confirmed."
        case .changedOwner: "The active server or profile changed. Synced settings were not written."
        case .unconfirmedWrite: "The server did not confirm the restored value."
        }
    }
}

/// Production transport uses the same authenticated, owner-pinned API as the Settings screens.
#if os(iOS)
struct SiloSettingsBackupTransport: SettingsBackupRemoteTransport {
    let api: SiloAPI
    init(api: SiloAPI = .shared) { self.api = api }

    func prepare() async throws {
        await PlayerSettings.shared.flushPendingDeviceSettings()
        let hasPending = await MainActor.run { PlayerSettings.shared.hasUnsettledSettingsWrites }
        if hasPending { throw SettingsBackupRemoteError.unconfirmedWrite }
    }

    func refreshUI() async { _ = await PlayerSettings.shared.refreshFromServer() }

    func owner() async throws -> SettingsBackupRemoteOwner {
        let entry = await MainActor.run { ServerRegistry.shared.activeServer }
        guard let entry, let verified = entry.verifiedServerId, !verified.isEmpty else {
            throw SettingsBackupRemoteError.noVerifiedServer
        }
        guard let profile = await api.currentProfileId(), !profile.isEmpty else {
            throw SettingsBackupRemoteError.noProfile
        }
        let request = HTTPRequestIdentity(serverId: entry.id, serverURL: entry.url,
                                          profileId: profile, clientFamily: AppleDeviceIdentity.current.clientFamily)
        return SettingsBackupRemoteOwner(
            request: request,
            scope: SettingsBackupScope(
                serverFingerprint: Self.fingerprint("kyro-server-v2|\(verified)"),
                profileFingerprint: Self.fingerprint("kyro-profile-v2|\(verified)|\(profile)")))
    }

    func read(_ keys: [SettingKey], owner: SettingsBackupRemoteOwner) async throws -> EffectiveSettingValuesResponse {
        let capabilities = await api.getContractCapabilities(requestIdentity: owner.request)
        guard case .available(let contract) = capabilities, keys.allSatisfy(contract.supports) else {
            throw SettingsBackupRemoteError.unsupportedValue
        }
        return try await api.getEffectiveValues(keys: keys, requestIdentity: owner.request)
    }

    func put(_ key: SettingKey, scope: SettingScopeIdentity, value: SettingJSONValue,
             owner: SettingsBackupRemoteOwner) async throws {
        _ = try await api.putValue(key: key, scope: scope, value: value,
                                   profileId: owner.request.profileId, requestIdentity: owner.request)
    }

    func delete(_ key: SettingKey, scope: SettingScopeIdentity,
                owner: SettingsBackupRemoteOwner) async throws {
        do {
            try await api.deleteValue(key: key, scope: scope,
                                      profileId: owner.request.profileId, requestIdentity: owner.request)
        } catch SettingsAPIError.noValueAtScope {
            // Already inherited at this scope.
        }
    }

    private static func fingerprint(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
#endif

private enum RemoteBackupDefinition: CaseIterable {
    case resolution, subtitleLanguage

    var id: String {
        switch self {
        case .resolution: "streaming.resolution"
        case .subtitleLanguage: "subtitles.language"
        }
    }
    var group: SettingsBackupGroup {
        switch self {
        case .resolution: .streaming
        case .subtitleLanguage: .subtitles
        }
    }
    var title: String {
        switch self {
        case .resolution: "Playback resolution"
        case .subtitleLanguage: "Subtitle language"
        }
    }
    var key: SettingKey {
        switch self {
        case .resolution: .playbackPreferredQuality
        case .subtitleLanguage: .playbackSubtitleLanguage
        }
    }
    var scope: SettingScopeIdentity {
        switch self {
        case .resolution: .profileDevice
        case .subtitleLanguage: .profile
        }
    }
    var expectedScope: SettingScope { scope.scope }

    /// The two reserved values distinguish an inherited row from an explicit JSON null.
    static let inherited = "~inherit"
    static let null = "~null"

    func validate(_ value: BackupValue) -> Bool {
        guard case .string(let raw) = value else { return false }
        if raw == Self.inherited { return true }
        switch self {
        case .resolution: return SiloQualityPresets.resolutionChoices.contains(raw)
        case .subtitleLanguage:
            if raw == Self.null { return true }
            return !raw.isEmpty && raw.count <= 32
                && raw.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0)
                    || (48...57).contains($0) || $0 == 45 }
        }
    }

    func snapshot(_ row: EffectiveSettingValue) throws -> BackupValue {
        guard row.key == key.rawValue else { throw SettingsBackupRemoteError.unsupportedValue }
        if row.scope == expectedScope {
            guard row.profileId == nil || !row.profileId!.isEmpty else {
                throw SettingsBackupRemoteError.unsupportedValue
            }
            let authored = row.storedValue ?? row.value
            switch authored {
            case .string(let raw):
                let result = BackupValue.string(raw)
                guard validate(result) else { throw SettingsBackupRemoteError.unsupportedValue }
                return result
            case .null where self == .subtitleLanguage: return .string(Self.null)
            default: throw SettingsBackupRemoteError.unsupportedValue
            }
        }
        // A lower-scope or contract default must remain inherited. A higher-scope answer
        // cannot be treated as the value of the row this adapter writes.
        if row.scope == nil || row.scope == .profile && self == .resolution {
            return .string(Self.inherited)
        }
        throw SettingsBackupRemoteError.unsupportedValue
    }

    func wireValue(_ value: BackupValue) throws -> SettingJSONValue? {
        guard validate(value), case .string(let raw) = value else {
            throw SettingsBackupRemoteError.unsupportedValue
        }
        if raw == Self.inherited { return nil }
        if raw == Self.null { return .null }
        return .string(raw)
    }

    func label(_ value: BackupValue) -> String {
        guard case .string(let raw) = value else { return value.plainText }
        if raw == Self.inherited { return "Use inherited setting" }
        if raw == Self.null { return "No preference" }
        return self == .resolution ? SiloQualityPresets.resolutionLabel(raw) : raw
    }
}

struct RemoteBackupChange: Codable, Equatable {
    let id: String
    let previous: BackupValue
    let applied: BackupValue
}

struct RemoteBackupJournal: Codable {
    let scope: SettingsBackupScope
    var changes: [RemoteBackupChange]
    var state: State
    enum State: String, Codable { case applying, applied }
}

protocol RemoteBackupJournalStoring: AnyObject {
    func load() throws -> RemoteBackupJournal?
    func save(_ journal: RemoteBackupJournal) throws
    func clear() throws
}

final class FileRemoteBackupJournal: RemoteBackupJournalStoring {
    private let url: URL
    init(url: URL) { self.url = url }
    static func standard() -> FileRemoteBackupJournal {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return FileRemoteBackupJournal(url: base.appendingPathComponent("SettingsBackup/remote-restore-point.json"))
    }
    func load() throws -> RemoteBackupJournal? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard data.count < SettingsBackupSafety.maxFileBytes else { throw SettingsBackupError.tooLarge }
        return try JSONDecoder().decode(RemoteBackupJournal.self, from: data)
    }
    func save(_ journal: RemoteBackupJournal) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try JSONEncoder().encode(journal).write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try JSONEncoder().encode(journal).write(to: url, options: .atomic)
        #endif
    }
    func clear() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

struct RemoteBackupApplyReport {
    var applied: [String] = []
    var failed: [String] = []
    var skipped: [String] = []
}

/// Only the two audited scalar API settings are currently allowlisted. Other server settings
/// remain unsupported until their type, scope, refresh and Undo rules are individually verified.
@MainActor
final class SettingsBackupRemoteAdapter {
    private let transport: SettingsBackupRemoteTransport
    private let journal: RemoteBackupJournalStoring
    private let timeout: Duration

    init(transport: SettingsBackupRemoteTransport, journal: RemoteBackupJournalStoring,
         timeout: Duration = .seconds(12)) {
        self.transport = transport
        self.journal = journal
        self.timeout = timeout
    }

    var undoAvailable: Bool { (try? journal.load()) != nil }
    var needsRecovery: Bool { (try? journal.load())?.state == .applying }

    func refreshUI() async { await transport.refreshUI() }

    func export() async throws -> (scope: SettingsBackupScope, groups: [String: [String: BackupValue]]) {
        try await timed { try await self.transport.prepare() }
        let owner = try await timed { try await self.transport.owner() }
        let rows = try await read(owner)
        var groups: [String: [String: BackupValue]] = [:]
        for definition in RemoteBackupDefinition.allCases {
            guard let row = rows[definition.key] else { throw SettingsBackupRemoteError.unsupportedValue }
            groups[definition.group.rawValue, default: [:]][definition.id] = try definition.snapshot(row)
        }
        return (owner.scope, groups)
    }

    func preview(_ incoming: IncomingBackup) async -> [RestorePreviewGroup] {
        let present = RemoteBackupDefinition.allCases.filter {
            incoming.groups[$0.group.rawValue]?[$0.id] != nil
        }
        guard !present.isEmpty else { return [] }
        var reason: String?
        var current: [SettingKey: EffectiveSettingValue] = [:]
        do {
            try await timed { try await self.transport.prepare() }
            let owner = try await timed { try await self.transport.owner() }
            guard owner.scope == incoming.scope else { throw SettingsBackupRemoteError.destinationMismatch }
            current = try await read(owner)
        } catch { reason = error.localizedDescription }
        return [SettingsBackupGroup.streaming, .subtitles].compactMap { group in
            let items: [RestorePreviewItem] = present.filter { $0.group == group }.map { definition in
                let value = incoming.groups[group.rawValue]![definition.id]!
                let existing = current[definition.key].flatMap { try? definition.snapshot($0) }
                let status: RestoreItemStatus
                if !definition.validate(value) { status = .invalid("This value is not supported.") }
                else if let reason { status = .unsupported(reason) }
                else if existing == nil { status = .unsupported("Kyro could not read the authoritative value.") }
                else if existing == value { status = .unchanged }
                else { status = .willChange }
                return RestorePreviewItem(id: definition.id, group: group, title: definition.title,
                                          current: existing.map(definition.label), incoming: definition.label(value),
                                          status: status, incomingValue: value)
            }
            return items.isEmpty ? nil : RestorePreviewGroup(group: group, items: items, groupUnsupportedReason: nil)
        }
    }

    func apply(_ incoming: IncomingBackup, selectedIDs: Set<String>) async -> RemoteBackupApplyReport {
        let definitions = RemoteBackupDefinition.allCases.filter { selectedIDs.contains($0.id) }
        guard !definitions.isEmpty else { return RemoteBackupApplyReport() }
        var report = RemoteBackupApplyReport()
        do {
            guard !needsRecovery else { throw SettingsBackupRemoteError.unconfirmedWrite }
            try await timed { try await self.transport.prepare() }
            let owner = try await timed { try await self.transport.owner() }
            guard owner.scope == incoming.scope else { throw SettingsBackupRemoteError.destinationMismatch }
            let current = try await read(owner)
            var changes: [RemoteBackupChange] = []
            for definition in definitions {
                guard let desired = incoming.groups[definition.group.rawValue]?[definition.id],
                      definition.validate(desired), let row = current[definition.key] else {
                    report.skipped.append(definition.id); continue
                }
                let previous = try definition.snapshot(row)
                if previous != desired {
                    changes.append(RemoteBackupChange(id: definition.id, previous: previous, applied: desired))
                }
            }
            guard !changes.isEmpty else { return report }
            var record = RemoteBackupJournal(scope: owner.scope, changes: changes, state: .applying)
            try journal.save(record)
            for change in changes {
                guard let definition = definitions.first(where: { $0.id == change.id }) else { continue }
                do {
                    try Task.checkCancellation()
                    try await write(definition, value: change.applied, owner: owner)
                    let confirmed = try await read(owner)
                    guard let row = confirmed[definition.key], try definition.snapshot(row) == change.applied else {
                        throw SettingsBackupRemoteError.unconfirmedWrite
                    }
                    report.applied.append(change.id)
                } catch {
                    report.failed.append(change.id)
                    break
                }
            }
            if report.failed.isEmpty { record.state = .applied; try journal.save(record) }
        } catch {
            if report.failed.isEmpty { report.failed = definitions.map(\.id) }
        }
        return report
    }

    func undo() async -> RemoteBackupApplyReport {
        var report = RemoteBackupApplyReport()
        guard var record = try? journal.load() else { return report }
        do {
            let owner = try await timed { try await self.transport.owner() }
            guard owner.scope == record.scope else { throw SettingsBackupRemoteError.destinationMismatch }
            var remaining: [RemoteBackupChange] = []
            for change in record.changes.reversed() {
                guard let definition = RemoteBackupDefinition.allCases.first(where: { $0.id == change.id }) else {
                    report.skipped.append(change.id); continue
                }
                do {
                    let current = try await read(owner)
                    guard let row = current[definition.key] else { throw SettingsBackupRemoteError.unsupportedValue }
                    let value = try definition.snapshot(row)
                    if value == change.previous { continue }
                    guard value == change.applied else { report.skipped.append(change.id); continue }
                    try await write(definition, value: change.previous, owner: owner)
                    let confirmed = try await read(owner)
                    guard let result = confirmed[definition.key], try definition.snapshot(result) == change.previous else {
                        throw SettingsBackupRemoteError.unconfirmedWrite
                    }
                    report.applied.append(change.id)
                } catch {
                    report.failed.append(change.id)
                    remaining.append(change)
                }
            }
            if remaining.isEmpty { try journal.clear() }
            else { record.changes = remaining.reversed(); try journal.save(record) }
        } catch { report.failed = record.changes.map(\.id) }
        return report
    }

    private func read(_ owner: SettingsBackupRemoteOwner) async throws -> [SettingKey: EffectiveSettingValue] {
        let response = try await timed {
            try await self.transport.read(RemoteBackupDefinition.allCases.map(\.key), owner: owner)
        }
        return response.byKey
    }

    private func write(_ definition: RemoteBackupDefinition, value: BackupValue,
                       owner: SettingsBackupRemoteOwner) async throws {
        let currentOwner = try await timed { try await self.transport.owner() }
        guard currentOwner.scope == owner.scope, currentOwner.request == owner.request else {
            throw SettingsBackupRemoteError.changedOwner
        }
        if let wire = try definition.wireValue(value) {
            try await timed { try await self.transport.put(definition.key, scope: definition.scope,
                                                           value: wire, owner: owner) }
        } else {
            try await timed { try await self.transport.delete(definition.key, scope: definition.scope,
                                                              owner: owner) }
        }
    }

    private func timed<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: self.timeout)
                throw SettingsBackupRemoteError.timeout
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw SettingsBackupRemoteError.timeout }
            return result
        }
    }
}
#endif
