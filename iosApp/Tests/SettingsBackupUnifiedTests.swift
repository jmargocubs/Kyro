#if os(iOS)
import XCTest
@testable import Silo

private actor FakeBackupRemoteTransport: SettingsBackupRemoteTransport {
    enum Failure: Error { case offline }

    private var destination = SettingsBackupRemoteOwner(
        request: HTTPRequestIdentity(serverId: "server-local", serverURL: "https://example.invalid",
                                     profileId: "profile-one", clientFamily: "ios"),
        scope: SettingsBackupScope(serverFingerprint: String(repeating: "a", count: 64),
                                   profileFingerprint: String(repeating: "b", count: 64)))
    private var stored: [SettingKey: SettingJSONValue] = [
        .playbackPreferredQuality: .string("1080p"),
        .playbackSubtitleLanguage: .string("en"),
    ]
    private var failedKey: SettingKey?
    private var offline = false
    private var delay: Duration?
    private(set) var writes: [SettingKey] = []

    func owner() async throws -> SettingsBackupRemoteOwner { destination }

    func read(_ keys: [SettingKey], owner: SettingsBackupRemoteOwner) async throws -> EffectiveSettingValuesResponse {
        if let delay { try await Task.sleep(for: delay) }
        if offline { throw Failure.offline }
        let rows = keys.map { key -> EffectiveSettingValue in
            let scope: SettingScope = key == .playbackPreferredQuality ? .profileDevice : .profile
            let value = stored[key]
            return EffectiveSettingValue(
                key: key.rawValue,
                value: value ?? (key == .playbackPreferredQuality ? .string("auto") : .null),
                source: value == nil ? .contractDefault : .scope(scope),
                scope: value == nil ? nil : scope,
                profileId: value == nil ? nil : destination.request.profileId)
        }
        return EffectiveSettingValuesResponse(settings: rows, revision: SettingKey.revision)
    }

    func put(_ key: SettingKey, scope: SettingScopeIdentity, value: SettingJSONValue,
             owner: SettingsBackupRemoteOwner) async throws {
        if offline || key == failedKey { throw Failure.offline }
        guard owner.request == destination.request else { throw SettingsBackupRemoteError.changedOwner }
        stored[key] = value
        writes.append(key)
    }

    func delete(_ key: SettingKey, scope: SettingScopeIdentity,
                owner: SettingsBackupRemoteOwner) async throws {
        if offline || key == failedKey { throw Failure.offline }
        stored[key] = nil
        writes.append(key)
    }

    func set(_ key: SettingKey, to value: SettingJSONValue?) { stored[key] = value }
    func value(_ key: SettingKey) -> SettingJSONValue? { stored[key] }
    func fail(_ key: SettingKey?) { failedKey = key }
    func setOffline(_ flag: Bool) { offline = flag }
    func setDelay(_ value: Duration?) { delay = value }
    func moveProfile() {
        destination = SettingsBackupRemoteOwner(
            request: HTTPRequestIdentity(serverId: destination.request.serverId,
                                         serverURL: destination.request.serverURL,
                                         profileId: "profile-two", clientFamily: destination.request.clientFamily),
            scope: SettingsBackupScope(serverFingerprint: destination.scope.serverFingerprint,
                                       profileFingerprint: String(repeating: "c", count: 64)))
    }
}

private final class MemoryRemoteBackupJournal: RemoteBackupJournalStoring {
    var record: RemoteBackupJournal?
    func load() throws -> RemoteBackupJournal? { record }
    func save(_ journal: RemoteBackupJournal) throws { record = journal }
    func clear() throws { record = nil }
}

@MainActor
final class SettingsBackupUnifiedTests: XCTestCase {
    private let app = SettingsBackupAppInfo(version: "1", build: "95", platform: "iOS", idiom: "phone")

    private func makeModel(
        local: BackupFakeStore, transport: FakeBackupRemoteTransport,
        remoteJournal: MemoryRemoteBackupJournal = MemoryRemoteBackupJournal()
    ) -> SettingsBackupModel {
        SettingsBackupModel(
            registry: local.registry(), journal: BackupMemoryJournal(), app: app,
            remote: SettingsBackupRemoteAdapter(transport: transport, journal: remoteJournal))
    }

    func testOneFileRoundTripRestoresLocalResolutionAndSubtitleFromAuthoritativeOwners() async throws {
        let local = BackupFakeStore(["navigation.fourthTab": .string("sports")])
        let transport = FakeBackupRemoteTransport()
        let model = makeModel(local: local, transport: transport)
        model.exportSelection = [.navigation, .streaming, .subtitles]
        let exported = await model.exportUnifiedDocument()
        let data = try XCTUnwrap(exported)
        let decoded = try SettingsBackupCodec.decode(data)
        XCTAssertEqual(decoded.schemaVersion, 2)
        XCTAssertNotNil(decoded.scope)
        XCTAssertEqual(decoded.groups["streaming"]?["streaming.resolution"], .string("1080p"))
        XCTAssertEqual(decoded.groups["subtitles"]?["subtitles.language"], .string("en"))

        local.values["navigation.fourthTab"] = .string("forYou")
        await transport.set(.playbackPreferredQuality, to: .string("480p"))
        await transport.set(.playbackSubtitleLanguage, to: .string("zh"))
        await model.loadUnifiedImport(data: data)
        XCTAssertEqual(model.selectedChangeCount, 3)
        await model.applyUnifiedSelected()
        XCTAssertEqual(local.values["navigation.fourthTab"], .string("sports"))
        let resolution = await transport.value(.playbackPreferredQuality)
        let language = await transport.value(.playbackSubtitleLanguage)
        XCTAssertEqual(resolution, .string("1080p"))
        XCTAssertEqual(language, .string("en"))
        XCTAssertEqual(model.lastRestoredCount, 3)
    }

    func testDifferentProfileSkipsRemoteWithoutWritingIt() async throws {
        let local = BackupFakeStore(["navigation.fourthTab": .string("sports")])
        let transport = FakeBackupRemoteTransport()
        let model = makeModel(local: local, transport: transport)
        model.exportSelection = [.navigation, .streaming, .subtitles]
        let exported = await model.exportUnifiedDocument()
        let data = try XCTUnwrap(exported)
        await transport.moveProfile()
        await model.loadUnifiedImport(data: data)
        let remote = model.preview?.groups.filter { [.streaming, .subtitles].contains($0.group) }
        XCTAssertEqual(remote?.flatMap(\.items).count, 2)
        XCTAssertTrue(remote?.flatMap(\.items).allSatisfy {
            if case .unsupported = $0.status { return true }; return false
        } ?? false)
        let writes = await transport.writes
        XCTAssertTrue(writes.isEmpty)
    }

    func testOfflineReadNeverFallsBackToCachedValues() async throws {
        let transport = FakeBackupRemoteTransport()
        let model = makeModel(local: BackupFakeStore(["navigation.fourthTab": .string("sports")]),
                              transport: transport)
        model.exportSelection = [.navigation, .streaming, .subtitles]
        await transport.setOffline(true)
        let exported = await model.exportUnifiedDocument()
        XCTAssertNil(exported)
        XCTAssertNotNil(model.banner)
    }

    func testPartialRemoteFailureKeepsUndoPointAndDoesNotApplyLocal() async throws {
        let local = BackupFakeStore(["navigation.fourthTab": .string("sports")])
        let transport = FakeBackupRemoteTransport()
        let journal = MemoryRemoteBackupJournal()
        let model = makeModel(local: local, transport: transport, remoteJournal: journal)
        model.exportSelection = [.navigation, .streaming, .subtitles]
        let exported = await model.exportUnifiedDocument()
        let data = try XCTUnwrap(exported)
        local.values["navigation.fourthTab"] = .string("forYou")
        await transport.set(.playbackPreferredQuality, to: .string("480p"))
        await transport.set(.playbackSubtitleLanguage, to: .string("zh"))
        await transport.fail(.playbackSubtitleLanguage)
        await model.loadUnifiedImport(data: data)
        await model.applyUnifiedSelected()
        XCTAssertEqual(local.values["navigation.fourthTab"], .string("forYou"))
        let resolution = await transport.value(.playbackPreferredQuality)
        let language = await transport.value(.playbackSubtitleLanguage)
        XCTAssertEqual(resolution, .string("1080p"))
        XCTAssertEqual(language, .string("zh"))
        XCTAssertEqual(journal.record?.state, .applying)
        XCTAssertTrue(model.needsRecovery)
    }

    func testLegacyFileRestoresLocalAndHasNoRemoteItems() async throws {
        let local = BackupFakeStore(["navigation.fourthTab": .string("forYou")])
        let transport = FakeBackupRemoteTransport()
        let model = makeModel(local: local, transport: transport)
        let data = try SettingsBackupCodec.makeDocument(
            groups: ["navigation": ["navigation.fourthTab": .string("sports")]],
            schemaVersion: 1, minReaderVersion: 1, app: app, now: Date())
        await model.loadUnifiedImport(data: data)
        XCTAssertEqual(model.selectedChangeCount, 1)
        await model.applyUnifiedSelected()
        XCTAssertEqual(local.values["navigation.fourthTab"], .string("sports"))
        let writes = await transport.writes
        XCTAssertTrue(writes.isEmpty)
    }

    func testRemoteValuesRequireSchemaTwoAndScope() throws {
        let data = try SettingsBackupCodec.makeDocument(
            groups: ["streaming": ["streaming.resolution": .string("480p")]],
            schemaVersion: 1, minReaderVersion: 1, app: app, now: Date())
        XCTAssertThrowsError(try SettingsBackupCodec.decode(data)) { error in
            XCTAssertEqual(error as? SettingsBackupError, .unsafeContent)
        }
    }

    func testTimedReadFailsRatherThanUsingLocalCache() async throws {
        let transport = FakeBackupRemoteTransport()
        await transport.setDelay(.milliseconds(200))
        let adapter = SettingsBackupRemoteAdapter(
            transport: transport, journal: MemoryRemoteBackupJournal(), timeout: .milliseconds(20))
        do {
            _ = try await adapter.export()
            XCTFail("A timed-out authoritative read must not produce a backup")
        } catch { XCTAssertTrue(error is SettingsBackupRemoteError) }
    }
}
#endif
