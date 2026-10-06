import AppKit
import CryptoKit
import Security

/// Updates aus den GitHub-Releases von SH1FT-W/sharemount.
/// Öffentliche Releases brauchen keinen Token. Ein Token (nur Lesen, siehe TokenStore) ist optional:
/// nur für ein privates Repo/einen privaten Fork oder wenn das GitHub-Limit ohne Anmeldung (60/Std.) erreicht ist.
/// Installiert wird nur, wenn Prüfsumme, Bundle-ID und Version stimmen und die Signatur gültig ist (ad-hoc, kein Zertifikat).
@MainActor
final class Updater: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String)
        case installing(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// Ablaufdatum des Tokens, wenn es in weniger als 30 Tagen abläuft.
    @Published private(set) var tokenExpiresSoon: Date?
    /// Versionshinweise des verfügbaren Updates (Release-Text auf GitHub).
    @Published private(set) var notes = ""
    @Published private(set) var lastCheck: Date?
    @Published private(set) var hasToken = false
    /// Zuletzt gefundene neuere Version (bleibt auch bei „Update fehlgeschlagen“ bekannt – fürs Update-Fenster).
    @Published private(set) var offeredVersion: String?

    static let repo = "SH1FT-W/sharemount"
    private var release: Release?
    private var timer: Timer?

    struct Release {
        let version: String
        let notes: String
        let zip: URL          // API-URL des Assets
        let checksum: URL
        /// Token, mit dem das Release gefunden wurde (nil = öffentlich, ohne Anmeldung).
        let token: String?
    }

    init() {
        hasToken = TokenStore.exists
        // Kurz nach dem Start, danach alle 6 Stunden still prüfen (abschaltbar in den Einstellungen).
        // Beim Start-Check erscheint bei einem Update das Fenster „Neue Version“.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard Prefs.shared.autoCheckUpdates else { return }
            Task { await self?.check(silent: true, atLaunch: true) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard Prefs.shared.autoCheckUpdates else { return }
                await self?.check(silent: true)
            }
        }
        showNotesAfterUpdate()
    }

    /// Token aus den Einstellungen speichern (statt per Terminal). Leer = löschen.
    func setToken(_ token: String) {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        TokenStore.write(t)
        hasToken = !t.isEmpty
        tokenExpiresSoon = nil
        Log.write(t.isEmpty ? L("GitHub-Token entfernt", "GitHub token removed") : L("GitHub-Token gespeichert", "GitHub token saved"))
        if !t.isEmpty { Task { await check() } } else { state = .idle }
    }

    /// Nach einem Update einmal „Was ist neu“ als Mitteilung zeigen.
    private func showNotesAfterUpdate() {
        guard let p = Prefs.shared.pendingNotes else { return }
        Prefs.shared.pendingNotes = nil
        guard p.version == AppInfo.version else { return }
        Notifier.send("update.done", title: L("ShareMount auf v\(p.version) aktualisiert", "ShareMount updated to v\(p.version)"),
                      body: p.notes.isEmpty ? L("Läuft.", "Up and running.") : String(p.notes.prefix(240)), force: true)
    }

    // MARK: Prüfen

    func check(silent: Bool = false, atLaunch: Bool = false) async {
        if case .installing = state { return }
        let token = TokenStore.read()      // optional – öffentliche Releases gehen ohne
        let previous = state
        // Stilles Prüfen ändert die Anzeige nicht (sonst verschwindet „Update installieren“ kurz aus dem Menü).
        if !silent { state = .checking }
        defer { lastCheck = Date() }
        do {
            var used = token
            var (data, http) = try await latestRelease(token: used)
            // Abgelaufener/ungültiger Token: ein öffentliches Repo geht auch ohne – dann ohne weiter.
            if http?.statusCode == 401, used != nil {
                let retry = try await latestRelease(token: nil)
                if retry.1?.statusCode == 200 {
                    (data, http, used) = (retry.0, retry.1, nil)
                    Log.write(L("Update-Prüfung: GitHub-Token ungültig, ohne Token geprüft", "Update check: GitHub token invalid, checked without token"))
                }
            }
            noteTokenExpiry(http)
            switch http?.statusCode ?? 0 {
            case 200: break
            case 401: throw Fail(L("Token ungültig oder abgelaufen", "Token invalid or expired"))
            case 403, 429:
                throw Fail(used == nil ? L("GitHub-Limit erreicht, später erneut versuchen", "GitHub rate limit reached, try again later")
                                       : L("Kein Zugriff auf \(Self.repo), Token prüfen", "No access to \(Self.repo), check the token"))
            case 404: throw Fail(used == nil ? L("Kein Release gefunden", "No release found")
                                            : L("Kein Release gefunden (oder Token ohne Zugriff)", "No release found (or the token has no access)"))
            case let c: throw Fail(L("GitHub antwortet mit \(c)", "GitHub responded with \(c)"))
            }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let tag = (json["tag_name"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            let assets = json["assets"] as? [[String: Any]] ?? []
            func asset(_ name: String) -> URL? {
                assets.first { $0["name"] as? String == name }
                    .flatMap { $0["url"] as? String }.flatMap(URL.init(string:))
            }
            guard !tag.isEmpty, let zip = asset("ShareMount.zip"), let sum = asset("ShareMount.zip.sha256") else {
                throw Fail(L("Release ohne ShareMount.zip/.sha256", "Release has no ShareMount.zip/.sha256"))
            }
            let body = Self.cleanNotes(json["body"] as? String ?? "")
            if Self.isNewer(tag, than: AppInfo.version) {
                release = Release(version: tag, notes: body, zip: zip, checksum: sum, token: used)
                notes = body
                offeredVersion = tag
                state = .available(version: tag)
                // Fenster nach dem Start und bei einer im Betrieb neu entdeckten Version – nicht bei „Jetzt suchen“
                // (da ist man ohnehin in den Einstellungen) und nicht für übersprungene Versionen.
                let fresh = Prefs.shared.notifiedUpdate != tag
                if fresh { Log.write(L("Update verfügbar: v\(tag)", "Update available: v\(tag)")) }
                Prefs.shared.notifiedUpdate = tag
                if silent && (atLaunch || fresh) && Prefs.shared.promptUpdates && Prefs.shared.skippedUpdate != tag {
                    UpdatePrompt.show(self)
                } else if fresh && Prefs.shared.skippedUpdate != tag {
                    // Je Version nur eine Mitteilung – bis 2.0 kam alle 6 Std. (und nach jedem Start) dieselbe.
                    Notifier.send("update.\(tag)", title: L("ShareMount v\(tag) ist da", "ShareMount v\(tag) is available"),
                                  body: body.isEmpty ? L("Im Menü „Update installieren“ wählen.", "Choose “Update to v\(tag)” in the menu.") : String(body.prefix(200)))
                }
            } else {
                release = nil
                notes = ""
                offeredVersion = nil
                state = .upToDate
            }
        } catch {
            let msg = (error as? Fail)?.text ?? L("GitHub nicht erreichbar", "GitHub not reachable")
            // Stilles Prüfen im Hintergrund: Fehler nur ins Protokoll, Menü bleibt ruhig.
            if silent {
                Log.write(L("Update-Prüfung", "Update check") + ": \(msg)")
                if case .failed = previous { state = .idle }   // alter Fehler ist überholt, Rest bleibt stehen
            } else { state = .failed(msg) }
        }
    }

    #if SNAPSHOT
    /// Nur für tools/snapshot.swift: Fenster mit Beispiel-Update rendern.
    func preview(_ v: String, notes n: String) { offeredVersion = v; notes = n; state = .available(version: v) }
    #endif

    // MARK: Installieren

    func install() async {
        guard let release else { return }
        if let problem = Self.targetProblem(Bundle.main.bundleURL) { state = .failed(problem); return }
        state = .installing(L("Lade v\(release.version) …", "Downloading v\(release.version)…"))
        Log.write(L("Update auf v\(release.version) gestartet", "Update to v\(release.version) started"))
        do {
            let work = FileManager.default.temporaryDirectory
                .appendingPathComponent("ShareMount-Update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

            state = .installing(L("Lade v\(release.version) …", "Downloading v\(release.version)…"))
            let zipData = try await download(release.zip, token: release.token)
            let sumText = String(decoding: try await download(release.checksum, token: release.token), as: UTF8.self)

            state = .installing(L("Prüfe …", "Verifying…"))
            let expected = sumText.split(whereSeparator: \.isWhitespace).first.map(String.init)?.lowercased() ?? ""
            let actual = SHA256.hash(data: zipData).map { String(format: "%02x", $0) }.joined()
            guard expected.count == 64, expected == actual else { throw Fail(L("Prüfsumme stimmt nicht", "Checksum does not match")) }

            let zipURL = work.appendingPathComponent("ShareMount.zip")
            try zipData.write(to: zipURL)
            guard await Shell.run("/usr/bin/ditto", ["-x", "-k", zipURL.path, work.path]) else {
                throw Fail(L("Entpacken fehlgeschlagen", "Could not unzip the download"))
            }
            let newApp = work.appendingPathComponent("ShareMount.app")
            _ = await Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])
            try await Task.detached { try Self.verifySignature(newApp) }.value   // Signaturprüfung dauert – nicht im Menü-Thread
            let newVersion = Bundle(url: newApp)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            guard newVersion == release.version else { throw Fail(L("Versionsnummer passt nicht zum Release", "Version number does not match the release")) }

            state = .installing(L("Starte neu …", "Restarting…"))
            Prefs.shared.pendingNotes = (release.version, release.notes)
            try launchSwapScript(newApp: newApp, work: work)
            Log.write(L("Update auf v\(release.version) geprüft, App wird ersetzt und neu gestartet", "Update to v\(release.version) verified, replacing and restarting the app"))
            NSApp.terminate(nil)
        } catch {
            let msg = (error as? Fail)?.text ?? error.localizedDescription
            Log.write(L("Update fehlgeschlagen", "Update failed") + ": \(msg)")
            state = .failed(L("Update fehlgeschlagen", "Update failed") + ": \(msg)")
        }
    }

    /// Ziel muss ersetzbar sein – sonst endet jeder Versuch in derselben Schleife (z. B. Start aus „Downloads“
    /// mit App-Translocation oder von einem schreibgeschützten Volume).
    private static func targetProblem(_ app: URL) -> String? {
        let move = L("Bitte ShareMount in den Ordner „Programme“ ziehen, von dort öffnen und das Update erneut starten.",
                     "Please move ShareMount to the Applications folder, open it from there and start the update again.")
        if app.path.contains("/AppTranslocation/") {
            return L("ShareMount läuft aus einem vorübergehenden Ort (macOS-Schutz für geladene Apps). ",
                     "ShareMount is running from a temporary location (macOS protection for downloaded apps). ") + move
        }
        let fm = FileManager.default
        if !fm.isWritableFile(atPath: app.deletingLastPathComponent().path) || !fm.isWritableFile(atPath: app.path) {
            return L("Der Ordner mit ShareMount ist nicht beschreibbar. ", "The folder containing ShareMount is not writable. ") + move
        }
        return nil
    }

    /// Gleiche Bundle-ID und gültige (ad-hoc-)Signatur. Ein festes Zertifikat gibt es bewusst nicht mehr –
    /// nach einem Update fragt der Schlüsselbund einmal nach („Immer erlauben“).
    nonisolated private static func verifySignature(_ app: URL) throws {
        guard let id = Bundle(url: app)?.bundleIdentifier, id == (Bundle.main.bundleIdentifier ?? AppInfo.bundleID) else {
            throw Fail(L("Falsche App im Release", "Wrong app in the release"))
        }
        var other: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &other) == errSecSuccess, let other else {
            throw Fail(L("Signatur nicht lesbar", "Signature not readable"))
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(other, flags, nil) == errSecSuccess else {
            throw Fail(L("Signatur ungültig, Update verworfen", "Invalid signature, update discarded"))
        }
    }

    /// Kleines Skript ersetzt die App, sobald sie beendet ist, und startet die neue.
    /// Schlägt das Verschieben fehl, kommt die alte App zurück.
    private func launchSwapScript(newApp: URL, work: URL) throws {
        let target = Bundle.main.bundleURL.path
        let script = work.appendingPathComponent("swap.sh")
        // Pfade als Argumente statt in den Skripttext eingesetzt – kein Zitat-/Sonderzeichen-Problem.
        let body = """
        #!/bin/zsh -f
        PID="$1"; TARGET="$2"; NEW="$3"; WORK="$4"; LOG="$5"
        while kill -0 "$PID" 2>/dev/null; do sleep 0.2; done
        OLD="$TARGET.alt"
        rm -rf "$OLD"
        if mv "$TARGET" "$OLD" && mv "$NEW" "$TARGET"; then
            rm -rf "$OLD"
        else
            [[ -d "$OLD" && ! -d "$TARGET" ]] && mv "$OLD" "$TARGET"
            echo "$(date '+%Y-%m-%d %H:%M:%S')  \(L("Update: Ersetzen fehlgeschlagen, alte Version bleibt", "Update: replacing failed, keeping the old version"))" >> "$LOG"
        fi
        open "$TARGET"
        rm -rf "$WORK"
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // -f: keine Startdateien des Benutzers (~/.zshenv) – das Skript läuft genau so, wie es hier steht.
        p.arguments = ["-f", script.path, "\(ProcessInfo.processInfo.processIdentifier)", target, newApp.path, work.path, Log.url.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
    }

    // MARK: Hilfen

    private func apiRequest(_ url: String, token: String?) -> URLRequest {
        var r = URLRequest(url: URL(string: url)!, timeoutInterval: 20)
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        r.setValue("ShareMount/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        return r
    }

    /// Asset-Download: GitHub leitet auf einen signierten Speicher-Link um –
    /// dorthin darf der Token nicht mit (sonst 400 und unnötig preisgegeben).
    private func latestRelease(token: String?) async throws -> (Data, HTTPURLResponse?) {
        var req = apiRequest("https://api.github.com/repos/\(Self.repo)/releases/latest", token: token)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.cachePolicy = .reloadIgnoringLocalCacheData      // nie eine zwischengespeicherte „neueste“ Version
        let (data, resp) = try await URLSession.shared.data(for: req)
        return (data, resp as? HTTPURLResponse)
    }

    private func download(_ url: URL, token: String?) async throws -> Data {
        var req = apiRequest(url.absoluteString, token: token)
        req.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 120
        let (data, resp) = try await URLSession.shared.data(for: req, delegate: StripAuthOnRedirect())
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw Fail(L("Download fehlgeschlagen", "Download failed")) }
        return data
    }

    private func noteTokenExpiry(_ http: HTTPURLResponse?) {
        // Header z. B. "2027-09-26 21:40:00 +0200"
        guard let raw = http?.value(forHTTPHeaderField: "github-authentication-token-expiration") else {
            tokenExpiresSoon = nil; return
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        guard let d = f.date(from: raw.replacingOccurrences(of: " UTC", with: " +0000")) else { return }
        tokenExpiresSoon = d.timeIntervalSinceNow < 30 * 86400 ? d : nil
    }

    /// GitHub-Markdown grob zu Klartext (Mitteilungen/Einstellungen zeigen kein Markdown).
    static func cleanNotes(_ md: String) -> String {
        md.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                var l = line.trimmingCharacters(in: .whitespaces)
                while l.hasPrefix("#") { l.removeFirst() }
                if l.hasPrefix("- ") || l.hasPrefix("* ") { l = "• " + l.dropFirst(2) }
                return l.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
            .joined(separator: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    private struct Fail: Error {
        let text: String
        init(_ text: String) { self.text = text }
    }
}

private final class StripAuthOnRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        var r = request
        if r.url?.host != "api.github.com" { r.setValue(nil, forHTTPHeaderField: "Authorization") }
        return r
    }
}
