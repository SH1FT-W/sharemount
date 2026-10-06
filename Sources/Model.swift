import Foundation

/// Eine SMB-Freigabe, die automatisch eingebunden werden soll.
struct Share: Codable, Identifiable, Hashable {
    var id = UUID()
    var host: String
    var share: String
    var user: String
    var enabled = true
    /// Eigener Anzeigename (seit 2.0, optional). Leer = Name der Freigabe.
    var name: String?

    var displayName: String {
        let n = name?.trimmingCharacters(in: .whitespaces) ?? ""
        return n.isEmpty ? share : n
    }
    var address: String { "smb://\(user)@\(host)/\(share)" }

    var url: URL? {
        var c = URLComponents()
        c.scheme = "smb"
        c.host = host
        c.path = "/" + share
        return c.url
    }

    /// Erwarteter Einhängepunkt ohne „-1“-Anhängsel.
    var cleanMountPath: String { "/Volumes/" + share }

    init(host: String, share: String, user: String, enabled: Bool = true, name: String? = nil) {
        self.host = host; self.share = share; self.user = user; self.enabled = enabled; self.name = name
    }

    enum CodingKeys: String, CodingKey { case id, host, share, user, enabled, name }

    // Tolerant beim Lesen, falls shares.json von Hand bearbeitet wird.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        host = try c.decode(String.self, forKey: .host)
        share = try c.decode(String.self, forKey: .share)
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? NSUserName()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        name = try c.decodeIfPresent(String.self, forKey: .name)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(host, forKey: .host)
        try c.encode(share, forKey: .share)
        try c.encode(user, forKey: .user)
        try c.encode(enabled, forKey: .enabled)
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { try c.encode(name, forKey: .name) }
    }

    func matches(host h: String, share s: String) -> Bool {
        Self.normalizeHost(host).caseInsensitiveCompare(Self.normalizeHost(h)) == .orderedSame
            && share.caseInsensitiveCompare(s) == .orderedSame
    }

    /// Finder-Seitenleiste mountet per Bonjour-Dienstname („NAS._smb._tcp.local“) – das ist kein
    /// auflösbarer Hostname. Wird zu „NAS.local“; Port („host:445“) fällt weg; Leerzeichen → „-“.
    static func normalizeHost(_ raw: String) -> String {
        var h = raw.removingPercentEncoding ?? raw
        if let r = h.range(of: "._smb._tcp", options: .caseInsensitive) {
            h = String(h[..<r.lowerBound]).replacingOccurrences(of: " ", with: "-") + ".local"
        }
        if !h.hasPrefix("["), let colon = h.lastIndex(of: ":"), h.firstIndex(of: ":") == colon,
           Int(h[h.index(after: colon)...]) != nil {
            h = String(h[..<colon])
        }
        return h.hasSuffix(".") ? String(h.dropLast()) : h
    }

    /// „smb://user@host/share“, „//host/share“ oder „host/share“ → Teile (für Einfügen im Editor).
    static func parse(address raw: String) -> (host: String, share: String, user: String?)? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for p in ["smb://", "cifs://", "//", "\\\\"] where s.lowercased().hasPrefix(p) { s = String(s.dropFirst(p.count)); break }
        s = s.replacingOccurrences(of: "\\", with: "/")
        var user: String?
        if let slash = s.firstIndex(of: "/"), let at = s[..<slash].lastIndex(of: "@") {
            var u = String(s[..<at])
            if let colon = u.firstIndex(of: ":") { u = String(u[..<colon]) }        // Passwort in der URL ignorieren
            if let semi = u.lastIndex(of: ";") { u = String(u[u.index(after: semi)...]) }
            user = u.removingPercentEncoding ?? u
            s = String(s[s.index(after: at)...])
        }
        guard let slash = s.firstIndex(of: "/") else { return nil }
        let host = normalizeHost(String(s[..<slash]))
        let share = String(s[s.index(after: slash)...]).split(separator: "/").first.map(String.init) ?? ""
        guard !host.isEmpty, !share.isEmpty else { return nil }
        return (host, share.removingPercentEncoding ?? share, user)
    }
}

struct Usage: Equatable {
    let free: Int64
    let total: Int64
    var fraction: Double { total > 0 ? Double(total - free) / Double(total) : 0 }
    var freeText: String { ByteCountFormatter.string(fromByteCount: free, countStyle: .file) + " " + L("frei", "free") }
    var totalText: String { ByteCountFormatter.string(fromByteCount: total, countStyle: .file) }
}

enum AppInfo {
    static var version: String {
        #if SNAPSHOT
        if let v = versionOverride { return v }
        #endif
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
    #if SNAPSHOT
    nonisolated(unsafe) static var versionOverride: String?
    #endif

    /// Bundle-ID der App (wie in Info.plist). Der Updater nimmt nur Releases mit genau dieser ID an.
    static let bundleID = "io.github.sh1ft-w.sharemount"
}

enum ShareStatus: Equatable {
    case checking
    case mounted(String)
    case mounting
    case unreachable
    case stale
    case failed(String)
    /// Benutzer/Passwort falsch – kein automatischer Neuversuch, damit das NAS-Konto nicht gesperrt wird.
    case authFailed
    case disconnected
    case disabled
    case waitingForNetwork

    var text: String {
        switch self {
        case .checking: return L("Prüfe …", "Checking…")
        case .mounted: return L("Verbunden", "Connected")
        case .mounting: return L("Verbinde …", "Connecting…")
        case .unreachable: return L("Server nicht erreichbar", "Server not reachable")
        case .stale: return L("Reagiert nicht, prüfe erneut", "Not responding, checking again")
        case .failed(let m): return m
        case .authFailed: return L("Anmeldung abgelehnt: Passwort prüfen", "Login rejected: check the password")
        case .disconnected: return L("Getrennt (manuell)", "Disconnected manually")
        case .disabled: return L("Automatik aus", "Auto-connect off")
        case .waitingForNetwork: return L("Warte auf WLAN/LAN …", "Waiting for Wi-Fi or Ethernet…")
        }
    }

    var isProblem: Bool {
        switch self {
        case .failed, .stale, .authFailed: return true
        default: return false
        }
    }

    var isMounted: Bool { if case .mounted = self { return true }; return false }
    var isBusy: Bool { switch self { case .mounting, .checking: return true; default: return false } }
}

/// Ein Eintrag im Verlauf einer Freigabe (nur im Speicher, fürs Menü/Einstellungen).
struct ShareEvent: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let text: String
    let problem: Bool
}
