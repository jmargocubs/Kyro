import Foundation
import OSLog

/// Loads the Seekr API key from Keychain or an untracked local file.
/// Never logs the key value.
enum SeekrCredentials {
    static let keychainAccount = "seekr.api_key"
    /// Untracked path relative to the `iosApp/` folder that XcodeGen uses.
    static let localFileName = "SeekrAPIKey"

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.cubbiestream.kyro",
        category: "SeekrCredentials"
    )

    /// Returns a non-empty API key when one is configured.
    static func apiKey(
        keychain: SharedKeychain = SharedKeychain(audience: .userIndependent),
        fileManager: FileManager = .default,
        bundle: Bundle = .main
    ) -> String? {
        if let stored = keychain.get(keychainAccount)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !stored.isEmpty {
            return stored
        }
        if let seeded = readLocalFile(fileManager: fileManager, bundle: bundle) {
            // Seed Keychain so Release builds that ship without the file still
            // keep a previously imported key on this device. Failure to write
            // is fine — the file remains the source for this process.
            _ = keychain.set(seeded, for: keychainAccount)
            return seeded
        }
        return nil
    }

    @discardableResult
    static func store(
        _ key: String,
        keychain: SharedKeychain = SharedKeychain(audience: .userIndependent)
    ) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return keychain.set(trimmed, for: keychainAccount)
    }

    static func clear(keychain: SharedKeychain = SharedKeychain(audience: .userIndependent)) {
        keychain.delete(keychainAccount)
    }

    private static func readLocalFile(fileManager: FileManager, bundle: Bundle) -> String? {
        // Prefer Signing/SeekrAPIKey next to the xcodeproj (dev machines).
        let candidates: [URL] = {
            var urls: [URL] = []
            if let resource = bundle.url(forResource: "SeekrAPIKey", withExtension: nil) {
                urls.append(resource)
            }
            // Walk up from the bundle toward Signing/ during local debug runs.
            var directory = URL(fileURLWithPath: bundle.bundlePath)
            for _ in 0..<6 {
                directory.deleteLastPathComponent()
                urls.append(directory.appendingPathComponent("Signing/\(localFileName)"))
                urls.append(directory.appendingPathComponent(localFileName))
            }
            return urls
        }()

        for url in candidates {
            guard fileManager.isReadableFile(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("sk_") else { continue }
            logger.notice("Loaded Seekr API key from local untracked configuration.")
            return trimmed
        }
        return nil
    }
}
