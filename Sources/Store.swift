import Foundation

/// Konfiguration als lesbares JSON. Mit iCloud Drive liegt sie in iCloud Drive › Software › ShareMount und
/// wird so zwischen allen Macs mit derselben Apple-ID abgeglichen; sonst lokal in Application Support.
/// Passwörter wandern NICHT mit – die bleiben im Schlüsselbund des jeweiligen Macs.
enum Store {
    static let localDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ShareMount")
    static let iCloudRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")

    static var isSynced: Bool { FileManager.default.fileExists(atPath: iCloudRoot.path) }
    static var dir: URL { isSynced ? iCloudRoot.appendingPathComponent("Software/ShareMount") : localDir }
    static var file: URL { dir.appendingPathComponent("shares.json") }
    /// Ort bis v1.6 (iCloud Drive › ShareMount).
    static var oldDir: URL { iCloudRoot.appendingPathComponent("ShareMount") }

    /// Bestehende Konfiguration an den aktuellen Ort holen: lokal → iCloud Drive (einmalig) und
    /// iCloud Drive › ShareMount → iCloud Drive › Software › ShareMount. Läuft auch beim 10-s-Poll,
    /// damit ein Mac mit alter Version, der noch an den alten Ort schreibt, nicht abgehängt wird.
    static func migrateIfNeeded() {
        let fm = FileManager.default
        guard isSynced else { return }
        let old = oldDir.appendingPathComponent("shares.json")
        if fm.fileExists(atPath: old.path), (try? JSONDecoder().decode([Share].self, from: Data(contentsOf: old))) != nil {
            let oldDate = (try? fm.attributesOfItem(atPath: old.path))?[.modificationDate] as? Date
            if !fm.fileExists(atPath: file.path) || (oldDate ?? .distantPast) > (modificationDate() ?? .distantPast) {
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try? fm.removeItem(at: file)
                if (try? fm.moveItem(at: old, to: file)) != nil {
                    Log.write(L("Einstellungen nach iCloud Drive › Software › ShareMount verschoben", "Settings moved to iCloud Drive › Software › ShareMount"))
                }
            } else {
                try? fm.removeItem(at: old)
            }
            if (try? fm.contentsOfDirectory(atPath: oldDir.path))?.filter({ !$0.hasPrefix(".") }).isEmpty == true {
                try? fm.removeItem(at: oldDir)
            }
        }
        let local = localDir.appendingPathComponent("shares.json")
        guard !fm.fileExists(atPath: file.path), fm.fileExists(atPath: local.path) else { return }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if (try? fm.copyItem(at: local, to: file)) != nil {
            Log.write(L("Einstellungen nach iCloud Drive übernommen", "Settings copied to iCloud Drive"))
        }
    }

    static func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    }

    /// nil = Datei fehlt oder ist (noch) nicht lesbar, z. B. weil iCloud sie gerade schreibt.
    static func loadIfValid() -> [Share]? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode([Share].self, from: data)
    }

    static func load() -> [Share] { loadIfValid() ?? [] }

    /// Vor dem Überschreiben eine Kopie (shares.backup.json) – falls eine Bearbeitung danebengeht.
    static func save(_ shares: [Share]) {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let backup = dir.appendingPathComponent("shares.backup.json")
        if fm.fileExists(atPath: file.path) {
            try? fm.removeItem(at: backup)
            try? fm.copyItem(at: file, to: backup)
        }
        try? encode(shares).write(to: file, options: .atomic)
    }

    static func encode(_ shares: [Share]) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(shares)
    }
}

/// Protokoll unter ~/Library/Logs/ShareMount.log (in der Konsole-App lesbar).
enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ShareMount.log")
    static var oldURL: URL { url.deletingPathExtension().appendingPathExtension("old.log") }
    private static let queue = DispatchQueue(label: "sharemount.log")
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// Über 512 KB → nach ShareMount.old.log verschieben (beim Start und, weil die App wochenlang läuft,
    /// auch unterwegs beim Schreiben).
    static func rotate() {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size > 512_000 else { return }
        try? FileManager.default.removeItem(at: oldURL)
        try? FileManager.default.moveItem(at: url, to: oldURL)
    }

    static func write(_ msg: String) {
        let line = "\(fmt.string(from: Date()))  \(msg)\n"
        queue.async {
            if let h = try? FileHandle(forWritingTo: url) {
                let end = h.seekToEndOfFile()
                h.write(Data(line.utf8))
                try? h.close()
                if end > 512_000 { rotate() }
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }

    /// Die letzten Zeilen (für die Protokoll-Ansicht in den Einstellungen).
    static func tail(_ lines: Int = 400) -> [String] {
        queue.sync {}   // ausstehende Schreibvorgänge abwarten
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return Array(text.split(separator: "\n", omittingEmptySubsequences: true).suffix(lines).map(String.init))
    }
}
