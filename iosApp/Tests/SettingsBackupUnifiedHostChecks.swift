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
enum SettingKey: String, Hashable, Sendable {
    case playbackPreferredQuality = "playback.preferred_quality"
    case playbackAudioLanguage = "playback.audio_language"
    case playbackSubtitleLanguage = "playback.subtitle_language"
}
enum SettingScope: Equatable, Sendable { case profile, profileDevice }
enum SettingScopeIdentity: Equatable, Sendable {
    case profile, profileDevice
    var scope: SettingScope { self == .profile ? .profile : .profileDevice }
}
enum SettingJSONValue: Equatable, Sendable { case null, string(String) }
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
    var failedKey: SettingKey?
    var offline = false
    var delay: Duration?
    var writes: [SettingKey] = []

    func owner() async throws -> SettingsBackupRemoteOwner {
        SettingsBackupRemoteOwner(
            request: HTTPRequestIdentity(serverId: "local", serverURL: "https://example.invalid",
                                         profileId: "profile", clientFamily: "ios"), scope: scope)
    }
    func read(_ keys: [SettingKey], owner: SettingsBackupRemoteOwner) async throws -> EffectiveSettingValuesResponse {
        if let delay { try await Task.sleep(for: delay) }
        if offline { throw Failure.offline }
        var rows: [SettingKey: EffectiveSettingValue] = [:]
        for key in keys {
            let value = values[key]
            rows[key] = EffectiveSettingValue(
                key: key.rawValue,
                value: value ?? (key == .playbackPreferredQuality ? .string("auto") : .null),
                storedValue: nil,
                scope: value == nil ? nil : key == .playbackSubtitleLanguage ? .profile : .profileDevice,
                profileId: value == nil ? nil : "profile")
        }
        return EffectiveSettingValuesResponse(byKey: rows)
    }
    func put(_ key: SettingKey, scope: SettingScopeIdentity, value: SettingJSONValue,
             owner: SettingsBackupRemoteOwner) async throws {
        if offline || key == failedKey { throw Failure.offline }
        values[key] = value
        writes.append(key)
    }
    func delete(_ key: SettingKey, scope: SettingScopeIdentity,
                owner: SettingsBackupRemoteOwner) async throws {
        if offline || key == failedKey { throw Failure.offline }
        values[key] = nil
        writes.append(key)
    }
    func change(_ key: SettingKey, _ value: SettingJSONValue) { values[key] = value }
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
        precondition(model.preview?.skippedCount == 3)
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

        print("SettingsBackupUnifiedHostChecks: 10 passed")
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
