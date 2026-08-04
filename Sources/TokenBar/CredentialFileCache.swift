import Foundation

/// On-disk JSON credential cache so the app never needs to touch the Keychain
/// on a warm restart. The file is stored in the app's support directory with
/// 0600 permissions (owner-only read/write).
///
/// The Keychain remains the canonical store; this is a cache that shadows it.
/// If the file is missing or corrupt, the app falls back to Keychain and
/// re-populates the file cache.
enum CredentialFileCache {
    private static let fileName = "credentials.json"

    /// ~/Library/Application Support/TokenBar/credentials.json
    private static var fileURL: URL? {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        let dir = support.appendingPathComponent("TokenBar", isDirectory: true)
        let fm = FileManager.default
        // Create the directory with 0700 if it does not exist.
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                    attributes: [FileAttributeKey.posixPermissions: 0o700])
        }
        return dir.appendingPathComponent(fileName)
    }

    /// Read all cached credentials. Returns empty dict on any error.
    static func loadAll() -> [String: String] {
        guard let url = fileURL else { return [:] }
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        return dict
    }

    /// Write a single credential to the file cache, preserving existing entries.
    static func store(provider: String, value: String) {
        guard let url = fileURL else { return }
        var dict = loadAll()
        dict[provider] = value
        write(dict, to: url)
    }

    /// Remove a single credential from the file cache.
    static func clear(provider: String) {
        guard let url = fileURL else { return }
        var dict = loadAll()
        dict.removeValue(forKey: provider)
        write(dict, to: url)
    }

    /// Remove all credentials from the file cache.
    static func clearAll() {
        guard let url = fileURL else { return }
        write([:], to: url)
    }

    private static func write(_ dict: [String: String], to url: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) else {
            return
        }
        // Atomically write with 0600 permissions.
        let fm = FileManager.default
        let tempURL = url.deletingLastPathComponent().appendingPathComponent(".\(fileName).tmp")
        do {
            try data.write(to: tempURL, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempURL.path)
            try fm.replaceItemAt(url, withItemAt: tempURL,
                                 backupItemName: nil, options: .usingNewMetadataOnly)
        } catch {
            // Best-effort; the Keychain is the canonical store.
            UsageStore.log("CredentialFileCache write failed: \(error.localizedDescription)")
            // Clean up the temp file if it still exists.
            try? fm.removeItem(at: tempURL)
        }
    }
}