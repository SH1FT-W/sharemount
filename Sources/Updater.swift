import AppKit

/// Updates aus den GitHub-Releases von SH1FT-W/sharemount.
/// Öffentliche Releases brauchen keinen Token. Ein Token (nur Lesen, siehe TokenStore) ist optional:
/// nur für ein privates Repo/einen privaten Fork oder wenn das GitHub-Limit ohne Anmeldung (60/Std.) erreicht ist.
/// Installiert wird nur, wenn Prüfsumme, Bundle-ID und Version stimmen und die Signatur gültig ist (ad-hoc, kein Zertifikat).
/// Die Schritte selbst (Laden, Prüfen, Tauschen) liegen in Shared/Sources/UpdateCore.swift; hier bleibt, was
/// ShareMount eigen ist: Token, Benutzerwechsel, Tausch mit Administrator-Rechten, Protokoll.
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
    static let appName = "ShareMount"
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

    private var userAgent: String { "ShareMount/\(AppInfo.version)" }

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
                self?.restartIfReplaced()
                guard Prefs.shared.autoCheckUpdates else { return }
                await self?.check(silent: true)
            }
        }
        showNotesAfterUpdate()
        // Mehrere Benutzer teilen sich /Applications/ShareMount.app. Hat ein anderer Benutzer aktualisiert,
        // liegt eine neue Version auf der Platte, während hier noch die alte läuft → selbst neu starten.
        // Geprüft wird beim Zurückwechseln in diese Sitzung (dann war der andere Benutzer gerade vorne) und
        // beim 6-Stunden-Check, nicht mehr alle 30 s per Info.plist und stat.
        Session.onReturn { [weak self] in self?.restartIfReplaced() }
    }

    private var replaced = false
    private let runningBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    private let runningStamp = Updater.executableStamp()

    /// Änderungsdatum des Programms – erkennt auch einen Neubau mit gleicher Build-Nummer (./build.sh install).
    private static func executableStamp() -> Date? {
        guard let path = Bundle.main.executableURL?.path else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    private func restartIfReplaced() {
        if replaced { return }
        if case .installing = state { return }
        let plist = Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist")
        // Fehlt die Datei kurz (Tausch läuft gerade), beim nächsten Mal.
        guard let info = NSDictionary(contentsOf: plist),
              let build = info["CFBundleVersion"] as? String,
              FileManager.default.isExecutableFile(atPath: Bundle.main.executableURL?.path ?? ""),
              let stamp = Self.executableStamp(),
              build != runningBuild || stamp != runningStamp else { return }
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        replaced = true
        Log.write(L("ShareMount v\(version) wurde installiert (z. B. von einem anderen Benutzer), starte neu",
                    "ShareMount \(version) was installed (e.g. by another user), restarting"))
        Prefs.shared.pendingNotes = (version, L("Von einem anderen Benutzer dieses Macs aktualisiert.", "Updated by another user on this Mac."))
        relaunch()
    }

    /// Wartet, bis dieser Prozess beendet ist, und öffnet die App neu (Mounts bleiben dabei bestehen).
    private func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-f", "-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; sleep 0.5; open \"$2\"", "relaunch",
                       "\(ProcessInfo.processInfo.processIdentifier)", Bundle.main.bundleURL.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        NSApp.terminate(nil)
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
            var (data, http) = try await UpdateCore.fetchLatestRelease(repo: Self.repo, userAgent: userAgent, token: used)
            // Abgelaufener/ungültiger Token: ein öffentliches Repo geht auch ohne – dann ohne weiter.
            if http?.statusCode == 401, used != nil {
                let retry = try await UpdateCore.fetchLatestRelease(repo: Self.repo, userAgent: userAgent, token: nil)
                if retry.1?.statusCode == 200 {
                    (data, http, used) = (retry.0, retry.1, nil)
                    Log.write(L("Update-Prüfung: GitHub-Token ungültig, ohne Token geprüft", "Update check: GitHub token invalid, checked without token"))
                }
            }
            noteTokenExpiry(http)
            switch http?.statusCode ?? 0 {
            case 200: break
            case 401: throw UpdateError(L("Token ungültig oder abgelaufen", "Token invalid or expired"))
            case 403, 429:
                throw UpdateError(used == nil ? L("GitHub-Limit erreicht, später erneut versuchen", "GitHub rate limit reached, try again later")
                                              : L("Kein Zugriff auf \(Self.repo), Token prüfen", "No access to \(Self.repo), check the token"))
            case 404: throw UpdateError(used == nil ? L("Kein Release gefunden", "No release found")
                                                   : L("Kein Release gefunden (oder Token ohne Zugriff)", "No release found (or the token has no access)"))
            case let c: throw UpdateError(L("GitHub antwortet mit \(c)", "GitHub responded with \(c)"))
            }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let found = try GitHubRelease(json: json)
            // API-Links der Assets (nicht browser_download_url): nur so geht ein Download mit Token
            guard let zip = found.apiURL("ShareMount.zip"), let sum = found.apiURL("ShareMount.zip.sha256") else {
                throw UpdateError(L("Release ohne ShareMount.zip/.sha256", "Release has no ShareMount.zip/.sha256"))
            }
            let tag = found.version
            let body = ReleaseNotes.cleanNotes(found.notes)
            if UpdateCore.isNewer(tag, than: AppInfo.version) {
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
            let msg = (error as? UpdateError)?.text ?? L("GitHub nicht erreichbar", "GitHub not reachable")
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
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShareMount-Update-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

            state = .installing(L("Lade v\(release.version) …", "Downloading v\(release.version)…"))
            let zipData = try await UpdateCore.download(release.zip, userAgent: userAgent, token: release.token)
            let sumText = String(decoding: try await UpdateCore.download(release.checksum, userAgent: userAgent, token: release.token), as: UTF8.self)

            state = .installing(L("Prüfe …", "Verifying…"))
            try UpdateCore.verifyChecksum(zipData, sha256Text: sumText)
            // Entpacken, Bundle-ID, Version, Code-Signatur (nicht im Menü-Thread); Quarantäne erst nach bestandener Prüfung weg
            let newApp = try await UpdateCore.unpackAndVerify(zip: zipData, in: work, appName: Self.appName,
                                                              bundleID: Bundle.main.bundleIdentifier ?? AppInfo.bundleID, version: release.version)

            Prefs.shared.pendingNotes = (release.version, release.notes)
            if Self.needsAdmin(Bundle.main.bundleURL) {
                // App gehört einem anderen Benutzer (z. B. dem, der sie installiert hat) → macOS fragt nach
                // einem Administrator-Passwort, getauscht wird sofort, danach nur neu starten.
                state = .installing(L("Warte auf Administrator-Passwort …", "Waiting for administrator password…"))
                do { try await adminSwap(newApp: newApp, work: work) }
                catch { Prefs.shared.pendingNotes = nil; throw error }
                state = .installing(L("Starte neu …", "Restarting…"))
                Log.write(L("Update auf v\(release.version) mit Administrator-Rechten installiert, starte neu", "Update to v\(release.version) installed with administrator rights, restarting"))
                try? FileManager.default.removeItem(at: work)
                relaunch()
                return
            }
            state = .installing(L("Starte neu …", "Restarting…"))
            try UpdateCore.launchSwapScript(target: Bundle.main.bundleURL, newApp: newApp, work: work, logFile: Log.url,
                                            failureMessage: L("Update: Ersetzen fehlgeschlagen, alte Version bleibt", "Update: replacing failed, keeping the old version"))
            Log.write(L("Update auf v\(release.version) geprüft, App wird ersetzt und neu gestartet", "Update to v\(release.version) verified, replacing and restarting the app"))
            NSApp.terminate(nil)
        } catch {
            try? FileManager.default.removeItem(at: work)   // Download und entpackte App nicht liegen lassen
            let msg = (error as? UpdateError)?.text ?? error.localizedDescription
            Log.write(L("Update fehlgeschlagen", "Update failed") + ": \(msg)", problem: true)
            state = .failed(L("Update fehlgeschlagen", "Update failed") + ": \(msg)")
        }
    }

    /// Ziel muss ersetzbar sein – sonst endet jeder Versuch in derselben Schleife (z. B. Start aus „Downloads“
    /// mit App-Translocation oder von einem schreibgeschützten Volume). Nicht beschreibbar (App gehört einem
    /// anderen Benutzer) geht mit Administrator-Passwort, deshalb ohne requireWritable.
    private static func targetProblem(_ app: URL) -> String? {
        UpdateCore.targetProblem(app, appName: appName, requireWritable: false)
    }

    /// Darf dieser Benutzer die App selbst ersetzen? Sonst (anderer Besitzer) per Administrator-Passwort.
    private static func needsAdmin(_ app: URL) -> Bool {
        let fm = FileManager.default
        return !fm.isWritableFile(atPath: app.deletingLastPathComponent().path) || !fm.isWritableFile(atPath: app.path)
    }

    /// Tausch mit Administrator-Rechten (macOS-Passwortdialog). Besitzer und Gruppe der alten App bleiben erhalten,
    /// damit der Benutzer, der sie installiert hat, weiter ohne Passwort aktualisieren kann.
    private func adminSwap(newApp: URL, work: URL) async throws {
        let script = work.appendingPathComponent("adminswap.sh")
        try """
        #!/bin/zsh -f
        TARGET="$1"; NEW="$2"; OLD="$1.alt"
        OWNER=$(stat -f %u:%g "$TARGET") || exit 1
        rm -rf "$OLD"
        if mv "$TARGET" "$OLD" && mv "$NEW" "$TARGET" && chown -R "$OWNER" "$TARGET"; then
            rm -rf "$OLD"
        else
            [[ -d "$OLD" && ! -d "$TARGET" ]] && mv "$OLD" "$TARGET"
            exit 1
        fi
        """.write(to: script, atomically: true, encoding: .utf8)
        let prompt = L("ShareMount möchte sich aktualisieren.", "ShareMount wants to install an update.")
        // Pfade als Argumente (argv), nie in den AppleScript-Text eingesetzt.
        let ok = await Shell.run("/usr/bin/osascript", [
            "-e", "on run argv",
            "-e", "do shell script \"/bin/zsh -f \" & quoted form of item 1 of argv & \" \" & quoted form of item 2 of argv & \" \" & quoted form of item 3 of argv with prompt item 4 of argv with administrator privileges",
            "-e", "end run",
            script.path, Bundle.main.bundleURL.path, newApp.path, prompt,
        ], timeout: 300)
        guard ok else {
            Log.write(L("Update: Administrator-Tausch abgebrochen oder fehlgeschlagen", "Update: administrator swap cancelled or failed"), problem: true)
            throw UpdateError(L("Kein Administrator-Passwort eingegeben oder Ersetzen fehlgeschlagen", "No administrator password entered, or replacing failed"))
        }
    }

    // MARK: Hilfen

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
}
