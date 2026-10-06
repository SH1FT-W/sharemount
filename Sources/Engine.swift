import AppKit
import Combine
import Network

/// Hält alle Freigaben verbunden: prüft beim Start, nach dem Aufwachen,
/// bei Netzwerkwechsel und regelmäßig (Standard: jede Minute).
@MainActor
final class Engine: ObservableObject {
    @Published private(set) var shares: [Share] = []
    @Published private(set) var status: [UUID: ShareStatus] = [:]
    @Published private(set) var usage: [UUID: Usage] = [:]
    @Published private(set) var connectedSince: [UUID: Date] = [:]
    @Published private(set) var events: [UUID: [ShareEvent]] = [:]
    @Published private(set) var isChecking = false
    @Published private(set) var lastCheck: Date?
    /// Erst verbinden, wenn WLAN oder LAN wirklich steht (beim Anmelden ist das Netz oft noch nicht da –
    /// sonst scheitert der erste Versuch und die Wartezeit wächst unnötig).
    @Published private(set) var networkReady = false
    /// Ein Ordner unter /Volumes, der root gehört und den sauberen Pfad blockiert (nur mit sudo zu löschen).
    @Published private(set) var blockedPaths: [UUID: String] = [:]
    /// Mount liegt auf „Name-1“, obwohl „Name“ frei ist → Hinweis mit „Pfad korrigieren“.
    @Published private(set) var misplaced: [UUID: String] = [:]
    /// Wo das Passwort je Freigabe liegt (gecacht – Schlüsselbund-Abfragen nicht bei jedem Rendern).
    @Published private(set) var credentialState: [UUID: Credentials] = [:]

    private var busy: Set<UUID> = []
    private var mountingHosts: Set<String> = []
    private var manuallyDisconnected: Set<UUID> = []
    /// Passwort abgelehnt → kein automatischer Neuversuch (NAS sperrt Konten sonst nach x Fehlversuchen).
    private var authFailed: Set<UUID> = []
    private var strikes: [UUID: (count: Int, since: Date)] = [:]
    private var retryAt: [UUID: (date: Date, delay: TimeInterval)] = [:]
    private var failCount: [UUID: Int] = [:]
    private var notified: Set<UUID> = []
    private var hostCache: [String: (date: Date, ok: Bool)] = [:]
    /// Nach Aufwachen/Netzwechsel stehen Server ein paar Sekunden lang nicht zur Verfügung.
    /// In dieser Zeit wird nichts gelöst – bis 1.7 riss genau das nach jedem Aufwachen alle Mounts ab.
    private var settleUntil = Date.distantPast
    private var pending: Task<Void, Never>?
    private var timer: Timer?
    private var configTimer: Timer?
    private var configStamp: Date?
    private let pathMonitor = NWPathMonitor()
    private var lastPath: String?
    private var subs: Set<AnyCancellable> = []

    #if SNAPSHOT
    /// Nur für tools/snapshot.swift: Beispiel-Freigaben zeigen, nichts prüfen, keine echten Mounts anzeigen.
    private(set) var frozen = false
    func preview(_ items: [(share: Share, status: ShareStatus, usage: Usage?, since: Date?)], checked: Date = Date()) {
        frozen = true
        pending?.cancel()
        networkReady = true
        shares = items.map(\.share)
        for i in items {
            status[i.share.id] = i.status
            usage[i.share.id] = i.usage
            connectedSince[i.share.id] = i.since
            credentialState[i.share.id] = .system
        }
        lastCheck = checked
    }
    #else
    private let frozen = false
    #endif

    init() {
        Log.rotate()
        Store.migrateIfNeeded()
        shares = Store.load()
        configStamp = Store.modificationDate()
        Log.write(L("Start v\(AppInfo.version): \(shares.count) Freigabe(n)", "Launch v\(AppInfo.version): \(shares.count) share(s)"))
        refreshCredentials()

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                Log.write(L("Aufgewacht", "Woke from sleep"))
                self.settle(25)
                self.retryAt.removeAll()
                self.schedule(after: 5)
            }
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            // Nur echte Wechsel zählen (Schnittstelle, Gateway, online/offline) –
            // macOS meldet sonst auch Kleinkram und beim Start gleich mehrfach.
            var seen = Set<String>()
            let ifaces = path.availableInterfaces.map(\.name).filter { seen.insert($0).inserted }.joined(separator: ", ")
            let gws = path.gateways.map { "\($0)" }.sorted().joined(separator: ",")
            let sig = "\(path.status)|\(ifaces)|\(gws)"
            let ready = path.status == .satisfied
                && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
            Task { @MainActor in
                guard let self, !self.frozen, sig != self.lastPath else { return }
                let first = self.lastPath == nil
                self.lastPath = sig
                self.hostCache.removeAll()
                let wasReady = self.networkReady
                self.networkReady = ready
                if ready && !wasReady {
                    Log.write(first ? L("Netzwerk bereit (\(ifaces))", "Network ready (\(ifaces))") : L("Netzwerk wieder da (\(ifaces))", "Network back (\(ifaces))"))
                    if !first { self.settle(15) }
                    self.retryAt.removeAll()
                    self.schedule(after: 2)      // DHCP/DNS kurz setzen lassen
                    return
                }
                if !ready {
                    if wasReady || first { Log.write(L("Warte auf WLAN/LAN …", "Waiting for Wi-Fi or Ethernet…")) }
                    for s in self.shares where !(self.status[s.id]?.isMounted ?? false) {
                        self.status[s.id] = .waitingForNetwork
                    }
                    return
                }
                if first { return }
                Log.write(L("Netzwerk gewechselt (online über \(ifaces))", "Network changed (online via \(ifaces))"))
                self.settle(15)
                self.retryAt.removeAll()
                self.schedule(after: 3)
            }
        }
        pathMonitor.start(queue: .global())

        Prefs.shared.$interval.removeDuplicates().sink { [weak self] secs in
            Task { @MainActor in self?.startTimer(secs) }
        }.store(in: &subs)
        // Änderungen vom anderen Mac (über iCloud Drive) alle 10 s aufgreifen.
        configTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reloadConfigIfChanged() }
        }
        // Kein Sofort-Versuch: der erste Durchlauf kommt, sobald der Netzwerk-Monitor „bereit“ meldet.
        // Sicherheitsnetz, falls der Monitor nie meldet: nach 45 s trotzdem prüfen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in
            guard let self, !self.networkReady, self.lastPath == nil else { return }
            Log.write(L("Netzwerk-Monitor ohne Meldung, prüfe trotzdem", "No word from the network monitor, checking anyway"))
            self.networkReady = true
            self.schedule(after: 0)
        }
    }

    private func startTimer(_ secs: Double) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: max(15, secs), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.schedule(after: 0) }
        }
        timer?.tolerance = 5
    }

    private func settle(_ seconds: TimeInterval) {
        settleUntil = max(settleUntil, Date().addingTimeInterval(seconds))
        strikes.removeAll()
        hostCache.removeAll()
    }

    private var settling: Bool { Date() < settleUntil }

    private func reloadConfigIfChanged() {
        if frozen { return }
        Store.migrateIfNeeded()
        let stamp = Store.modificationDate()
        guard stamp != configStamp else { return }
        guard let new = Store.loadIfValid() else { return }   // halb geschrieben → beim nächsten Mal
        configStamp = stamp
        guard new != shares else { return }
        let gone = Set(shares.map(\.id)).subtracting(new.map(\.id))
        for id in gone { forget(id) }
        shares = new
        refreshCredentials()
        Log.write(L("Einstellungen von anderem Mac übernommen: \(new.count) Freigabe(n)", "Settings taken over from another Mac: \(new.count) share(s)"))
        schedule(after: 1)
    }

    private func persist() {
        Store.save(shares)
        configStamp = Store.modificationDate()
    }

    private func forget(_ id: UUID) {
        status[id] = nil; usage[id] = nil; connectedSince[id] = nil; events[id] = nil
        strikes[id] = nil; retryAt[id] = nil; failCount[id] = nil; blockedPaths[id] = nil; misplaced[id] = nil
        credentialState[id] = nil
        authFailed.remove(id); manuallyDisconnected.remove(id); notified.remove(id)
    }

    // MARK: Zusammenfassung

    var hasProblem: Bool { shares.contains { status[$0.id]?.isProblem ?? false } }

    var connectedCount: Int { shares.filter { status[$0.id]?.isMounted ?? false }.count }

    var summary: String {
        if shares.isEmpty { return L("Keine Freigaben eingerichtet", "No shares set up") }
        let problems = shares.filter { status[$0.id]?.isProblem ?? false }
        if problems.count == 1 { return L("Problem: \(problems[0].displayName)", "Problem: \(problems[0].displayName)") }
        if problems.count > 1 { return L("Probleme bei \(problems.count) Freigaben", "Problems with \(problems.count) shares") }
        if !networkReady { return L("Warte auf WLAN/LAN …", "Waiting for Wi-Fi or Ethernet…") }
        let n = connectedCount
        let active = shares.filter(\.enabled).count
        if n == shares.count { return n == 1 ? L("Verbunden", "Connected") : L("Alle \(n) verbunden", "All \(n) connected") }
        if n == active && n > 0 { return L("\(n) verbunden", "\(n) connected") }
        return L("\(n) von \(shares.count) verbunden", "\(n) of \(shares.count) connected")
    }

    // MARK: Verlauf

    private func record(_ s: Share, _ text: String, problem: Bool = false) {
        Log.write("\(s.displayName): \(text)")
        var list = events[s.id] ?? []
        list.insert(ShareEvent(date: Date(), text: text, problem: problem), at: 0)
        events[s.id] = Array(list.prefix(15))
    }

    private func setMounted(_ s: Share, _ path: String) {
        if !(status[s.id]?.isMounted ?? false) || connectedSince[s.id] == nil { connectedSince[s.id] = Date() }
        status[s.id] = .mounted(path)
        retryAt[s.id] = nil
        failCount[s.id] = 0
        strikes[s.id] = nil
        authFailed.remove(s.id)
        if notified.remove(s.id) != nil {
            Notifier.clear(s.id.uuidString)
            if Prefs.shared.notifyRecovery {
                Notifier.send(s.id.uuidString + ".ok", title: L("„\(s.displayName)“ wieder verbunden", "“\(s.displayName)” reconnected"), body: s.address)
            }
        }
    }

    private func setNotMounted(_ s: Share, _ st: ShareStatus) {
        status[s.id] = st
        usage[s.id] = nil
        connectedSince[s.id] = nil
    }

    private func problemNotice(_ s: Share, _ body: String) {
        guard !settling, networkReady else { return }
        notified.insert(s.id)
        Notifier.send(s.id.uuidString, title: L("ShareMount: „\(s.displayName)“", "ShareMount: “\(s.displayName)”"), body: body)
    }

    // MARK: Prüfen

    /// Entprellt: mehrere Auslöser kurz hintereinander → ein Durchlauf.
    func schedule(after seconds: Double) {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await checkAll()
        }
    }

    private func recheck(_ s: Share, after seconds: Double) {
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            await check(s)
        }
    }

    /// Mehrere Freigaben auf demselben Server teilen sich eine Erreichbarkeits-Prüfung (5 s gültig).
    private func hostReachable(_ host: String) async -> Bool {
        let key = host.lowercased()
        if let c = hostCache[key], Date().timeIntervalSince(c.date) < 5 { return c.ok }
        let ok = await Mounter.reachable(host)
        hostCache[key] = (Date(), ok)
        return ok
    }

    func checkAll(force: Bool = false) async {
        if frozen { return }
        guard networkReady else {
            for s in shares where !(status[s.id]?.isMounted ?? false) { status[s.id] = .waitingForNetwork }
            return
        }
        isChecking = true
        await withTaskGroup(of: Void.self) { group in
            for s in shares { group.addTask { await self.check(s, force: force) } }
        }
        isChecking = false
        lastCheck = Date()
    }

    private func check(_ s: Share, force: Bool = false) async {
        if frozen { return }
        guard !busy.contains(s.id) else { return }
        busy.insert(s.id)
        defer { busy.remove(s.id) }
        // Freigabe inzwischen entfernt oder geändert (anderer Mac, Einstellungen)?
        guard let s = shares.first(where: { $0.id == s.id }) else { return }

        // 1. Schon gemountet? Dann schauen, ob er noch lebt.
        //    Server (TCP 445) UND Mount (Verzeichnis lesen) werden geprüft. Antwortet nur der Server nicht,
        //    der Mount aber schon, kann das auch an der Prüfung selbst liegen (Lokales-Netzwerk-Recht,
        //    VPN) – dann wird erst nach 3 Fehlschlägen über ≥ 90 s gelöst, sonst nach 2 über ≥ 20 s.
        //    Nie direkt nach Aufwachen/Netzwechsel und nie bei „Automatik aus“.
        if let m = Mounter.find(s) {
            let reachable = await hostReachable(s.host)
            let probe = await Mounter.check(m.path)
            if reachable, let u = probe.usage {
                usage[s.id] = u
                setMounted(s, m.path)
                noteBlockedPath(s, m.path)
                return
            }
            if !networkReady { return }                       // Netz-zurück plant ohnehin neu
            if settling || probe == .stillHanging {
                recheck(s, after: 10)
                return
            }
            if !s.enabled {
                if let u = probe.usage { usage[s.id] = u; setMounted(s, m.path) } else { setNotMounted(s, .disabled) }
                return
            }
            let now = Date()
            let st = strikes[s.id].map { ($0.count + 1, $0.since) } ?? (1, now)
            strikes[s.id] = st
            let cacheOnly = probe.usage != nil                // Server stumm, Mount liest (evtl. nur Cache)
            let (need, span): (Int, TimeInterval) = cacheOnly ? (3, 90) : (2, 20)
            if st.0 < need || now.timeIntervalSince(st.1) < span {
                if let u = probe.usage { usage[s.id] = u; setMounted(s, m.path) } else { status[s.id] = .stale }
                recheck(s, after: cacheOnly ? 35 : 12)        // zeitnah nachprüfen statt erst beim nächsten Durchlauf
                return
            }
            record(s, reachable ? L("Mount reagiert nicht, wird gelöst", "Mount not responding, unmounting")
                                 : L("Server weg, Mount wird gelöst", "Server gone, unmounting"), problem: true)
            if !(await Mounter.unmount(m.path, force: true)) { Log.write("\(s.displayName): " + L("Lösen fehlgeschlagen", "unmount failed")) }
            await Mounter.waitUntilFree(m.path)
            strikes[s.id] = nil
            setNotMounted(s, .checking)
            if reachable { problemNotice(s, L("Die Verbindung hing und wurde neu aufgebaut.", "The connection hung and was set up again.")) }
            if !reachable {
                setUnreachable(s)
                return
            }
        }

        // 2. Nicht gemountet – sollen wir?
        if !s.enabled { setNotMounted(s, .disabled); return }
        if manuallyDisconnected.contains(s.id) && !force { setNotMounted(s, .disconnected); return }
        if authFailed.contains(s.id) && !force { setNotMounted(s, .authFailed); return }
        if !force, let r = retryAt[s.id], r.date > Date() { return }

        guard await hostReachable(s.host) else {
            setUnreachable(s)
            return
        }
        if status[s.id] == .unreachable { record(s, L("Server wieder erreichbar", "Server reachable again")) }

        // 3. Einbinden – pro Server nacheinander. Mehrere gleichzeitige Mounts auf dieselbe NAS
        //    ließen NetAuth hängen und erzeugten Doppel-Mounts („Name-1“).
        status[s.id] = .mounting
        await lockHost(s.host)
        defer { unlockHost(s.host) }
        if let m = Mounter.find(s) {       // inzwischen anderweitig verbunden (Finder, 2. Durchlauf)
            if let u = await Mounter.probe(m.path) { usage[s.id] = u; setMounted(s, m.path) }
            else { status[s.id] = .stale }
            return
        }
        await Mounter.waitUntilFree(s.cleanMountPath, timeout: 3)
        Mounter.clearLeftover(s.cleanMountPath)
        let (result, pw) = await mountWithStoredCredentials(s)
        switch result {
        case .success(var path):
            // Während des Mounts „Trennen“ geklickt → gleich wieder lösen.
            if manuallyDisconnected.contains(s.id) && !force {
                _ = await Mounter.unmount(path, force: false)
                setNotMounted(s, .disconnected)
                return
            }
            path = await fixFreshMountPath(s, path)
            record(s, L("verbunden → \(path)", "connected → \(path)"))
            usage[s.id] = await Mounter.probe(path)
            setMounted(s, path)
            noteBlockedPath(s, path)
        case .failure(let err) where err.isAuth:
            authFailed.insert(s.id)
            retryAt[s.id] = nil
            record(s, pw ? L("Anmeldung abgelehnt, keine automatischen Versuche mehr bis zur neuen Anmeldung",
                           "Login rejected, no more automatic attempts until you sign in again")
                         : L("Anmeldung abgelehnt, kein Passwort im Schlüsselbund", "Login rejected, no password in the keychain"), problem: true)
            setNotMounted(s, .authFailed)
            problemNotice(s, pw ? L("Der Server hat Benutzer oder Passwort abgelehnt. Im Menü „Anmelden …“ wählen.",
                                  "The server rejected the user name or password. Choose “Sign In…” in the menu.")
                                : L("Kein Passwort im Schlüsselbund. Im Menü „Anmelden …“ wählen.",
                                    "No password in the keychain. Choose “Sign In…” in the menu."))
        case .failure(let err):
            // Wartezeit verdoppelt sich: 30 s, 1 min, 2 min … max. 15 min
            let delay = min((retryAt[s.id]?.delay ?? 15) * 2, 900)
            retryAt[s.id] = (Date().addingTimeInterval(delay), delay)
            let n = (failCount[s.id] ?? 0) + 1
            failCount[s.id] = n
            record(s, "\(err.text), " + L("nächster Versuch in \(Self.duration(delay))", "next attempt in \(Self.duration(delay))"), problem: true)
            setNotMounted(s, .failed(err.text))
            if n == 3 { problemNotice(s, L("Verbinden klappt nicht: \(err.text). ShareMount versucht es weiter.", "Can’t connect: \(err.text). ShareMount keeps trying.")) }
        }
    }

    private func lockHost(_ host: String) async {
        let key = Share.normalizeHost(host).lowercased()
        while mountingHosts.contains(key) { try? await Task.sleep(nanoseconds: 300_000_000) }
        mountingHosts.insert(key)
    }

    private func unlockHost(_ host: String) {
        mountingHosts.remove(Share.normalizeHost(host).lowercased())
    }

    /// Nur beim Wechsel protokollieren, nicht bei jeder Prüfung erneut.
    private func setUnreachable(_ s: Share) {
        if status[s.id] != .unreachable { record(s, L("Server \(s.host) nicht erreichbar", "Server \(s.host) not reachable")) }
        setNotMounted(s, .unreachable)
    }

    /// Frischer Mount landete auf „Name-1“, obwohl „Name“ inzwischen frei ist (alter Mount war noch nicht ganz weg)?
    /// Direkt nach dem eigenen Mount hat noch niemand etwas geöffnet → sofort sauber neu einbinden.
    /// Skripte und Backups, die mit /Volumes/Name arbeiten, finden die Freigabe sonst nicht.
    private func fixFreshMountPath(_ s: Share, _ path: String) async -> String {
        let clean = s.cleanMountPath
        guard path != clean else { return path }
        await Mounter.waitUntilFree(clean, timeout: 4)
        guard !Mounter.isMountPoint(clean), Mounter.clearLeftover(clean) else { return path }
        guard await Mounter.unmount(path, force: false) else { return path }
        await Mounter.waitUntilFree(path)
        if case .success(let p) = await mountWithStoredCredentials(s).0 {
            Log.write("\(s.displayName): " + L("Pfad korrigiert \(path) → \(p)", "path fixed \(path) → \(p)"))
            return p
        }
        return Mounter.find(s)?.path ?? path
    }

    /// Bestehender Mount auf „Name-1“ (z. B. von 1.7 oder vom Finder) – nur auf ausdrücklichen Klick neu einbinden,
    /// denn offene Dokumente (Vorschau, Office) verlören dabei ihren Pfad.
    func fixMountPath(_ s: Share) {
        guard let m = Mounter.find(s), m.path != s.cleanMountPath, !busy.contains(s.id) else { return }
        busy.insert(s.id)
        Task {
            defer { busy.remove(s.id) }
            await lockHost(s.host)
            defer { unlockHost(s.host) }
            guard await Mounter.unmount(m.path, force: false) else {
                record(s, L("Pfad-Korrektur: Freigabe ist in Benutzung, erst Dateien schließen", "Fix path: share is in use, close files first"), problem: true)
                return
            }
            await Mounter.waitUntilFree(m.path)
            _ = Mounter.clearLeftover(s.cleanMountPath)
            switch await mountWithStoredCredentials(s).0 {
            case .success(let p):
                record(s, L("Pfad korrigiert: \(m.path) → \(p)", "Path fixed: \(m.path) → \(p)"))
                usage[s.id] = await Mounter.probe(p)
                setMounted(s, p)
                noteBlockedPath(s, p)
            case .failure(let e):
                record(s, L("Pfad-Korrektur", "Fix path") + ": \(e.text)", problem: true)
                setNotMounted(s, .checking)
                recheck(s, after: 2)
            }
        }
    }

    private func noteBlockedPath(_ s: Share, _ path: String) {
        let clean = s.cleanMountPath
        misplaced[s.id] = path != clean && !FileManager.default.fileExists(atPath: clean) ? path : nil
        if path != clean, FileManager.default.fileExists(atPath: clean), !Mounter.isMountPoint(clean) {
            if blockedPaths[s.id] != clean {
                Log.write("\(s.displayName): " + L("\(clean) ist ein verwaister Ordner (nur mit sudo rmdir zu entfernen)",
                                                          "\(clean) is an orphaned folder (can only be removed with sudo rmdir)"))
            }
            blockedPaths[s.id] = clean
        } else {
            blockedPaths[s.id] = nil
        }
    }

    /// Ohne Passwort: macOS (NetAuth) nimmt das im Schlüsselbund gesicherte Finder-Passwort.
    /// ShareMount liest es nie selbst, also keine Nachfragen nach Updates.
    /// Zweiter Wert: ob überhaupt ein Passwort vorhanden war.
    private func mountWithStoredCredentials(_ s: Share) async -> (Result<String, MountError>, Bool) {
        let system = Keychain.hasSystemPassword(user: s.user, host: s.host)
        return (await Mounter.mount(s, password: nil), system)
    }

    /// Wo liegt das Passwort für diese Freigabe?
    enum Credentials { case system, none }

    /// Nur Metadaten-Abfragen – löst nie eine Schlüsselbund-Nachfrage aus. Ergebnis gecacht für die Oberfläche.
    func refreshCredentials() {
        var map: [UUID: Credentials] = [:]
        for s in shares {
            map[s.id] = Keychain.hasSystemPassword(user: s.user, host: s.host) ? .system : Credentials.none
        }
        credentialState = map
    }

    func credentials(for s: Share) -> Credentials { credentialState[s.id] ?? .none }

    /// macOS-Anmeldedialog zeigen („Im Schlüsselbund sichern“ anhaken) – danach verbindet ShareMount
    /// für immer ohne eigene Passwörter. Ist die Freigabe verbunden, wird sie dafür kurz getrennt.
    @Published private(set) var signingIn: UUID?
    func signIn(_ s: Share) {
        guard signingIn == nil else { return }
        signingIn = s.id
        manuallyDisconnected.remove(s.id)
        Task {
            defer { signingIn = nil }
            // Laufende Prüfung abwarten, dann selbst Freigabe und Server sperren (sonst parallele Mounts).
            while busy.contains(s.id) { try? await Task.sleep(nanoseconds: 200_000_000) }
            busy.insert(s.id)
            defer { busy.remove(s.id) }
            await lockHost(s.host)
            defer { unlockHost(s.host) }
            for m in Mounter.current() where s.matches(host: m.host, share: m.share) {
                guard await Mounter.unmount(m.path, force: false) else {
                    record(s, L("Anmelden: Freigabe ist in Benutzung, erst Dateien schließen", "Sign in: share is in use, close files first"), problem: true)
                    return
                }
                await Mounter.waitUntilFree(m.path)
            }
            _ = Mounter.clearLeftover(s.cleanMountPath)
            setNotMounted(s, .mounting)
            NSApp.activate(ignoringOtherApps: true)
            let result = await Mounter.mount(s, password: nil, ui: true)
            refreshCredentials()
            switch result {
            case .success(let path):
                record(s, L("angemeldet → \(path)", "signed in → \(path)"))
                authFailed.remove(s.id)
                usage[s.id] = await Mounter.probe(path)
                setMounted(s, path)
                noteBlockedPath(s, path)
                if credentials(for: s) == .system { Log.write("\(s.displayName): " + L("Passwort liegt im Schlüsselbund von macOS", "password is in the macOS keychain")) }
            case .failure(let e):
                record(s, L("Anmelden", "Sign in") + ": \(e.text)", problem: !e.isCancel)
                if e.isAuth { authFailed.insert(s.id); setNotMounted(s, .authFailed) }
                else { setNotMounted(s, .checking); recheck(s, after: 1) }
            }
        }
    }

    static func duration(_ secs: TimeInterval) -> String {
        secs < 90 ? "\(Int(secs)) s" : "\(Int(secs / 60)) min"
    }

    // MARK: Aktionen aus dem Menü

    func connect(_ s: Share) {
        manuallyDisconnected.remove(s.id)
        authFailed.remove(s.id)
        retryAt[s.id] = nil
        hostCache[s.host.lowercased()] = nil
        Task { await check(s, force: true) }
    }

    func disconnect(_ s: Share) {
        manuallyDisconnected.insert(s.id)
        Task {
            var stuck: String?
            for m in Mounter.current() where s.matches(host: m.host, share: m.share) {
                if !(await Mounter.unmount(m.path, force: false)), !(await Mounter.unmount(m.path, force: true)) {
                    stuck = m.path
                }
            }
            if let stuck {
                // Nicht „getrennt“ anzeigen, solange macOS den Mount noch festhält.
                record(s, L("Trennen fehlgeschlagen, \(stuck) ist noch in Benutzung", "Disconnect failed, \(stuck) is still in use"), problem: true)
                manuallyDisconnected.remove(s.id)
                return
            }
            record(s, L("manuell getrennt", "disconnected manually"))
            setNotMounted(s, .disconnected)
        }
    }

    func reconnectAll() {
        manuallyDisconnected.removeAll()
        authFailed.removeAll()
        retryAt.removeAll()
        hostCache.removeAll()
        Task { await checkAll(force: true) }
    }

    func disconnectAll() {
        for s in shares where status[s.id]?.isMounted ?? false { disconnect(s) }
    }

    func open(_ s: Share) {
        if case .mounted(let p) = status[s.id] {
            NSWorkspace.shared.open(URL(fileURLWithPath: p))
        } else {
            connect(s)
        }
    }

    func path(of s: Share) -> String? {
        if case .mounted(let p) = status[s.id] { return p }
        return nil
    }

    // MARK: Einstellungen

    func save(_ s: Share) {
        if let i = shares.firstIndex(where: { $0.id == s.id }) {
            let old = shares[i]
            shares[i] = s
            // Server oder Freigabe geändert: der alte Mount gehört zu keiner Freigabe mehr → sanft lösen
            // (bleibt er in Benutzung, taucht er unter „Weitere SMB-Freigaben“ auf).
            if !old.matches(host: s.host, share: s.share), let m = Mounter.find(old) {
                status[s.id] = nil; usage[s.id] = nil; connectedSince[s.id] = nil
                misplaced[s.id] = nil; blockedPaths[s.id] = nil
                Task {
                    if await Mounter.unmount(m.path, force: false) {
                        Log.write("\(old.displayName): " + L("alte Adresse getrennt (\(m.path))", "old address disconnected (\(m.path))"))
                    }
                }
            }
        } else {
            shares.append(s)
        }
        persist()
        refreshCredentials()
        authFailed.remove(s.id)
        retryAt[s.id] = nil
        Task { await check(s, force: true) }
    }

    func remove(_ s: Share, unmount: Bool) {
        shares.removeAll { $0.id == s.id }
        forget(s.id)
        persist()
        if unmount, let m = Mounter.find(s) {
            Task { _ = await Mounter.unmount(m.path, force: false) }
        }
        Log.write("\(s.displayName): " + L("entfernt", "removed"))
    }

    func move(from source: IndexSet, to destination: Int) {
        shares.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    /// Eine einzelne fremde Freigabe übernehmen (Menü „Weitere SMB-Freigaben“).
    func adopt(_ m: MountInfo) {
        guard !shares.contains(where: { $0.matches(host: m.host, share: m.share) }) else { return }
        shares.append(Share(host: m.host, share: m.share, user: m.user.isEmpty ? NSUserName() : m.user))
        persist()
        refreshCredentials()
        schedule(after: 0)
    }

    /// Übernimmt Freigaben, die gerade (z. B. per Finder) eingebunden sind.
    func importCurrentMounts() -> Int {
        var added = 0
        for m in Mounter.current() where !shares.contains(where: { $0.matches(host: m.host, share: m.share) }) {
            shares.append(Share(host: m.host, share: m.share, user: m.user.isEmpty ? NSUserName() : m.user))
            added += 1
        }
        if added > 0 { persist(); refreshCredentials() }
        schedule(after: 0)
        return added
    }

    /// Eingebundene SMB-Freigaben, die ShareMount (noch) nicht kennt.
    var foreignMounts: [MountInfo] {
        if frozen { return [] }
        return Mounter.current().filter { m in !shares.contains { $0.matches(host: m.host, share: m.share) } }
    }
}
