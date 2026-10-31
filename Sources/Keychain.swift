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

/// Earlier versions could store an optional GitHub token for updates. The repository is public, so the
/// feature is gone; a token file left over from those versions is deleted once at launch.
enum TokenStore {
    static var file: URL { Store.localDir.appendingPathComponent("github-token") }

    static func removeLeftover() {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        try? FileManager.default.removeItem(at: file)
        Log.write(L("Alten GitHub-Token entfernt (Updates brauchen keinen Token)", "Removed old GitHub token (updates need no token)"))
    }
}
