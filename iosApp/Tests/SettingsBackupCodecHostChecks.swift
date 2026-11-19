#if KYRO_STANDALONE_TESTS
import Foundation

@main
enum SettingsBackupCodecHostChecks {
    static func main() throws {
        let app = SettingsBackupAppInfo(version: "1", build: "94", platform: "iOS", idiom: "phone")
        let local = ["navigation": ["navigation.fourthTab": BackupValue.string("sports")]]
        let legacy = try SettingsBackupCodec.makeDocument(
            groups: local, schemaVersion: 1, minReaderVersion: 1, app: app, now: Date())
        let legacyDecoded = try SettingsBackupCodec.decode(legacy)
        precondition(legacyDecoded.schemaVersion == 1 && legacyDecoded.scope == nil)
        precondition(legacyDecoded.groups == local)
        // Hash calculated from the schema-1 canonical payload before schema 2 existed.
        let oldFile = #"{"format":"kyro.settings-backup","schemaVersion":1,"minReaderVersion":1,"createdAt":"2026-01-01T00:00:00Z","payloadSha256":"9a7ccdb2e54a873a38a430453e2311b6593e6a8db4c258e33774431c7f652b63","payload":{"groups":{"navigation":{"navigation.fourthTab":"sports"}}}}"#
        let oldDecoded = try SettingsBackupCodec.decode(Data(oldFile.utf8))
        precondition(oldDecoded.groups == local)

        let scope = SettingsBackupScope(serverFingerprint: String(repeating: "a", count: 64),
                                        profileFingerprint: String(repeating: "b", count: 64))
        var combined = local
        combined["streaming"] = ["streaming.resolution": .string("480p")]
        combined["subtitles"] = ["subtitles.language": .string("zh")]
        let unified = try SettingsBackupCodec.makeUnifiedDocument(
            groups: combined, scope: scope, app: app, now: Date())
        let decoded = try SettingsBackupCodec.decode(unified)
        precondition(decoded.schemaVersion == 2 && decoded.scope == scope && decoded.groups == combined)

        let edited = String(decoding: unified, as: UTF8.self).replacingOccurrences(of: "480p", with: "720p")
        do {
            _ = try SettingsBackupCodec.decode(Data(edited.utf8))
            fatalError("Tampered backup passed integrity validation")
        } catch SettingsBackupError.integrityMismatch {}

        let unsafe = try SettingsBackupCodec.makeDocument(
            groups: ["streaming": ["streaming.resolution": .string("480p")]],
            schemaVersion: 1, minReaderVersion: 1, app: app, now: Date())
        do {
            _ = try SettingsBackupCodec.decode(unsafe)
            fatalError("Schema-1 file carried a scoped setting")
        } catch SettingsBackupError.unsafeContent {}

        do {
            _ = try SettingsBackupCodec.makeUnifiedDocument(
                groups: ["navigation": ["account.token": .string("secret")]],
                scope: scope, app: app, now: Date())
            fatalError("Credential-like setting passed the allowlist")
        } catch SettingsBackupError.unsafeContent {}

        print("SettingsBackupCodecHostChecks: 6 passed")
    }
}
#endif
