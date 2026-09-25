import Foundation

/// On-disk JSON credential cache so the app never needs to touch the Keychain
/// on a warm restart. The file is stored in the app's support directory with
/// 0600 permissions (owner-only read/write).
///
/// The Keychain remains the canonical store; this is a cache that shadows it.
/// If the file is missing or corrupt, the app falls back to Keychain and
/// re-populates the file cache.
///
/// Read-modify-write is serialized under one lock: several providers can
/// persist concurrently, and without it a later write would overwrite an
/// earlier one's key. Each write stages through a uniquely named temp file so
/// concurrent writers cannot collide on the staging path either.
enum CredentialFileCache {
    private static let fileName = "credentials.json"
    private static let lock = NSLock()

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

    /// Write a single credential to the file cache, preserving existing
    /// entries. Returns whether the value was persisted.
    @discardableResult
    static func store(provider: String, value: String) -> Bool {
        guard let url = fileURL else { return false }
        return lock.withLock {
            var dict = loadAll()
            dict[provider] = value
            return write(dict, to: url)
        }
    }

    /// Remove a single credential from the file cache.
    @discardableResult
    static func clear(provider: String) -> Bool {
        guard let url = fileURL else { return false }
        return lock.withLock {
            var dict = loadAll()
            dict.removeValue(forKey: provider)
            return write(dict, to: url)
        }
    }

    /// Remove all credentials from the file cache.
    static func clearAll() {
        guard let url = fileURL else { return }
        _ = lock.withLock { write([:], to: url) }
    }

    private static func write(_ dict: [String: String], to url: URL) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) else {
            return false
        }
        // Atomically write with 0600 permissions.
        let fm = FileManager.default
        // Unique staging name: two concurrent writers must not share a temp
        // path (a write racing a rename would clobber the other's data).
        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(fileName).\(UUID().uuidString).tmp")
        do {
            try data.write(to: tempURL, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempURL.path)
            _ = try fm.replaceItemAt(url, withItemAt: tempURL,
                                     backupItemName: nil, options: .usingNewMetadataOnly)
            return true
        } catch {
            // Best-effort; the Keychain is the canonical store.
            UsageStore.log("CredentialFileCache write failed: \(error.localizedDescription)")
            // Clean up the temp file if it still exists.
            try? fm.removeItem(at: tempURL)
            return false
        }
    }
}
