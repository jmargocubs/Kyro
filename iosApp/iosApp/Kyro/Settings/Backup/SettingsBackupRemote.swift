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
    /// A narrower scope (this device, a library or a series) holds a value that hides the
    /// profile row, so the profile value can't be read, compared or safely replaced.
    case overridden

    var errorDescription: String? {
        switch self {
        case .noVerifiedServer: "Connect to a server with a verified identity before backing up synced settings."
        case .noProfile: "Select a profile before backing up or restoring synced settings."
        case .destinationMismatch: "This backup belongs to a different server or profile. Synced settings were skipped."
        case .unsupportedValue: "The server returned a value or scope this Kyro version cannot safely transfer."
        case .timeout: "The server did not respond in time. The change was not confirmed."
        case .changedOwner: "The active server or profile changed. Synced settings were not written."
        case .unconfirmedWrite: "The server did not confirm the restored value."
        case .overridden: "A device, library or series override hides this profile setting, so it was left alone."
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

    func refreshUI() async {
        _ = await PlayerSettings.shared.refreshFromServer()
        await ThemeMusicPreferences.shared.refresh()
        await AdvisoryAgePreferenceStore.shared.refresh()
        await EpisodeSpoilerPreferences.shared.refresh()
        await SeekIntervalPreferences.shared.refresh()
    }

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
        guard case .available(let contract) = capabilities else {
            throw SettingsBackupRemoteError.unsupportedValue
        }
        // A batch fails as a whole on a key the server does not define, so newer keys are left out
        // of the request; the adapter reports each missing row as unsupported by this server.
        let served = keys.filter(contract.supports)
        guard !served.isEmpty else { throw SettingsBackupRemoteError.unsupportedValue }
        return try await api.getEffectiveValues(keys: served, requestIdentity: owner.request)
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

/// How a remote setting's value is carried in a backup. Every kind is a backup scalar, so the
/// schema-2 envelope, its size limits and its safety filter apply unchanged.
enum RemoteBackupValueKind: Equatable {
    case resolution
    case languageTag
    case subtitleLanguage
    case bool
    /// One of the contract's enum members, with its shared label.
    case choice([(value: String, label: String)])
    /// An integer in a contract range. `nullable` lets JSON null ("No limit") be explicit.
    case integer(ClosedRange<Int>, nullable: Bool)
    /// An integer that must be one of the contract's listed values (the seek intervals).
    case intChoice([Int])
    /// A nullable language tag with no fixed list (`catalog.metadata_language`).
    case metadataLanguage
    /// `player.playback_speed` (0.25…3.0, step 0.05) as whole hundredths: 125 means 1.25×.
    /// A backup holds no floating-point values, so the grid is exact.
    case speedHundredths

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.resolution, .resolution), (.languageTag, .languageTag),
             (.subtitleLanguage, .subtitleLanguage), (.bool, .bool), (.speedHundredths, .speedHundredths),
             (.metadataLanguage, .metadataLanguage):
            return true
        case (.choice(let a), .choice(let b)): return a.map(\.value) == b.map(\.value)
        case (.integer(let a, let x), .integer(let b, let y)): return a == b && x == y
        case (.intChoice(let a), .intChoice(let b)): return a == b
        default: return false
        }
    }
}

/// The API-backed settings in the unified backup. Each one is a single scalar key with one
/// authoritative scope; it is read through the batched effective-settings API and written with
/// `putValue`/`deleteValue` at that scope. Settings whose scope can move (subtitle appearance and
/// timing), composite records and catalog-bound IDs are deliberately absent.
enum RemoteBackupDefinition: CaseIterable {
    case resolution, audioLanguage, subtitleLanguage
    // Batch 1: profile-device scalar playback and interface preferences.
    case maxBitrate, bufferingQuality, hdr, dolbyVision
    case introSkip, skipCredits, autoPlayNext, nextUpPrompt
    case playbackSpeed, videoSizing, orientation, seekCache
    case themeMusic, themeMusicLoop
    // Batch 2: profile-scope scalars.
    case advisoryAge, hideEpisodeImages, hideEpisodeDescriptions
    case videoSkipBack, videoSkipForward, audiobookSkipBack, audiobookSkipForward
    case subtitleMode, forcedSubtitles, metadataLanguage

    /// Stable, platform-neutral backup IDs. They must pass `SettingsBackupSafety.isSensitiveName`,
    /// so the seek cache uses `fastSeeking` rather than the word "cache".
    var id: String {
        switch self {
        case .resolution: "streaming.resolution"
        case .audioLanguage: "streaming.audioLanguage"
        case .subtitleLanguage: "subtitles.language"
        case .maxBitrate: "streaming.maxBitrate"
        case .bufferingQuality: "streaming.bufferingQuality"
        case .hdr: "streaming.hdr"
        case .dolbyVision: "streaming.dolbyVision"
        case .introSkip: "player.introSkip"
        case .skipCredits: "player.skipCredits"
        case .autoPlayNext: "player.autoPlayNext"
        case .nextUpPrompt: "player.nextUpSeconds"
        case .playbackSpeed: "player.speedHundredths"
        case .videoSizing: "player.videoSizing"
        case .orientation: "player.orientation"
        case .seekCache: "player.fastSeeking"
        case .themeMusic: "interface.themeMusic"
        case .themeMusicLoop: "interface.themeMusicLoop"
        case .advisoryAge: "interface.advisoryAge"
        case .hideEpisodeImages: "interface.hideEpisodeImages"
        case .hideEpisodeDescriptions: "interface.hideEpisodeDescriptions"
        case .videoSkipBack: "player.videoSkipBackSeconds"
        case .videoSkipForward: "player.videoSkipForwardSeconds"
        case .audiobookSkipBack: "player.audiobookSkipBackSeconds"
        case .audiobookSkipForward: "player.audiobookSkipForwardSeconds"
        case .subtitleMode: "subtitles.mode"
        case .forcedSubtitles: "subtitles.showForced"
        case .metadataLanguage: "subtitles.metadataLanguage"
        }
    }

    var group: SettingsBackupGroup {
        switch self {
        case .resolution, .audioLanguage, .maxBitrate, .bufferingQuality, .hdr, .dolbyVision: .streaming
        case .subtitleLanguage, .subtitleMode, .forcedSubtitles, .metadataLanguage: .subtitles
        case .introSkip, .skipCredits, .autoPlayNext, .nextUpPrompt, .playbackSpeed, .videoSizing,
             .orientation, .seekCache, .videoSkipBack, .videoSkipForward, .audiobookSkipBack,
             .audiobookSkipForward: .player
        case .themeMusic, .themeMusicLoop, .advisoryAge, .hideEpisodeImages,
             .hideEpisodeDescriptions: .interface
        }
    }

    var title: String {
        switch self {
        case .resolution: "Playback resolution"
        case .audioLanguage: "Audio language"
        case .subtitleLanguage: "Subtitle language"
        case .maxBitrate: "Maximum bitrate"
        case .bufferingQuality: "Lower quality when buffering"
        case .hdr: "HDR"
        case .dolbyVision: "Dolby Vision"
        case .introSkip: "Skip intros"
        case .skipCredits: "Skip credits"
        case .autoPlayNext: "Auto-play next episode"
        case .nextUpPrompt: "Show Next Up"
        case .playbackSpeed: "Playback speed"
        case .videoSizing: "Video sizing"
        case .orientation: "Player orientation"
        case .seekCache: "Seek cache"
        case .themeMusic: "Theme music"
        case .themeMusicLoop: "Loop theme music"
        case .advisoryAge: "Show advisory age"
        case .hideEpisodeImages: "Blur unwatched episode images"
        case .hideEpisodeDescriptions: "Hide unwatched episode descriptions"
        case .videoSkipBack: "Video skip back"
        case .videoSkipForward: "Video skip forward"
        case .audiobookSkipBack: "Audiobook skip back"
        case .audiobookSkipForward: "Audiobook skip forward"
        case .subtitleMode: "Subtitle behavior"
        case .forcedSubtitles: "Show forced subtitles"
        case .metadataLanguage: "Metadata language"
        }
    }

    var key: SettingKey {
        switch self {
        case .resolution: .playbackPreferredQuality
        case .audioLanguage: .playbackAudioLanguage
        case .subtitleLanguage: .playbackSubtitleLanguage
        case .maxBitrate: .playbackMaxBitrateKbps
        case .bufferingQuality: .playbackBufferingQualityMode
        case .hdr: .playerHdrEnabled
        case .dolbyVision: .playerDolbyVisionEnabled
        case .introSkip: .playbackIntroSkipMode
        case .skipCredits: .playbackAutoSkipCredits
        case .autoPlayNext: .playbackAutoPlayNext
        case .nextUpPrompt: .playbackNextUpPromptSeconds
        case .playbackSpeed: .playerPlaybackSpeed
        case .videoSizing: .playerVideoGravity
        case .orientation: .playerOrientationMode
        case .seekCache: .playerSeekCacheEnabled
        case .themeMusic: .uiThemeMusicEnabled
        case .themeMusicLoop: .uiThemeMusicLoop
        case .advisoryAge: .catalogShowAdvisoryAge
        case .hideEpisodeImages: .catalogHideUnwatchedEpisodeImages
        case .hideEpisodeDescriptions: .catalogHideUnwatchedEpisodeOverviews
        case .videoSkipBack: .playerVideoSkipBackSeconds
        case .videoSkipForward: .playerVideoSkipForwardSeconds
        case .audiobookSkipBack: .playerAudiobookSkipBackSeconds
        case .audiobookSkipForward: .playerAudiobookSkipForwardSeconds
        case .subtitleMode: .playbackSubtitleMode
        case .forcedSubtitles: .playbackShowForcedSubtitles
        case .metadataLanguage: .catalogMetadataLanguage
        }
    }

    /// Batch 1 and the audio/resolution settings are per device; subtitle and library-wide
    /// preferences (and the skip intervals) belong to the profile.
    var scope: SettingScopeIdentity {
        switch self {
        case .subtitleLanguage, .subtitleMode, .forcedSubtitles, .metadataLanguage, .advisoryAge,
             .hideEpisodeImages, .hideEpisodeDescriptions, .videoSkipBack, .videoSkipForward,
             .audiobookSkipBack, .audiobookSkipForward: .profile
        default: .profileDevice
        }
    }
    var expectedScope: SettingScope { scope.scope }

    /// Keys newer than the oldest supported server (`SettingKey.minimumServerRevision`). An older
    /// server does not serve them, so they are omitted from its export and skipped on its restore
    /// instead of failing the whole backup. A test pins this to `SettingKey.isNewerThanMinimumServer`.
    var requiresCapability: Bool {
        switch self {
        case .bufferingQuality, .themeMusic, .themeMusicLoop, .advisoryAge, .hideEpisodeImages,
             .hideEpisodeDescriptions, .videoSkipBack, .videoSkipForward, .audiobookSkipBack,
             .audiobookSkipForward: true
        default: false
        }
    }

    var kind: RemoteBackupValueKind {
        switch self {
        case .resolution: .resolution
        case .audioLanguage: .languageTag
        case .subtitleLanguage: .subtitleLanguage
        case .maxBitrate: .integer(100...200_000, nullable: true)
        case .nextUpPrompt: .integer(0...120, nullable: false)
        case .playbackSpeed: .speedHundredths
        case .hdr, .dolbyVision, .skipCredits, .autoPlayNext, .seekCache, .themeMusic, .themeMusicLoop,
             .advisoryAge, .hideEpisodeImages, .hideEpisodeDescriptions, .forcedSubtitles: .bool
        case .videoSkipBack, .videoSkipForward, .audiobookSkipBack, .audiobookSkipForward:
            .intChoice(Self.seekChoices)
        case .metadataLanguage: .metadataLanguage
        case .subtitleMode: .choice([("auto", "Auto"), ("always", "Always"), ("off", "Off")])
        // The contract's enum members and shared labels. Tests pin them to the production enums
        // (`BufferingQualityMode`, `IntroSkipMode`, `VideoGravity`, `PlayerOrientationMode`).
        case .bufferingQuality:
            .choice([("never", "Never"), ("ask", "Ask first"), ("always", "Automatically")])
        case .introSkip:
            .choice([("never", "Never"), ("ask", "Ask to skip"), ("always", "Skip automatically")])
        case .videoSizing:
            .choice([("fit", "Fit"), ("fill", "Fill"), ("stretch", "Stretch")])
        case .orientation:
            .choice([("landscapeLocked", "Landscape locked"), ("rotateFreely", "Rotate freely")])
        }
    }

    /// `SeekIntervalContract.choices`; a test pins the two together.
    static let seekChoices = [5, 10, 15, 30, 45, 60, 90]

    /// The reserved value distinguishes an inherited row from an explicit value.
    static let inherited = "~inherit"
    /// An explicit JSON null, for a key whose contract allows one.
    static let null = "~null"

    static func definition(id: String) -> RemoteBackupDefinition? { allCases.first { $0.id == id } }
    static var ids: Set<String> { Set(allCases.map(\.id)) }
    static var groups: [SettingsBackupGroup] {
        var seen: [SettingsBackupGroup] = []
        for definition in allCases where !seen.contains(definition.group) { seen.append(definition.group) }
        return seen
    }

    var allowsNull: Bool {
        switch kind {
        case .subtitleLanguage, .metadataLanguage: true
        case .integer(_, let nullable): nullable
        default: false
        }
    }

    func validate(_ value: BackupValue) -> Bool {
        if case .string(let raw) = value {
            if raw == Self.inherited { return true }
            if raw == Self.null { return allowsNull }
        }
        switch (kind, value) {
        case (.resolution, .string(let raw)): return SiloQualityPresets.resolutionChoices.contains(raw)
        case (.languageTag, .string(let raw)): return Self.isPortableLanguageTag(raw)
        case (.subtitleLanguage, .string(let raw)), (.metadataLanguage, .string(let raw)):
            return !raw.isEmpty && raw.count <= 32
                && raw.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0)
                    || (48...57).contains($0) || $0 == 45 }
        case (.bool, .bool): return true
        case (.choice(let options), .string(let raw)): return options.contains { $0.value == raw }
        case (.integer(let range, _), .int(let number)): return range.contains(number)
        case (.intChoice(let allowed), .int(let number)): return allowed.contains(number)
        case (.speedHundredths, .int(let number)): return (25...300).contains(number) && number % 5 == 0
        default: return false
        }
    }

    /// The authoritative value of the row this definition writes. A row from any other scope means
    /// the destination row is absent; for the profile-device settings that is "inherited".
    func snapshot(_ row: EffectiveSettingValue) throws -> BackupValue {
        guard row.key == key.rawValue else { throw SettingsBackupRemoteError.unsupportedValue }
        guard row.scope == expectedScope else {
            // A contract default, or an account/profile row under a device setting, is inherited.
            // For the profile-scoped setting, a higher-precedence row hides the profile row, which
            // therefore cannot be read or safely replaced.
            if row.scope == nil || expectedScope == .profileDevice || row.scope == .account {
                return .string(Self.inherited)
            }
            // A profile setting whose winning row is a device, client, library or series
            // override. That row belongs to someone else's scope; it is never read as the
            // profile value and never overwritten.
            if expectedScope == .profile, let other = row.scope, other != .profile {
                throw SettingsBackupRemoteError.overridden
            }
            throw SettingsBackupRemoteError.unsupportedValue
        }
        guard row.profileId == nil || !row.profileId!.isEmpty else {
            throw SettingsBackupRemoteError.unsupportedValue
        }
        let result: BackupValue
        switch (kind, row.storedValue ?? row.value) {
        case (.subtitleLanguage, .null), (.metadataLanguage, .null): result = .string(Self.null)
        // No audio preference on this device means no device override.
        case (.languageTag, .null): result = .string(Self.inherited)
        case (.integer(_, nullable: true), .null): result = .string(Self.null)
        case (.resolution, .string(let raw)), (.languageTag, .string(let raw)),
             (.subtitleLanguage, .string(let raw)), (.metadataLanguage, .string(let raw)),
             (.choice, .string(let raw)):
            result = .string(raw)
        case (.bool, .bool(let flag)): result = .bool(flag)
        case (.integer, let wire), (.intChoice, let wire):
            guard let number = wire.intValue else { throw SettingsBackupRemoteError.unsupportedValue }
            result = .int(number)
        case (.speedHundredths, let wire):
            guard let rate = wire.doubleValue, rate.isFinite else { throw SettingsBackupRemoteError.unsupportedValue }
            let hundredths = (rate * 100).rounded()
            // Off-grid values were never accepted by the server; refuse rather than round silently.
            guard abs(rate * 100 - hundredths) < 0.001 else { throw SettingsBackupRemoteError.unsupportedValue }
            result = .int(Int(hundredths))
        default: throw SettingsBackupRemoteError.unsupportedValue
        }
        guard validate(result) else { throw SettingsBackupRemoteError.unsupportedValue }
        return result
    }

    /// The JSON value to PUT, or nil to delete the destination row (inherit).
    func wireValue(_ value: BackupValue) throws -> SettingJSONValue? {
        guard validate(value) else { throw SettingsBackupRemoteError.unsupportedValue }
        switch value {
        case .string(Self.inherited): return nil
        case .string(Self.null): return .null
        case .string(let raw): return .string(raw)
        case .bool(let flag): return .bool(flag)
        case .int(let number):
            if kind == .speedHundredths { return .double(Double(number) / 100) }
            return .int(number)
        }
    }

    func label(_ value: BackupValue) -> String {
        if case .string(let raw) = value {
            if raw == Self.inherited { return "Use inherited setting" }
            if raw == Self.null {
                return self == .maxBitrate ? "No limit" : self == .metadataLanguage ? "Library default" : "No preference"
            }
        }
        switch (kind, value) {
        case (.resolution, .string(let raw)): return SiloQualityPresets.resolutionLabel(raw)
        case (.languageTag, .string(let raw)): return raw == "x-silo-original" ? "Original language" : raw
        case (.intChoice, .int(let number)): return "\(number) seconds"
        case (.choice(let options), .string(let raw)): return options.first { $0.value == raw }?.label ?? raw
        case (.integer, .int(let number)):
            if self == .maxBitrate { return Self.bitrateLabel(number) }
            // The Playback screen's wording: "At end", "30 seconds before end", "1 minute before end".
            if self == .nextUpPrompt {
                if number == 0 { return "At end" }
                if number % 60 == 0 { return number == 60 ? "1 minute before end" : "\(number / 60) minutes before end" }
                return "\(number) seconds before end"
            }
            return String(number)
        case (.speedHundredths, .int(let number)):
            let rate = Double(number) / 100
            return rate == 1 ? "Normal (1×)" : String(format: "%g×", rate)
        default: return value.plainText
        }
    }

    private static func bitrateLabel(_ kbps: Int) -> String {
        kbps >= 1000 ? String(format: "%g Mbps", Double(kbps) / 1000) : "\(kbps) Kbps"
    }

    private static func isPortableLanguageTag(_ raw: String) -> Bool {
        guard !raw.isEmpty, raw.count <= 64,
              raw.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
                  || (48...57).contains($0) || $0 == 45 }) else { return false }
        guard raw != "x-silo-original" else { return true }
        let subtags = raw.split(separator: "-", omittingEmptySubsequences: false)
        guard let language = subtags.first, (2...8).contains(language.count),
              language.allSatisfy({ $0.isASCII && $0.isLetter }),
              subtags.dropFirst().allSatisfy({ (1...8).contains($0.count) }) else { return false }
        return true
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

/// Only `RemoteBackupDefinition` settings are allowlisted. Other server settings remain unsupported
/// until their type, scope, refresh and Undo rules are individually verified.
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

    /// Backup IDs and groups this adapter owns; the model routes them here instead of to the local
    /// registry.
    nonisolated static var settingIDs: Set<String> { RemoteBackupDefinition.ids }
    nonisolated static var groups: [SettingsBackupGroup] { RemoteBackupDefinition.groups }

    var undoAvailable: Bool { (try? journal.load()) != nil }
    var needsRecovery: Bool { (try? journal.load())?.state == .applying }

    func refreshUI() async { await transport.refreshUI() }

    /// `omitted` lists settings left out of the file, each with the precise reason, so the UI can
    /// say what the backup does not contain.
    func export() async throws -> (scope: SettingsBackupScope, groups: [String: [String: BackupValue]],
                                   omitted: [String]) {
        try await timed { try await self.transport.prepare() }
        let owner = try await timed { try await self.transport.owner() }
        let rows = try await read(owner)
        var groups: [String: [String: BackupValue]] = [:]
        var omitted: [String] = []
        for definition in RemoteBackupDefinition.allCases {
            guard let row = rows[definition.key] else {
                // A key newer than this server is not part of its settings; anything else missing
                // means the read was incomplete, and an incomplete backup must not be written.
                if definition.requiresCapability {
                    omitted.append("\(definition.title) (this server doesn't support it)")
                    continue
                }
                throw SettingsBackupRemoteError.unsupportedValue
            }
            do {
                groups[definition.group.rawValue, default: [:]][definition.id] = try definition.snapshot(row)
            } catch SettingsBackupRemoteError.overridden {
                // The profile value is hidden by a narrower override. Exporting the override as the
                // profile value would restore the wrong thing, so the setting is left out.
                omitted.append("\(definition.title) (hidden by a device, library or series override)")
            }
        }
        return (owner.scope, groups, omitted)
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
        return RemoteBackupDefinition.groups.compactMap { group in
            let items: [RestorePreviewItem] = present.filter { $0.group == group }.map { definition in
                let value = incoming.groups[group.rawValue]![definition.id]!
                let row = current[definition.key]
                let existing = row.flatMap { try? definition.snapshot($0) }
                var overridden = false
                if let row, existing == nil {
                    do { _ = try definition.snapshot(row) }
                    catch SettingsBackupRemoteError.overridden { overridden = true }
                    catch {}
                }
                let status: RestoreItemStatus
                if !definition.validate(value) { status = .invalid("This value is not supported.") }
                else if let reason { status = .unsupported(reason) }
                else if row == nil && definition.requiresCapability {
                    status = .unsupported("This server doesn't support this setting.")
                }
                else if row == nil { status = .unsupported("Kyro could not read the authoritative value.") }
                else if overridden {
                    status = .unsupported(SettingsBackupRemoteError.overridden.localizedDescription)
                }
                else if existing == nil {
                    status = .unsupported("The server's current value can't be compared or restored safely.")
                }
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
                let previous: BackupValue
                do { previous = try definition.snapshot(row) }
                catch SettingsBackupRemoteError.overridden {
                    // Hidden by a narrower override: leave it alone and say so.
                    report.skipped.append(definition.id); continue
                }
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
                guard let definition = RemoteBackupDefinition.definition(id: change.id) else {
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
