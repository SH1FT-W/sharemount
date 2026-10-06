import Foundation
import Security

/// Passwörter: seit 2.0 ohne Schlüsselbund-Nachfragen nach Updates.
///
/// Die SMB-Passwörter liegen dort, wo auch der Finder sie ablegt: als Internet-Passwort (Protokoll smb,
/// Server, Benutzer). Diese Einträge gehören dem macOS-Anmeldedienst NetAuth. ShareMount liest sie nie selbst,
/// sondern verbindet ohne Passwort, NetAuth holt es sich. Hier wird nur nachgesehen, ob es einen Eintrag gibt.
enum Keychain {
    #if SNAPSHOT
    /// Snapshot/Selbsttest fassen den echten Schlüsselbund nie an.
    static let offline = true
    #else
    static let offline = false
    #endif

    // MARK: Finder-/NetAuth-Passwort (nur Metadaten – fragt nie nach)

    static func hasSystemPassword(user: String, host: String) -> Bool {
        if offline { return false }
        let q: [String: Any] = [kSecClass as String: kSecClassInternetPassword,
                                kSecAttrServer as String: host,
                                kSecAttrAccount as String: user,
                                kSecAttrProtocol as String: kSecAttrProtocolSMB,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        if SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess { return true }
        // Manche Server-Einträge haben Benutzernamen in anderer Schreibweise (alex/Alex).
        var all = q
        all.removeValue(forKey: kSecAttrAccount as String)
        all[kSecMatchLimit as String] = kSecMatchLimitAll
        all[kSecReturnAttributes as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(all as CFDictionary, &out) == errSecSuccess,
              let items = out as? [[String: Any]] else { return false }
        return items.contains { ($0[kSecAttrAccount as String] as? String)?.caseInsensitiveCompare(user) == .orderedSame }
    }
}

/// GitHub-Token für Updates (nur Lesen, nur das ShareMount-Repo). Liegt seit 2.0 als Datei nur für
/// diesen Benutzer lesbar (0600) in Application Support – im Schlüsselbund hätte er nach jedem Update
/// wieder eine Nachfrage ausgelöst.
enum TokenStore {
    static var file: URL { Store.localDir.appendingPathComponent("github-token") }

    static func read() -> String? {
        guard let t = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return t.isEmpty ? nil : t
    }

    static var exists: Bool {
        FileManager.default.fileExists(atPath: file.path)
    }

    @discardableResult
    static func write(_ token: String) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: Store.localDir, withIntermediateDirectories: true)
        if token.isEmpty {
            try? fm.removeItem(at: file)
            return true
        }
        guard fm.createFile(atPath: file.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600]) else {
            Log.write(L("GitHub-Token konnte nicht gespeichert werden", "Could not save the GitHub token"))
            return false
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return true
    }
}
