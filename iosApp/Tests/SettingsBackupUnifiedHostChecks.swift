#if KYRO_STANDALONE_TESTS
import Foundation

// Minimal wire-model stubs let the production backup adapter and model run on macOS without an
// iOS Simulator, a server, or the rest of the app. iOS XCTest uses the real wire models instead.
struct HTTPRequestIdentity: Equatable, Sendable {
    let serverId: String
    let serverURL: String
    let profileId: String
    let clientFamily: String
}
enum SettingKey: String, Hashable, Sendable, CaseIterable {
    case playbackPreferredQuality = "playback.preferred_quality"
    case playbackAudioLanguage = "playback.audio_language"
    case playbackSubtitleLanguage = "playback.subtitle_language"
    case playbackMaxBitrateKbps = "playback.max_bitrate_kbps"
    case playbackBufferingQualityMode = "playback.buffering_quality_mode"
    case playerHdrEnabled = "player.hdr_enabled"
    case playerDolbyVisionEnabled = "player.dolby_vision_enabled"
    case playbackIntroSkipMode = "playback.intro_skip_mode"
    case playbackAutoSkipCredits = "playback.auto_skip_credits"
    case playbackAutoPlayNext = "playback.auto_play_next"
    case playbackNextUpPromptSeconds = "playback.next_up_prompt_seconds"
    case playerPlaybackSpeed = "player.playback_speed"
    case playerVideoGravity = "player.video_gravity"
    case playerOrientationMode = "player.orientation_mode"
    case playerSeekCacheEnabled = "player.seek_cache_enabled"
    case uiThemeMusicEnabled = "ui.theme_music_enabled"
    case uiThemeMusicLoop = "ui.theme_music_loop"
    case catalogShowAdvisoryAge = "catalog.show_advisory_age"
    case catalogHideUnwatchedEpisodeImages = "catalog.hide_unwatched_episode_images"
    case catalogHideUnwatchedEpisodeOverviews = "catalog.hide_unwatched_episode_overviews"
    case playerVideoSkipBackSeconds = "player.video_skip_back_seconds"
    case playerVideoSkipForwardSeconds = "player.video_skip_forward_seconds"
    case playerAudiobookSkipBackSeconds = "player.audiobook_skip_back_seconds"
    case playerAudiobookSkipForwardSeconds = "player.audiobook_skip_forward_seconds"
    case playbackSubtitleMode = "playback.subtitle_mode"
    case playbackShowForcedSubtitles = "playback.show_forced_subtitles"
    case catalogMetadataLanguage = "catalog.metadata_language"

    /// Keys the real contract stores at profile scope; everything else here is per device.
    static let profileScoped: Set<SettingKey> = [
        .playbackSubtitleLanguage, .catalogShowAdvisoryAge, .catalogHideUnwatchedEpisodeImages,
        .catalogHideUnwatchedEpisodeOverviews, .playerVideoSkipBackSeconds, .playerVideoSkipForwardSeconds,
        .playerAudiobookSkipBackSeconds, .playerAudiobookSkipForwardSeconds, .playbackSubtitleMode,
        .playbackShowForcedSubtitles, .catalogMetadataLanguage,
    ]
}
enum SettingScope: Equatable, Sendable {
    case account, profile, profileDevice, profileLibrary, profileSeries
}
enum SettingScopeIdentity: Equatable, Sendable {
    case profile, profileDevice
    var scope: SettingScope { self == .profile ? .profile : .profileDevice }
}
enum SettingJSONValue: Equatable, Sendable {
    case null, bool(Bool), int(Int), double(Double), string(String)
    var intValue: Int? {
        switch self {
        case .int(let value): value
        case .double(let value) where value == value.rounded(): Int(exactly: value)
        default: nil
        }
    }
    var doubleValue: Double? {
        switch self {
        case .double(let value): value
        case .int(let value): Double(value)
        default: nil
        }
    }
}
struct EffectiveSettingValue: Sendable {
    let key: String
    let value: SettingJSONValue
    let storedValue: SettingJSONValue?
    let scope: SettingScope?
    let profileId: String?
}
struct EffectiveSettingValuesResponse: Sendable {
    let byKey: [SettingKey: EffectiveSettingValue]
}
enum SiloQualityPresets {
    static let resolutionChoices = ["auto", "2160p", "1080p", "720p", "480p"]
    static func resolutionLabel(_ value: String) -> String { value }
}

private actor FakeTransport: SettingsBackupRemoteTransport {
    enum Failure: Error { case offline }
    var scope = SettingsBackupScope(serverFingerprint: String(repeating: "a", count: 64),
                                    profileFingerprint: String(repeating: "b", count: 64))
    var values: [SettingKey: SettingJSONValue] = [
        .playbackPreferredQuality: .string("1080p"), .playbackAudioLanguage: .string("en"),
        .playbackSubtitleLanguage: .string("en")]
    /// Rows authored at profile scope, which a profile-device setting inherits.
    var profileValues: [SettingKey: SettingJSONValue] = [:]
    /// Keys this fake server does not serve, like a server older than their manifest revision.
    var unserved: Set<SettingKey> = []
    /// A narrower-scope row (device, library or series) that wins over the profile row.
    var overrides: [SettingKey: (scope: SettingScope, value: SettingJSONValue)] = [:]
    var failedKey: SettingKey?
    var offline = false
    var delay: Duration?
    var writes: [SettingKey] = []
    var scopes: [SettingScopeIdentity] = []

    func owner() async throws -> SettingsBackupRemoteOwner {
        SettingsBackupRemoteOwner(
            request: HTTPRequestIdentity(serverId: "local", serverURL: "https://example.invalid",
                                         profileId: "profile", clientFamily: "ios"), scope: scope)
    }
    func read(_ keys: [SettingKey], owner: SettingsBackupRemoteOwner) async throws -> EffectiveSettingValuesResponse {
        if let delay { try await Task.sleep(for: delay) }
        if offline { throw Failure.offline }
        var rows: [SettingKey: EffectiveSettingValue] = [:]
        for key in keys where !unserved.contains(key) {
            let own: SettingScope = SettingKey.profileScoped.contains(key) ? .profile : .profileDevice
            if let hidden = overrides[key] {
                rows[key] = EffectiveSettingValue(key: key.rawValue, value: hidden.value, storedValue: nil,
                                                  scope: hidden.scope, profileId: "profile")
            } else if let value = values[key] {
                rows[key] = EffectiveSettingValue(key: key.rawValue, value: value, storedValue: nil,
                                                  scope: own, profileId: "profile")
            } else if let value = profileValues[key] {
                rows[key] = EffectiveSettingValue(key: key.rawValue, value: value, storedValue: nil,
                                                  scope: .profile, profileId: "profile")
            } else {
                rows[key] = EffectiveSettingValue(
                    key: key.rawValue, value: key == .playbackPreferredQuality ? .string("auto") : .null,
                    storedValue: nil, scope: nil, profileId: nil)
            }
        }
        return EffectiveSettingValuesResponse(byKey: rows)
    }
    func put(_ key: SettingKey, scope: SettingScopeIdentity, value: SettingJSONValue,
             owner: SettingsBackupRemoteOwner) async throws {
        if offline || key == failedKey || unserved.contains(key) { throw Failure.offline }
        values[key] = value
        writes.append(key)
        scopes.append(scope)
    }
    func delete(_ key: SettingKey, scope: SettingScopeIdentity,
                owner: SettingsBackupRemoteOwner) async throws {
        if offline || key == failedKey || unserved.contains(key) { throw Failure.offline }
        values[key] = nil
        writes.append(key)
        scopes.append(scope)
    }
    func change(_ key: SettingKey, _ value: SettingJSONValue?) { values[key] = value }
    func setProfileValue(_ key: SettingKey, _ value: SettingJSONValue?) { profileValues[key] = value }
    func setUnserved(_ keys: Set<SettingKey>) { unserved = keys }
    func setOverride(_ key: SettingKey, _ scope: SettingScope?, _ value: SettingJSONValue = .null) {
        overrides[key] = scope.map { ($0, value) }
    }
    func clearWrites() { writes = []; scopes = [] }
    func writtenKeys() -> [SettingKey] { writes }
    func writtenScopes() -> [SettingScopeIdentity] { scopes }
    func fail(_ key: SettingKey?) { failedKey = key }
    func moveProfile() {
        scope = SettingsBackupScope(serverFingerprint: scope.serverFingerprint,
                                    profileFingerprint: String(repeating: "c", count: 64))
    }
    func setOffline(_ value: Bool) { offline = value }
    func setDelay(_ value: Duration?) { delay = value }
    func current(_ key: SettingKey) -> SettingJSONValue? { values[key] }
    func writeCount() -> Int { writes.count }
}

private final class RemoteMemoryJournal: RemoteBackupJournalStoring {
    var record: RemoteBackupJournal?
    func load() throws -> RemoteBackupJournal? { record }
    func save(_ journal: RemoteBackupJournal) throws { record = journal }
    func clear() throws { record = nil }
}

@main
@MainActor
enum SettingsBackupUnifiedHostChecks {
    static func main() async throws {
        let transport = FakeTransport()
        let local = LocalStore()
        let remoteJournal = RemoteMemoryJournal()
        let model = SettingsBackupModel(
            registry: local.registry(), journal: LocalMemoryJournal(),
            app: SettingsBackupAppInfo(version: "1", build: "95", platform: "iOS", idiom: "phone"),
            remote: SettingsBackupRemoteAdapter(transport: transport, journal: remoteJournal,
                                                timeout: .milliseconds(100)))
        model.exportSelection = [.navigation, .streaming, .subtitles]
        guard let file = await model.exportUnifiedDocument() else { fatalError("export failed") }
        let document = try SettingsBackupCodec.decode(file)
        precondition(document.schemaVersion == 2 && document.scope != nil)
        precondition(document.groups["streaming"]?["streaming.resolution"] == .string("1080p"))
        precondition(document.groups["streaming"]?["streaming.audioLanguage"] == .string("en"))
        precondition(document.groups["subtitles"]?["subtitles.language"] == .string("en"))

        local.fourthTab = "forYou"
        await transport.change(.playbackPreferredQuality, .string("480p"))
        await transport.change(.playbackAudioLanguage, .string("zh"))
        await transport.change(.playbackSubtitleLanguage, .string("zh"))
        await model.loadUnifiedImport(data: file)
        precondition(model.selectedChangeCount == 4)
        await model.applyUnifiedSelected()
        precondition(local.fourthTab == "sports")
        let restoredQuality = await transport.current(.playbackPreferredQuality)
        let restoredAudio = await transport.current(.playbackAudioLanguage)
        let restoredLanguage = await transport.current(.playbackSubtitleLanguage)
        precondition(restoredQuality == .string("1080p"))
        precondition(restoredAudio == .string("en"))
        precondition(restoredLanguage == .string("en"))
        precondition(model.lastRestoredCount == 4)
        await model.undoUnified()
        precondition(local.fourthTab == "forYou")
        let undoneQuality = await transport.current(.playbackPreferredQuality)
        let undoneLanguage = await transport.current(.playbackSubtitleLanguage)
        precondition(undoneQuality == .string("480p"))
        precondition(undoneLanguage == .string("zh"))

        await transport.moveProfile()
        await model.loadUnifiedImport(data: file)
        // This file selected the streaming (6) and subtitles (4) groups; all ten are refused for a
        // different profile.
        precondition(model.preview?.skippedCount == 10)
        let before = await transport.writeCount()
        await model.applyUnifiedSelected()
        let after = await transport.writeCount()
        precondition(after == before)

        await transport.setOffline(true)
        let offlineExport = await model.exportUnifiedDocument()
        precondition(offlineExport == nil)
        await transport.setOffline(false)
        await transport.setDelay(.milliseconds(200))
        let timeoutAdapter = SettingsBackupRemoteAdapter(
            transport: transport, journal: RemoteMemoryJournal(), timeout: .milliseconds(20))
        do {
            _ = try await timeoutAdapter.export()
            fatalError("timeout failed")
        } catch SettingsBackupRemoteError.timeout {}

        let partialTransport = FakeTransport()
        let partialLocal = LocalStore()
        let partialJournal = RemoteMemoryJournal()
        let partialModel = SettingsBackupModel(
            registry: partialLocal.registry(), journal: LocalMemoryJournal(),
            app: SettingsBackupAppInfo(version: "1", build: "95", platform: "iOS", idiom: "phone"),
            remote: SettingsBackupRemoteAdapter(transport: partialTransport, journal: partialJournal))
        partialModel.exportSelection = [.navigation, .streaming, .subtitles]
        guard let partialFile = await partialModel.exportUnifiedDocument() else { fatalError("partial export failed") }
        partialLocal.fourthTab = "forYou"
        await partialTransport.change(.playbackPreferredQuality, .string("480p"))
        await partialTransport.change(.playbackAudioLanguage, .string("zh"))
        await partialTransport.change(.playbackSubtitleLanguage, .string("zh"))
        await partialTransport.fail(.playbackSubtitleLanguage)
        await partialModel.loadUnifiedImport(data: partialFile)
        await partialModel.applyUnifiedSelected()
        precondition(partialLocal.fourthTab == "forYou")
        precondition(partialModel.needsRecovery && partialModel.lastRestoredCount == nil)
        let partialQuality = await partialTransport.current(.playbackPreferredQuality)
        let partialAudio = await partialTransport.current(.playbackAudioLanguage)
        let partialLanguage = await partialTransport.current(.playbackSubtitleLanguage)
        precondition(partialQuality == .string("1080p") && partialAudio == .string("en")
                     && partialLanguage == .string("zh"))
        await partialTransport.fail(nil)
        await partialModel.recoverUnified()
        let recoveredQuality = await partialTransport.current(.playbackPreferredQuality)
        let recoveredAudio = await partialTransport.current(.playbackAudioLanguage)
        precondition(recoveredQuality == .string("480p"))
        precondition(recoveredAudio == .string("zh"))

        let selectiveTransport = FakeTransport()
        let selectiveLocal = LocalStore()
        let selectiveModel = SettingsBackupModel(
            registry: selectiveLocal.registry(), journal: LocalMemoryJournal(),
            app: SettingsBackupAppInfo(version: "1", build: "95", platform: "iOS", idiom: "phone"),
            remote: SettingsBackupRemoteAdapter(transport: selectiveTransport, journal: RemoteMemoryJournal()))
        selectiveModel.exportSelection = [.navigation, .streaming, .subtitles]
        guard let selectiveFile = await selectiveModel.exportUnifiedDocument() else { fatalError("selective export failed") }
        selectiveLocal.fourthTab = "forYou"
        await selectiveTransport.change(.playbackPreferredQuality, .string("480p"))
        await selectiveTransport.change(.playbackSubtitleLanguage, .string("zh"))
        await selectiveModel.loadUnifiedImport(data: selectiveFile)
        selectiveModel.setImport("subtitles.language", enabled: false)
        await selectiveModel.applyUnifiedSelected()
        let untouchedLanguage = await selectiveTransport.current(.playbackSubtitleLanguage)
        precondition(untouchedLanguage == .string("zh") && selectiveLocal.fourthTab == "sports")

        let cancellationTransport = FakeTransport()
        await cancellationTransport.setDelay(.milliseconds(200))
        let cancellationAdapter = SettingsBackupRemoteAdapter(
            transport: cancellationTransport, journal: RemoteMemoryJournal(), timeout: .seconds(1))
        let cancelled = Task { try await cancellationAdapter.export() }
        try await Task.sleep(for: .milliseconds(10))
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            fatalError("cancelled export returned a file")
        } catch is CancellationError {}

        let batchCount = try await RemoteBatchOneChecks.run()
        print("SettingsBackupUnifiedHostChecks: \(10 + batchCount) passed")
    }
}

/// Batch 1: the fourteen profile-device scalar settings, one table row per value transition.
@MainActor
private enum RemoteBatchOneChecks {
    struct Row {
        let id: String
        let key: SettingKey
        /// The backed-up server value; nil means this device has no row (it inherits).
        let saved: SettingJSONValue?
        let backup: BackupValue
        /// The value the destination holds before restore.
        let current: SettingJSONValue?
        var scope: SettingScopeIdentity = .profileDevice
    }

    static let inherit = BackupValue.string("~inherit")

    static let rows: [Row] = [
        Row(id: "streaming.maxBitrate", key: .playbackMaxBitrateKbps, saved: .int(6000), backup: .int(6000), current: .null),
        Row(id: "streaming.maxBitrate", key: .playbackMaxBitrateKbps, saved: .null, backup: .string("~null"), current: .int(2000)),
        Row(id: "streaming.maxBitrate", key: .playbackMaxBitrateKbps, saved: nil, backup: inherit, current: .int(2000)),
        Row(id: "streaming.bufferingQuality", key: .playbackBufferingQualityMode, saved: .string("never"), backup: .string("never"), current: .string("always")),
        Row(id: "streaming.hdr", key: .playerHdrEnabled, saved: .bool(false), backup: .bool(false), current: .bool(true)),
        Row(id: "streaming.hdr", key: .playerHdrEnabled, saved: .bool(true), backup: .bool(true), current: .bool(false)),
        Row(id: "streaming.dolbyVision", key: .playerDolbyVisionEnabled, saved: .bool(false), backup: .bool(false), current: .bool(true)),
        Row(id: "streaming.dolbyVision", key: .playerDolbyVisionEnabled, saved: .bool(true), backup: .bool(true), current: .bool(false)),
        Row(id: "player.introSkip", key: .playbackIntroSkipMode, saved: .string("always"), backup: .string("always"), current: .string("never")),
        Row(id: "player.skipCredits", key: .playbackAutoSkipCredits, saved: .bool(true), backup: .bool(true), current: .bool(false)),
        Row(id: "player.skipCredits", key: .playbackAutoSkipCredits, saved: .bool(false), backup: .bool(false), current: .bool(true)),
        Row(id: "player.autoPlayNext", key: .playbackAutoPlayNext, saved: .bool(false), backup: .bool(false), current: .bool(true)),
        Row(id: "player.autoPlayNext", key: .playbackAutoPlayNext, saved: .bool(true), backup: .bool(true), current: .bool(false)),
        Row(id: "player.nextUpSeconds", key: .playbackNextUpPromptSeconds, saved: .int(0), backup: .int(0), current: .int(30)),
        Row(id: "player.speedHundredths", key: .playerPlaybackSpeed, saved: .double(1.25), backup: .int(125), current: .double(2)),
        Row(id: "player.videoSizing", key: .playerVideoGravity, saved: .string("fill"), backup: .string("fill"), current: .string("fit")),
        Row(id: "player.orientation", key: .playerOrientationMode, saved: .string("rotateFreely"), backup: .string("rotateFreely"), current: .string("landscapeLocked")),
        Row(id: "player.fastSeeking", key: .playerSeekCacheEnabled, saved: .bool(false), backup: .bool(false), current: .bool(true)),
        Row(id: "player.fastSeeking", key: .playerSeekCacheEnabled, saved: .bool(true), backup: .bool(true), current: .bool(false)),
        Row(id: "interface.themeMusic", key: .uiThemeMusicEnabled, saved: .bool(true), backup: .bool(true), current: .bool(false)),
        Row(id: "interface.themeMusic", key: .uiThemeMusicEnabled, saved: .bool(false), backup: .bool(false), current: .bool(true)),
        Row(id: "interface.themeMusicLoop", key: .uiThemeMusicLoop, saved: .bool(true), backup: .bool(true), current: .bool(false)),
        Row(id: "interface.themeMusicLoop", key: .uiThemeMusicLoop, saved: .bool(false), backup: .bool(false), current: .bool(true)),
    ] + profileRows

    /// Batch 2: profile-scope scalars. `saved: nil` is an absent profile row, so the value inherits.
    static let profileRows: [Row] = [
        Row(id: "interface.advisoryAge", key: .catalogShowAdvisoryAge, saved: .bool(true), backup: .bool(true), current: .bool(false), scope: .profile),
        Row(id: "interface.advisoryAge", key: .catalogShowAdvisoryAge, saved: .bool(false), backup: .bool(false), current: .bool(true), scope: .profile),
        Row(id: "interface.advisoryAge", key: .catalogShowAdvisoryAge, saved: nil, backup: inherit, current: .bool(true), scope: .profile),
        Row(id: "interface.hideEpisodeImages", key: .catalogHideUnwatchedEpisodeImages, saved: .bool(true), backup: .bool(true), current: .bool(false), scope: .profile),
        Row(id: "interface.hideEpisodeImages", key: .catalogHideUnwatchedEpisodeImages, saved: .bool(false), backup: .bool(false), current: .bool(true), scope: .profile),
        Row(id: "interface.hideEpisodeDescriptions", key: .catalogHideUnwatchedEpisodeOverviews, saved: .bool(true), backup: .bool(true), current: .bool(false), scope: .profile),
        Row(id: "interface.hideEpisodeDescriptions", key: .catalogHideUnwatchedEpisodeOverviews, saved: .bool(false), backup: .bool(false), current: .bool(true), scope: .profile),
        Row(id: "player.videoSkipBackSeconds", key: .playerVideoSkipBackSeconds, saved: .int(45), backup: .int(45), current: .int(10), scope: .profile),
        Row(id: "player.videoSkipForwardSeconds", key: .playerVideoSkipForwardSeconds, saved: .int(5), backup: .int(5), current: .int(30), scope: .profile),
        Row(id: "player.videoSkipForwardSeconds", key: .playerVideoSkipForwardSeconds, saved: nil, backup: inherit, current: .int(90), scope: .profile),
        Row(id: "player.audiobookSkipBackSeconds", key: .playerAudiobookSkipBackSeconds, saved: .int(90), backup: .int(90), current: .int(10), scope: .profile),
        Row(id: "player.audiobookSkipForwardSeconds", key: .playerAudiobookSkipForwardSeconds, saved: .int(60), backup: .int(60), current: .int(30), scope: .profile),
        Row(id: "subtitles.mode", key: .playbackSubtitleMode, saved: .string("always"), backup: .string("always"), current: .string("auto"), scope: .profile),
        Row(id: "subtitles.mode", key: .playbackSubtitleMode, saved: .string("off"), backup: .string("off"), current: .string("always"), scope: .profile),
        Row(id: "subtitles.showForced", key: .playbackShowForcedSubtitles, saved: .bool(false), backup: .bool(false), current: .bool(true), scope: .profile),
        Row(id: "subtitles.showForced", key: .playbackShowForcedSubtitles, saved: .bool(true), backup: .bool(true), current: .bool(false), scope: .profile),
        Row(id: "subtitles.metadataLanguage", key: .catalogMetadataLanguage, saved: .string("ja"), backup: .string("ja"), current: .string("en"), scope: .profile),
        Row(id: "subtitles.metadataLanguage", key: .catalogMetadataLanguage, saved: .null, backup: .string("~null"), current: .string("en"), scope: .profile),
        Row(id: "subtitles.metadataLanguage", key: .catalogMetadataLanguage, saved: nil, backup: inherit, current: .string("en"), scope: .profile),
    ]

    static let app = SettingsBackupAppInfo(version: "1", build: "97", platform: "iOS", idiom: "phone")

    static func document(_ adapter: SettingsBackupRemoteAdapter) async throws -> IncomingBackup {
        let exported = try await adapter.export()
        return try SettingsBackupCodec.decode(SettingsBackupCodec.makeUnifiedDocument(
            groups: exported.groups, scope: exported.scope, app: app, now: Date()))
    }

    static func item(_ groups: [RestorePreviewGroup], _ id: String) -> RestorePreviewItem? {
        groups.flatMap(\.items).first { $0.id == id }
    }

    static func run() async throws -> Int {
        var checks = 0

        // Every new ID passes the document's sensitive-name filter and is owned by the adapter.
        let newIDs = Set(rows.map(\.id))
        precondition(newIDs.count == 24 && newIDs.isSubset(of: SettingsBackupRemoteAdapter.settingIDs))
        precondition(SettingsBackupRemoteAdapter.settingIDs.count == 27)
        precondition(SettingsBackupRemoteAdapter.settingIDs.allSatisfy { !SettingsBackupSafety.isSensitiveName($0) })
        checks += 1

        // Round trip per row: export → change → preview → restore → confirm → Undo.
        for row in rows {
            let transport = FakeTransport()
            await transport.change(row.key, row.saved)
            if row.saved == nil && row.scope == .profileDevice { await transport.setProfileValue(row.key, row.current) }
            let adapter = SettingsBackupRemoteAdapter(transport: transport, journal: RemoteMemoryJournal(),
                                                      timeout: .seconds(1))
            let incoming = try await document(adapter)
            let group = row.id.split(separator: ".").first.map(String.init)!
            if row.scope == .profile && row.saved == nil {
                // Inherited: exporting must find no profile row, and a different value is set after.
                precondition(incoming.groups[group]?[row.id] == row.backup, "inherited export \(row.id)")
            }
            precondition(incoming.groups[group]?[row.id] == row.backup, "export \(row.id) \(row.backup)")

            await transport.change(row.key, row.current)
            let preview = await adapter.preview(incoming)
            guard let entry = item(preview, row.id) else { fatalError("preview missing \(row.id)") }
            precondition(entry.status == .willChange, "preview \(row.id) \(entry.status)")
            precondition(entry.current != nil && entry.current != entry.incoming)

            await transport.clearWrites()
            let report = await adapter.apply(incoming, selectedIDs: [row.id])
            precondition(report.applied == [row.id] && report.failed.isEmpty, "apply \(row.id)")
            let restored = await transport.current(row.key)
            precondition(restored == row.saved, "restored \(row.id) \(String(describing: restored))")
            let written = await transport.writtenKeys()
            let scopes = await transport.writtenScopes()
            precondition(written == [row.key] && scopes == [row.scope], "scope \(row.id)")

            let undo = await adapter.undo()
            precondition(undo.applied == [row.id] && undo.failed.isEmpty, "undo \(row.id)")
            let undone = await transport.current(row.key)
            precondition(undone == row.current, "undo value \(row.id)")
            precondition(!adapter.undoAvailable)
            checks += 1
        }

        // A server older than revision 23/11 omits those keys from export and reports them as
        // unsupported on restore; the rest of the backup still works.
        let full = FakeTransport()
        await full.change(.playbackBufferingQualityMode, .string("ask"))
        await full.change(.uiThemeMusicEnabled, .bool(true))
        let fullFile = try await document(SettingsBackupRemoteAdapter(transport: full, journal: RemoteMemoryJournal()))
        let old = FakeTransport()
        let gated: Set<SettingKey> = [.playbackBufferingQualityMode, .uiThemeMusicEnabled, .uiThemeMusicLoop]
        await old.setUnserved(gated)
        let oldAdapter = SettingsBackupRemoteAdapter(transport: old, journal: RemoteMemoryJournal())
        let oldFile = try await document(oldAdapter)
        precondition(oldFile.groups["streaming"]?["streaming.bufferingQuality"] == nil)
        precondition(oldFile.groups["interface"]?["interface.themeMusic"] == nil)
        precondition(oldFile.groups["interface"]?["interface.themeMusicLoop"] == nil)
        precondition(oldFile.groups["streaming"]?["streaming.hdr"] == inherit)
        let oldPreview = await oldAdapter.preview(fullFile)
        for id in ["streaming.bufferingQuality", "interface.themeMusic", "interface.themeMusicLoop"] {
            precondition(item(oldPreview, id)?.status == .unsupported("This server doesn't support this setting."))
        }
        let oldReport = await oldAdapter.apply(fullFile, selectedIDs: ["streaming.bufferingQuality", "interface.themeMusic"])
        let oldWrites = await old.writeCount()
        precondition(oldReport.skipped.count == 2 && oldReport.failed.isEmpty && oldWrites == 0)
        checks += 1

        // Profile mismatch: nothing in batch 1 is written, and every item says why.
        let source = FakeTransport()
        await source.change(.playerHdrEnabled, .bool(false))
        await source.change(.playbackAutoPlayNext, .bool(false))
        let sourceAdapter = SettingsBackupRemoteAdapter(transport: source, journal: RemoteMemoryJournal())
        let sourceFile = try await document(sourceAdapter)
        await source.change(.playerHdrEnabled, .bool(true))
        await source.moveProfile()
        let mismatch = await sourceAdapter.preview(sourceFile)
        precondition(mismatch.flatMap(\.items).allSatisfy {
            $0.status == .unsupported(SettingsBackupRemoteError.destinationMismatch.localizedDescription)
        })
        precondition(mismatch.flatMap(\.items).count == SettingsBackupRemoteAdapter.settingIDs.count)
        let mismatchReport = await sourceAdapter.apply(sourceFile, selectedIDs: newIDs)
        let mismatchWrites = await source.writeCount()
        precondition(mismatchWrites == 0 && mismatchReport.applied.isEmpty)
        checks += 1

        // API failure mid-restore: earlier writes are confirmed, the failed one is reported, the
        // journal stays in recovery, and recovery puts the confirmed writes back.
        let failing = FakeTransport()
        await failing.change(.playbackMaxBitrateKbps, .int(10_000))
        await failing.change(.playerHdrEnabled, .bool(false))
        await failing.change(.playbackAutoPlayNext, .bool(false))
        let failingJournal = RemoteMemoryJournal()
        let failingAdapter = SettingsBackupRemoteAdapter(transport: failing, journal: failingJournal)
        let failingFile = try await document(failingAdapter)
        await failing.change(.playbackMaxBitrateKbps, .null)
        await failing.change(.playerHdrEnabled, .bool(true))
        await failing.change(.playbackAutoPlayNext, .bool(true))
        await failing.fail(.playerHdrEnabled)
        let failedReport = await failingAdapter.apply(
            failingFile, selectedIDs: ["streaming.maxBitrate", "streaming.hdr", "player.autoPlayNext"])
        precondition(failedReport.applied == ["streaming.maxBitrate"] && failedReport.failed == ["streaming.hdr"])
        precondition(failingAdapter.needsRecovery)
        await failing.fail(nil)
        let recovered = await failingAdapter.undo()
        precondition(recovered.failed.isEmpty)
        let recoveredBitrate = await failing.current(.playbackMaxBitrateKbps)
        let untouchedNext = await failing.current(.playbackAutoPlayNext)
        precondition(recoveredBitrate == .null && untouchedNext == .bool(true) && !failingAdapter.undoAvailable)
        checks += 1

        // Selective restore across groups writes only the chosen setting.
        let selective = FakeTransport()
        await selective.change(.playerVideoGravity, .string("stretch"))
        await selective.change(.uiThemeMusicLoop, .bool(true))
        let selectiveAdapter = SettingsBackupRemoteAdapter(transport: selective, journal: RemoteMemoryJournal())
        let selectiveFile = try await document(selectiveAdapter)
        await selective.change(.playerVideoGravity, .string("fit"))
        await selective.change(.uiThemeMusicLoop, .bool(false))
        await selective.clearWrites()
        _ = await selectiveAdapter.apply(selectiveFile, selectedIDs: ["interface.themeMusicLoop"])
        let selectiveWrites = await selective.writtenKeys()
        let gravity = await selective.current(.playerVideoGravity)
        precondition(selectiveWrites == [.uiThemeMusicLoop] && gravity == .string("fit"))
        checks += 1

        // Undo leaves a value alone when it changed again after the restore.
        let changed = FakeTransport()
        await changed.change(.playbackIntroSkipMode, .string("always"))
        let changedAdapter = SettingsBackupRemoteAdapter(transport: changed, journal: RemoteMemoryJournal())
        let changedFile = try await document(changedAdapter)
        await changed.change(.playbackIntroSkipMode, .string("never"))
        _ = await changedAdapter.apply(changedFile, selectedIDs: ["player.introSkip"])
        await changed.change(.playbackIntroSkipMode, .string("ask"))
        let changedUndo = await changedAdapter.undo()
        let afterUndo = await changed.current(.playbackIntroSkipMode)
        precondition(changedUndo.skipped == ["player.introSkip"] && afterUndo == .string("ask"))
        checks += 1

        // Values outside the contract are refused in preview and never written.
        let strict = FakeTransport()
        let strictAdapter = SettingsBackupRemoteAdapter(transport: strict, journal: RemoteMemoryJournal())
        let strictBase = try await document(strictAdapter)
        var invalidGroups = strictBase.groups
        invalidGroups["player"]?["player.speedHundredths"] = .int(127)
        invalidGroups["player"]?["player.nextUpSeconds"] = .int(500)
        invalidGroups["player"]?["player.orientation"] = .string("sideways")
        invalidGroups["streaming"]?["streaming.hdr"] = .int(1)
        invalidGroups["streaming"]?["streaming.dolbyVision"] = .string("~null")
        let invalid = try SettingsBackupCodec.decode(SettingsBackupCodec.makeUnifiedDocument(
            groups: invalidGroups, scope: strictBase.scope, app: app, now: Date()))
        let invalidPreview = await strictAdapter.preview(invalid)
        for id in ["player.speedHundredths", "player.nextUpSeconds", "player.orientation", "streaming.hdr", "streaming.dolbyVision"] {
            precondition(item(invalidPreview, id)?.status == .invalid("This value is not supported."), id)
        }
        await strict.clearWrites()
        let invalidReport = await strictAdapter.apply(invalid, selectedIDs: ["player.speedHundredths", "streaming.hdr"])
        let invalidWrites = await strict.writeCount()
        precondition(invalidWrites == 0 && invalidReport.skipped.count == 2)
        checks += 1

        // Model level: a Build 96 schema-2 file (three synced settings only) still previews and
        // restores; an unknown future synced ID is counted as skipped; the document has no secrets.
        let model96Transport = FakeTransport()
        let model = SettingsBackupModel(
            registry: LocalStore().registry(), journal: LocalMemoryJournal(), app: app,
            remote: SettingsBackupRemoteAdapter(transport: model96Transport, journal: RemoteMemoryJournal()))
        let scope = SettingsBackupScope(serverFingerprint: String(repeating: "a", count: 64),
                                        profileFingerprint: String(repeating: "b", count: 64))
        let build96 = try SettingsBackupCodec.makeUnifiedDocument(
            groups: ["streaming": ["streaming.resolution": .string("480p"), "streaming.audioLanguage": .string("en")],
                     "subtitles": ["subtitles.language": .string("zh")]],
            scope: scope, app: app, now: Date())
        await model.loadUnifiedImport(data: build96)
        precondition(model.preview?.unrecognizedSettings == 0 && model.selectedChangeCount == 2)
        await model.applyUnifiedSelected()
        let build96Quality = await model96Transport.current(.playbackPreferredQuality)
        precondition(build96Quality == .string("480p"))
        let future = try SettingsBackupCodec.makeUnifiedDocument(
            groups: ["player": ["player.futureSetting": .bool(true), "player.autoPlayNext": .bool(false)]],
            scope: scope, app: app, now: Date())
        await model.loadUnifiedImport(data: future)
        precondition(model.preview?.unrecognizedSettings == 1 && model.selectedChangeCount == 1)
        model.exportSelection = Set(SettingsBackupRemoteAdapter.groups)
        guard let exported = await model.exportUnifiedDocument() else { fatalError("model export failed") }
        let text = String(decoding: exported, as: UTF8.self)
        for secret in ["example.invalid", "https", "\"local\"", "\"profile\""] {
            precondition(!text.contains(secret), "document leaked \(secret)")
        }
        let decoded = try SettingsBackupCodec.decode(exported)
        precondition(decoded.groups["player"]?.count == 12 && decoded.groups["interface"]?.count == 5)
        precondition(decoded.groups["streaming"]?.count == 6 && decoded.groups["subtitles"]?.count == 4)
        checks += 1

        checks += try await batchTwoChecks()

        // A schema-1 file may not carry the new synced groups.
        let unsafe = try SettingsBackupCodec.makeDocument(
            groups: ["player": ["player.autoPlayNext": .bool(true)]],
            schemaVersion: 1, minReaderVersion: 1, app: app, now: Date())
        do {
            _ = try SettingsBackupCodec.decode(unsafe)
            fatalError("schema-1 file carried a synced player setting")
        } catch SettingsBackupError.unsafeContent {}
        checks += 1

        return checks
    }

    static func batchTwoChecks() async throws -> Int {
        var checks = 0
        let profileKeys: [SettingKey] = [
            .catalogShowAdvisoryAge, .catalogHideUnwatchedEpisodeImages, .catalogHideUnwatchedEpisodeOverviews,
            .playerVideoSkipBackSeconds, .playerVideoSkipForwardSeconds, .playerAudiobookSkipBackSeconds,
            .playerAudiobookSkipForwardSeconds, .playbackSubtitleMode, .playbackShowForcedSubtitles,
            .catalogMetadataLanguage]
        // Exactly ten profile-scope settings, every one written at profile scope.
        precondition(profileKeys.count == 10)
        precondition(RemoteBackupDefinition.allCases.filter { $0.scope == .profile }.count == 11)

        // Subtitle override isolation: a device/series row hides the profile value. Export leaves
        // it out with a reason, preview refuses it, and no write ever happens to the profile row.
        for hider in [SettingScope.profileDevice, .profileSeries, .profileLibrary] {
            let transport = FakeTransport()
            await transport.change(.playbackSubtitleMode, .string("always"))
            let adapter = SettingsBackupRemoteAdapter(transport: transport, journal: RemoteMemoryJournal())
            let file = try await document(adapter)
            precondition(file.groups["subtitles"]?["subtitles.mode"] == .string("always"))
            await transport.setOverride(.playbackSubtitleMode, hider, .string("off"))
            let exported = try await adapter.export()
            precondition(exported.groups["subtitles"]?["subtitles.mode"] == nil)
            precondition(exported.omitted.contains { $0.hasPrefix("Subtitle behavior") && $0.contains("override") })
            precondition(exported.groups["subtitles"]?["subtitles.showForced"] == inherit)
            let preview = await adapter.preview(file)
            precondition(item(preview, "subtitles.mode")?.status
                == .unsupported(SettingsBackupRemoteError.overridden.localizedDescription))
            await transport.clearWrites()
            let report = await adapter.apply(file, selectedIDs: ["subtitles.mode", "subtitles.showForced"])
            let writes = await transport.writeCount()
            precondition(writes == 0 && report.skipped == ["subtitles.mode"] && report.failed.isEmpty)
            let shown = await transport.current(.playbackSubtitleMode)
            precondition(shown == .string("always"))
            await transport.setOverride(.playbackSubtitleMode, nil)
        }
        checks += 1

        // Skip intervals: only the contract's list is valid, for all four keys.
        for definition in [RemoteBackupDefinition.videoSkipBack, .videoSkipForward, .audiobookSkipBack, .audiobookSkipForward] {
            for seconds in [5, 10, 15, 30, 45, 60, 90] { precondition(definition.validate(.int(seconds))) }
            for bad in [0, 1, 7, 20, 89, 91, 120, -10] { precondition(!definition.validate(.int(bad)), "\(bad)") }
            precondition(!definition.validate(.bool(true)) && !definition.validate(.string("10")))
            precondition(!definition.validate(.string("~null")))
            precondition(definition.validate(inherit))
            precondition(definition.scope == .profile && definition.requiresCapability)
        }
        let strict = FakeTransport()
        let strictAdapter = SettingsBackupRemoteAdapter(transport: strict, journal: RemoteMemoryJournal())
        let base = try await document(strictAdapter)
        var bad = base.groups
        bad["player"]?["player.videoSkipBackSeconds"] = .int(7)
        bad["player"]?["player.audiobookSkipForwardSeconds"] = .int(120)
        bad["subtitles"]?["subtitles.mode"] = .string("sometimes")
        bad["subtitles"]?["subtitles.showForced"] = .string("on")
        bad["interface"]?["interface.advisoryAge"] = .string("~null")
        bad["subtitles"]?["subtitles.metadataLanguage"] = .string("not a language!")
        let invalid = try SettingsBackupCodec.decode(SettingsBackupCodec.makeUnifiedDocument(
            groups: bad, scope: base.scope, app: app, now: Date()))
        let invalidPreview = await strictAdapter.preview(invalid)
        let badIDs = ["player.videoSkipBackSeconds", "player.audiobookSkipForwardSeconds", "subtitles.mode",
                      "subtitles.showForced", "interface.advisoryAge", "subtitles.metadataLanguage"]
        for id in badIDs { precondition(item(invalidPreview, id)?.status == .invalid("This value is not supported."), id) }
        await strict.clearWrites()
        _ = await strictAdapter.apply(invalid, selectedIDs: Set(badIDs))
        let strictWrites = await strict.writeCount()
        precondition(strictWrites == 0)
        checks += 1

        // Older servers: seek intervals (rev 9), advisory age (10) and spoilers (17) are omitted
        // from the export and reported on restore; subtitle mode, forced subtitles and metadata
        // language (rev 1) still work.
        let full = FakeTransport()
        for key in profileKeys { await full.change(key, profileSample(key)) }
        let fullFile = try await document(SettingsBackupRemoteAdapter(transport: full, journal: RemoteMemoryJournal()))
        let old = FakeTransport()
        let gated: Set<SettingKey> = [
            .catalogShowAdvisoryAge, .catalogHideUnwatchedEpisodeImages, .catalogHideUnwatchedEpisodeOverviews,
            .playerVideoSkipBackSeconds, .playerVideoSkipForwardSeconds, .playerAudiobookSkipBackSeconds,
            .playerAudiobookSkipForwardSeconds]
        await old.setUnserved(gated)
        let oldAdapter = SettingsBackupRemoteAdapter(transport: old, journal: RemoteMemoryJournal())
        let oldExport = try await oldAdapter.export()
        precondition(oldExport.groups["subtitles"]?.count == 4)
        for id in ["interface.advisoryAge", "interface.hideEpisodeImages", "interface.hideEpisodeDescriptions"] {
            precondition(oldExport.groups["interface"]?[id] == nil, id)
        }
        precondition(oldExport.groups["player"]?["player.videoSkipBackSeconds"] == nil)
        precondition(oldExport.omitted.count == 7)
        let oldPreview = await oldAdapter.preview(fullFile)
        for id in ["interface.advisoryAge", "interface.hideEpisodeImages", "interface.hideEpisodeDescriptions",
                   "player.videoSkipBackSeconds", "player.videoSkipForwardSeconds",
                   "player.audiobookSkipBackSeconds", "player.audiobookSkipForwardSeconds"] {
            precondition(item(oldPreview, id)?.status == .unsupported("This server doesn't support this setting."), id)
        }
        precondition(item(oldPreview, "subtitles.mode")?.status == .willChange)
        let oldReport = await oldAdapter.apply(fullFile, selectedIDs: ["interface.advisoryAge", "subtitles.mode"])
        let oldWritten = await old.writtenKeys()
        precondition(oldReport.skipped == ["interface.advisoryAge"] && oldWritten == [.playbackSubtitleMode])
        checks += 1

        // Partial API failure across profile settings: confirmed writes are journalled, the failure
        // is reported, nothing after it is attempted, and recovery restores the earlier values.
        let source = FakeTransport()
        for key in profileKeys { await source.change(key, profileSample(key)) }
        let journal = RemoteMemoryJournal()
        let adapter = SettingsBackupRemoteAdapter(transport: source, journal: journal)
        let file = try await document(adapter)
        for key in profileKeys { await source.change(key, profileOther(key)) }
        await source.fail(.playbackShowForcedSubtitles)
        let ids = ["interface.advisoryAge", "subtitles.mode", "subtitles.showForced", "subtitles.metadataLanguage"]
        let report = await adapter.apply(file, selectedIDs: Set(ids))
        precondition(report.failed == ["subtitles.showForced"], "\(report.failed)")
        precondition(!report.applied.contains("subtitles.showForced") && adapter.needsRecovery)
        let untouched = await source.current(.playerVideoSkipBackSeconds)
        precondition(untouched == profileOther(.playerVideoSkipBackSeconds))
        await source.fail(nil)
        let recovered = await adapter.undo()
        precondition(recovered.failed.isEmpty && !adapter.undoAvailable)
        for key in [SettingKey.catalogShowAdvisoryAge, .playbackSubtitleMode, .catalogMetadataLanguage] {
            let value = await source.current(key)
            precondition(value == profileOther(key), key.rawValue)
        }
        checks += 1

        // Selective restore: one chosen profile setting changes, its neighbours do not.
        await source.clearWrites()
        let selective = await adapter.apply(file, selectedIDs: ["player.videoSkipForwardSeconds"])
        let selectiveWrites = await source.writtenKeys()
        let selectiveScopes = await source.writtenScopes()
        precondition(selective.applied == ["player.videoSkipForwardSeconds"])
        precondition(selectiveWrites == [.playerVideoSkipForwardSeconds] && selectiveScopes == [.profile])
        let undoSelective = await adapter.undo()
        precondition(undoSelective.applied == ["player.videoSkipForwardSeconds"])
        checks += 1

        // Build 96 schema-2 and schema-1 files still decode and need no batch 2 settings.
        let legacy2 = try SettingsBackupCodec.makeUnifiedDocument(
            groups: ["subtitles": ["subtitles.language": .string("zh")]], scope: base.scope, app: app, now: Date())
        let decoded2 = try SettingsBackupCodec.decode(legacy2)
        let legacyPreview = await adapter.preview(decoded2)
        precondition(legacyPreview.flatMap(\.items).count == 1)
        let legacy1 = try SettingsBackupCodec.makeDocument(
            groups: ["navigation": ["navigation.fourthTab": .string("sports")]],
            schemaVersion: 1, minReaderVersion: 1, app: app, now: Date())
        let decoded1 = try SettingsBackupCodec.decode(legacy1)
        precondition(decoded1.schemaVersion == 1)
        let schema1Unsafe = try SettingsBackupCodec.makeDocument(
            groups: ["subtitles": ["subtitles.mode": .string("off")]],
            schemaVersion: 1, minReaderVersion: 1, app: app, now: Date())
        do { _ = try SettingsBackupCodec.decode(schema1Unsafe); fatalError("schema 1 carried synced mode") }
        catch SettingsBackupError.unsafeContent {}
        checks += 1
        return checks
    }

    /// A value the saved backup holds, and a different one the destination holds before restore.
    static func profileSample(_ key: SettingKey) -> SettingJSONValue {
        switch key {
        case .playerVideoSkipBackSeconds: .int(45)
        case .playerVideoSkipForwardSeconds: .int(5)
        case .playerAudiobookSkipBackSeconds: .int(90)
        case .playerAudiobookSkipForwardSeconds: .int(60)
        case .playbackSubtitleMode: .string("always")
        case .catalogMetadataLanguage: .string("ja")
        case .catalogShowAdvisoryAge, .catalogHideUnwatchedEpisodeImages, .catalogHideUnwatchedEpisodeOverviews: .bool(true)
        default: .bool(false)
        }
    }
    static func profileOther(_ key: SettingKey) -> SettingJSONValue {
        switch key {
        case .playerVideoSkipBackSeconds, .playerAudiobookSkipBackSeconds: .int(10)
        case .playerVideoSkipForwardSeconds, .playerAudiobookSkipForwardSeconds: .int(30)
        case .playbackSubtitleMode: .string("off")
        case .catalogMetadataLanguage: .string("en")
        case .catalogShowAdvisoryAge, .catalogHideUnwatchedEpisodeImages, .catalogHideUnwatchedEpisodeOverviews: .bool(false)
        default: .bool(true)
        }
    }
}

@MainActor
private final class LocalStore {
    var fourthTab = "sports"
    func registry() -> SettingsBackupRegistry {
        SettingsBackupRegistry(settings: [BackupSetting(
            id: "navigation.fourthTab", group: .navigation, title: "Fourth tab",
            validate: { if case .string(let value) = $0 { return ["sports", "forYou"].contains(value) }; return false },
            read: { [self] in .string(fourthTab) },
            write: { [self] value in
                guard case .string(let raw) = value else { return }
                fourthTab = raw
            })], deviceIdiom: "phone")
    }
}

private final class LocalMemoryJournal: RestoreJournalStoring {
    var record: RestoreJournal?
    func load() throws -> RestoreJournal? { record }
    func save(_ journal: RestoreJournal) throws { record = journal }
    func clear() throws { record = nil }
}
#endif
