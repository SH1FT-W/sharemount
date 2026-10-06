import Foundation
import NetFS
import Network

struct MountInfo: Equatable {
    let host: String
    let share: String
    let user: String
    let path: String
}

/// Alles, was blockieren kann, läuft hier im Hintergrund und immer mit Zeitlimit.
enum Mounter {

    // MARK: Aktuelle Mounts (MNT_NOWAIT = fragt den Server nicht, blockiert nie)

    /// Nur Mounts, die dem Benutzer gehören. Time Machine bindet dieselbe Freigabe zusätzlich
    /// unsichtbar unter /Volumes/.timemachine ein (nobrowse) – die fassen wir nie an: bis 1.7 wurde
    /// dieser Mount gelegentlich für „unseren“ gehalten, geprüft und zwangsweise gelöst.
    static func current() -> [MountInfo] {
        var result: [MountInfo] = []
        for var s in table() {
            guard cString(&s.f_fstypename) == "smbfs" else { continue }
            let on = cString(&s.f_mntonname)
            if s.f_flags & UInt32(MNT_DONTBROWSE) != 0 || on.hasPrefix("/Volumes/.") { continue }
            if let m = parse(from: cString(&s.f_mntfromname), path: on) { result.append(m) }
        }
        return result
    }

    /// "//DOMAIN;user@host/share" → Teile
    static func parse(from: String, path: String) -> MountInfo? {
        var rest = from.hasPrefix("//") ? String(from.dropFirst(2)) : from
        var user = ""
        if let at = rest.lastIndex(of: "@") {
            user = String(rest[..<at])
            if let semi = user.lastIndex(of: ";") { user = String(user[user.index(after: semi)...]) }
            rest = String(rest[rest.index(after: at)...])
        }
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let host = Share.normalizeHost(String(rest[..<slash]))
        let share = String(rest[rest.index(after: slash)...])
        return MountInfo(host: host,
                         share: share.removingPercentEncoding ?? share,
                         user: user.removingPercentEncoding ?? user,
                         path: path)
    }

    /// Bei mehreren Mounts derselben Freigabe gewinnt der unter dem sauberen Pfad.
    static func find(_ s: Share, in mounts: [MountInfo] = current()) -> MountInfo? {
        let hits = mounts.filter { s.matches(host: $0.host, share: $0.share) }
        return hits.first { $0.path == s.cleanMountPath } ?? hits.first
    }

    private static func cString<T>(_ field: inout T) -> String {
        withUnsafePointer(to: &field) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) }
        }
    }

    // MARK: Einhängepunkt

    /// Ist der Pfad gerade irgendein Einhängepunkt? (MNT_NOWAIT – blockiert nie)
    static func isMountPoint(_ path: String) -> Bool {
        table().contains { var s = $0; return cString(&s.f_mntonname) == path }
    }

    /// Eigener Puffer statt getmntinfo – dessen statischer Puffer ist nicht threadsicher,
    /// und die Mount-Tabelle wird hier aus mehreren Threads gelesen.
    private static func table() -> Array<statfs> {
        for _ in 0..<3 {
            let count = getfsstat(nil, 0, MNT_NOWAIT)
            guard count > 0 else { return [] }
            var buf = Array(repeating: statfs(), count: Int(count) + 4)
            let got = buf.withUnsafeMutableBufferPointer {
                getfsstat($0.baseAddress, Int32($0.count * MemoryLayout<statfs>.stride), MNT_NOWAIT)
            }
            if got >= 0 && Int(got) < buf.count { return Array(buf.prefix(Int(got))) }
        }
        return []
    }

    /// Nach dem Lösen verschwindet der Ordner in /Volumes oft erst ein paar Sekunden später.
    /// Wer vorher neu einbindet, landet auf „Name-1“ (kam nach dem Aufwachen vor).
    static func waitUntilFree(_ path: String, timeout: TimeInterval = 8) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, isMountPoint(path) || FileManager.default.fileExists(atPath: path) {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    /// Ein leerer, verwaister Ordner unter /Volumes blockiert den sauberen Pfad.
    /// Gehört er uns, räumen wir ihn weg; gehört er root (abgebrochener Mount), geht das nur mit sudo.
    @discardableResult
    static func clearLeftover(_ path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path), !isMountPoint(path) else { return true }
        return rmdir(path) == 0
    }

    // MARK: Erreichbarkeit (TCP 445, kurzer Timeout)

    static func reachable(_ host: String, timeout: TimeInterval = 3) async -> Bool {
        await withCheckedContinuation { cont in
            let conn = NWConnection(host: NWEndpoint.Host(host), port: 445, using: .tcp)
            let lock = NSLock()
            var done = false
            let finish: (Bool) -> Void = { ok in
                lock.lock(); let first = !done; done = true; lock.unlock()
                guard first else { return }
                conn.cancel()
                cont.resume(returning: ok)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .waiting: finish(false)
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }

    // MARK: Reagiert der Mount? (echtes Lesen mit Timeout, liefert nebenbei den Speicherplatz)

    private static let probeLock = NSLock()
    nonisolated(unsafe) private static var hanging: Set<String> = []

    enum Probe: Equatable { case ok(Usage), dead, stillHanging
        var usage: Usage? { if case .ok(let u) = self { return u }; return nil }
    }

    /// .stillHanging = ein früherer Prüf-Thread hängt noch an diesem Pfad (z. B. am alten, gelösten Mount) –
    /// das sagt nichts über den aktuellen Mount aus und zählt nicht als Fehlschlag.
    static func check(_ path: String, timeout: TimeInterval = 10) async -> Probe {
        let alreadyHanging = probeLock.withLock { hanging.contains(path) }
        if alreadyHanging { return .stillHanging }
        return await probe(path, timeout: timeout).map { .ok($0) } ?? .dead
    }

    /// nil = Mount reagiert nicht.
    static func probe(_ path: String, timeout: TimeInterval = 10) async -> Usage? {
        // Hängt schon ein Prüf-Thread an diesem Pfad, keinen weiteren dazustapeln.
        let alreadyHanging = probeLock.withLock { hanging.insert(path).inserted == false }
        if alreadyHanging { return nil }

        return await withCheckedContinuation { cont in
            let lock = NSLock()
            var done = false
            let finish: (Usage?) -> Void = { u in
                lock.lock(); let first = !done; done = true; lock.unlock()
                if first { cont.resume(returning: u) }
            }
            // Eigener Thread: hängt der Mount, hängt nur dieser – nicht die App.
            Thread.detachNewThread {
                defer { _ = probeLock.withLock { hanging.remove(path) } }
                guard let dir = opendir(path) else { finish(nil); return }
                _ = readdir(dir)
                closedir(dir)
                var st = statfs()
                guard statfs(path, &st) == 0 else { finish(nil); return }
                let bs = Int64(st.f_bsize)
                finish(Usage(free: Int64(st.f_bavail) * bs, total: Int64(st.f_blocks) * bs))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    // MARK: Einbinden

    /// Asynchron mit Zeitlimit: NetFSMountURLSync kann in NetAuth ewig hängen
    /// (eine Freigabe blieb so dauerhaft auf „Verbinde …“ stehen). Nach Ablauf wird die Anfrage abgebrochen.
    /// ui = macOS-Anmeldedialog zeigen (mit „Im Schlüsselbund sichern“) – nur auf ausdrücklichen Klick.
    static func mount(_ s: Share, password: String?, ui: Bool = false, timeout: TimeInterval = 45) async -> Result<String, MountError> {
        let timeout = ui ? 300 : timeout     // Zeit zum Tippen
        guard let url = s.url else { return .failure(MountError(code: -1)) }
        return await withCheckedContinuation { cont in
            let lock = NSLock()
            var done = false
            let finish: (Result<String, MountError>) -> Void = { r in
                lock.lock(); let first = !done; done = true; lock.unlock()
                if first { cont.resume(returning: r) }
            }
            let open = NSMutableDictionary()
            open[kNAUIOptionKey as String] = ui ? kNAUIOptionForceUI : kNAUIOptionNoUI   // sonst niemals Dialoge
            let opts = NSMutableDictionary()
            opts[kNetFSSoftMountKey as String] = true             // Zugriffe laufen in Timeout statt ewig zu hängen
            var request: AsyncRequestID?
            let rc = NetFSMountURLAsync(url as CFURL, nil,
                                        s.user as CFString,
                                        password.map { $0 as CFString },
                                        open, opts, &request,
                                        DispatchQueue.global(qos: .userInitiated)) { status, _, points in
                let paths = points as? [String] ?? []
                if status == 0, let p = paths.first {
                    finish(.success(p))
                } else if status == EEXIST, let m = find(s) {
                    finish(.success(m.path))
                } else {
                    finish(.failure(MountError(code: status)))
                }
            }
            guard rc == 0 else { finish(.failure(MountError(code: rc))); return }
            nonisolated(unsafe) let req = request   // Zeiger nur zum Abbrechen
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                lock.lock(); let open = !done; lock.unlock()
                guard open else { return }
                if let req { _ = NetFSMountURLCancel(req) }
                finish(.failure(MountError(code: ETIMEDOUT)))
            }
        }
    }

    // MARK: Aushängen

    static func unmount(_ path: String, force: Bool) async -> Bool {
        if force {
            if await Shell.run("/usr/sbin/diskutil", ["unmount", "force", path], timeout: 15) { return true }
            return await Shell.run("/sbin/umount", ["-f", path], timeout: 15)
        }
        return await Shell.run("/usr/sbin/diskutil", ["unmount", path], timeout: 15)
    }
}

struct MountError: Error, Equatable {
    let code: Int32

    /// NetFS liefert bei falschem Passwort je nach Server EAUTH, EACCES oder EPERM.
    var isAuth: Bool { code == EAUTH || code == EACCES || code == EPERM }
    /// Anmeldedialog abgebrochen (userCanceledErr / ECANCELED).
    var isCancel: Bool { code == -128 || code == ECANCELED }

    var text: String {
        switch code {
        case EAUTH, EACCES, EPERM: return L("Anmeldung fehlgeschlagen: Passwort prüfen", "Login failed: check the password")
        case ENOENT: return L("Freigabe nicht gefunden", "Share not found")
        case ETIMEDOUT: return L("Zeitüberschreitung", "Timed out")
        case -128, ECANCELED: return L("Abgebrochen", "Canceled")
        case EHOSTDOWN, EHOSTUNREACH, ENETUNREACH: return L("Server nicht erreichbar", "Server not reachable")
        case -1: return L("Ungültige Adresse", "Invalid address")
        default:
            if code > 0 && code < 200 { return L("Fehler", "Error") + " \(code): \(String(cString: strerror(code)))" }
            return L("Fehler", "Error") + " \(code)"
        }
    }
}
