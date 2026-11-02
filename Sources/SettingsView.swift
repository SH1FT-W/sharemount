import SwiftUI
import ServiceManagement

// MARK: - Einstellungsfenster: Freigaben · Allgemein · Updates · Protokoll

struct SettingsView: View {
    @EnvironmentObject var router: Router

    var body: some View {
        TabView(selection: $router.tab) {
            SharesTab().tabItem { Label(Router.Tab.shares.title, systemImage: Router.Tab.shares.icon) }.tag(Router.Tab.shares)
            GeneralTab().tabItem { Label(Router.Tab.general.title, systemImage: Router.Tab.general.icon) }.tag(Router.Tab.general)
            UpdatesTab().tabItem { Label(Router.Tab.updates.title, systemImage: Router.Tab.updates.icon) }.tag(Router.Tab.updates)
            LogTab().tabItem { Label(Router.Tab.log.title, systemImage: Router.Tab.log.icon) }.tag(Router.Tab.log)
        }
        .frame(width: 600, height: 470)
    }
}

// MARK: Freigaben

struct SharesTab: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var router: Router
    @State private var info = ""
    @State private var removing: Share?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            List {
                if engine.shares.isEmpty {
                    Text(L("Noch keine Freigaben. „Hinzufügen“ oder eine im Finder verbundene übernehmen.", "No shares yet. Click “Add” or import one that is connected in the Finder."))
                        .foregroundStyle(.secondary).padding(.vertical, 8)
                }
                ForEach(engine.shares) { s in row(s) }
                    .onMove { engine.move(from: $0, to: $1) }
            }
            .listStyle(.inset(alternatesRowBackgrounds: false))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack {
                Button { router.editing = Share(host: "", share: "", user: NSUserName()) } label: {
                    Label(L("Hinzufügen", "Add"), systemImage: "plus")
                }
                Button(L("Verbundene übernehmen", "Import Connected")) {
                    let n = engine.importCurrentMounts()
                    info = n == 0 ? L("Keine neuen SMB-Freigaben eingebunden.", "No new SMB shares are connected.") : L("\(n) übernommen.", "\(n) added.")
                }
                .help(L("Freigaben übernehmen, die gerade per Finder eingebunden sind", "Add shares that are currently connected in the Finder"))
                Spacer()
                Button(L("Konfig im Finder", "Show Config in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([Store.file]) }
            }
            if !info.isEmpty { Text(info).font(.caption).foregroundStyle(.secondary) }

            Label(Store.isSynced
                  ? L("Freigaben werden über iCloud Drive › Software › ShareMount mit deinen anderen Macs abgeglichen. Passwörter liegen im Schlüsselbund von macOS (wie beim Finder) und gelten nur auf diesem Mac.",
                      "Shares sync with your other Macs via iCloud Drive › Software › ShareMount. Passwords stay in the macOS keychain (just like with the Finder) and only apply to this Mac.")
                  : L("Freigaben liegen nur auf diesem Mac (iCloud Drive ist aus).", "Shares are stored on this Mac only (iCloud Drive is off)."),
                  systemImage: Store.isSynced ? "icloud" : "internaldrive")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .sheet(item: $router.editing) { s in
            ShareEditor(share: s, isNew: !engine.shares.contains { $0.id == s.id },
                        others: engine.shares.filter { $0.id != s.id },
                        detectRouters: { await engine.detectCurrentRouters() }) { edited in
                engine.save(edited, shownWakeMAC: .some(ShareEditor.prefilledWakeMAC(s, others: engine.shares.filter { $0.id != s.id })))
                router.editing = nil
            } onCancel: { router.editing = nil }
        }
        .confirmationDialog(L("„\(removing?.displayName ?? "")“ entfernen?", "Remove “\(removing?.displayName ?? "")”?"), isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { s in
            Button(L("Entfernen und trennen", "Remove and Disconnect"), role: .destructive) { engine.remove(s, unmount: true) }
            Button(L("Nur entfernen (bleibt verbunden)", "Remove Only (Stay Connected)")) { engine.remove(s, unmount: false) }
        } message: { _ in
            Text(L("Die Freigabe verschwindet auf allen Macs. Das Passwort im Schlüsselbund von macOS bleibt erhalten.", "The share is removed on all your Macs. The password stays in the macOS keychain."))
        }
    }

    private func row(_ s: Share) -> some View {
        let st = engine.status[s.id] ?? .checking
        let cred = engine.credentials(for: s)
        return HStack(spacing: 10) {
            Circle().fill(st.isMounted ? Color.accentColor : st.isProblem ? st.color : Color.secondary.opacity(0.4))
                .frame(width: 9, height: 9).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(s.displayName).fontWeight(.medium)
                    if !s.enabled { Text(L("Automatik aus", "Auto-connect off")).font(.caption2).foregroundStyle(.secondary) }
                }
                Text(s.address).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                switch cred {
                case .system: EmptyView()
                case .none:
                    Label(L("Kein Passwort im Schlüsselbund: „Anmelden“", "No password in the keychain: “Sign In”"), systemImage: "key")
                        .font(.caption).foregroundStyle(.orange)
                }
                if st.isProblem || st == .away { Text(st.text).font(.caption).foregroundStyle(st.isProblem ? st.color : Color.secondary) }
            }
            Spacer()
            if cred != .system || st == .authFailed {
                Button(L("Anmelden …", "Sign In…")) { engine.signIn(s) }.disabled(engine.signingIn != nil)
            }
            Button(L("Bearbeiten", "Edit")) { router.editing = s }
            Button(role: .destructive) { removing = s } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help(L("Entfernen", "Remove"))
                .accessibilityLabel(L("Entfernen", "Remove"))
        }
        .padding(.vertical, 4)
    }
}

// MARK: Editor

struct ShareEditor: View {
    @State var share: Share
    let isNew: Bool
    let others: [Share]
    var onSave: (Share) -> Void
    var onCancel: () -> Void
    @StateObject private var browser = ServerBrowser()
    @State private var test: String?
    @State private var testing = false
    @State private var resolving = false
    @State private var limitNetworks: Bool
    @State private var networkInfo: String?
    @State private var detecting = false
    var detectRouters: () async -> Set<String>

    init(share: Share, isNew: Bool, others: [Share] = [], detectRouters: @escaping () async -> Set<String> = { [] },
         onSave: @escaping (Share) -> Void, onCancel: @escaping () -> Void) {
        var share = share
        share.wakeMAC = Self.prefilledWakeMAC(share, others: others)
        _share = State(initialValue: share)
        _limitNetworks = State(initialValue: !share.networks.isEmpty)
        self.isNew = isNew
        self.others = others
        self.detectRouters = detectRouters
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? L("Neue Freigabe", "New Share") : share.displayName).font(.headline)
            Form {
                HStack {
                    TextField(L("Server", "Server"), text: $share.host, prompt: Text(L("192.168.1.10 oder nas.local", "192.168.1.10 or nas.local")))
                        .onChange(of: share.host) { _, v in splitAddress(v) }
                    Menu {
                        if browser.servers.isEmpty { Text(L("Suche im Netzwerk …", "Searching the network…")) }
                        ForEach(browser.servers) { srv in
                            Button(srv.name) { pick(srv) }
                        }
                    } label: { Image(systemName: resolving ? "ellipsis" : "magnifyingglass") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help(L("SMB-Server im Netzwerk", "SMB servers on the network"))
                    .accessibilityLabel(L("SMB-Server im Netzwerk", "SMB servers on the network"))
                }
                TextField(L("Freigabe", "Share"), text: $share.share, prompt: Text("Media"))
                TextField(L("Benutzer", "User"), text: $share.user)
                TextField(L("Anzeigename", "Display Name"), text: Binding(get: { share.name ?? "" }, set: { share.name = $0 }),
                          prompt: Text(share.share.isEmpty ? L("optional", "optional") : share.share))
                Toggle(L("Automatisch verbinden", "Connect automatically"), isOn: $share.enabled)
                TextField(L("Wake on LAN", "Wake on LAN"), text: Binding(get: { share.wakeMAC ?? "" }, set: { share.wakeMAC = $0 }),
                          prompt: Text(L("MAC-Adresse des Servers, optional", "Server MAC address, optional")))
                    .help(L("Antwortet der Server nicht, weckt ShareMount ihn vor dem Verbinden und wartet bis zu \(Int(Engine.wakeTimeout)) s. Gilt für alle Freigaben auf diesem Server.",
                            "If the server does not answer, ShareMount wakes it before connecting and waits up to \(Int(Engine.wakeTimeout)) s. Applies to all shares on this server."))
                Toggle(L("Nur in bestimmten Netzen", "Only on certain networks"), isOn: $limitNetworks)
                    .onChange(of: limitNetworks) { _, on in if on && share.networks.isEmpty { Task { await addCurrentNetwork() } } }
                if limitNetworks {
                    // Not ForEach($share.networks): removing a row from inside a binding-based ForEach can crash.
                    ForEach(share.networks) { n in
                        LabeledContent {
                            HStack(spacing: 6) {
                                TextField("", text: Binding(get: { share.networks.first { $0.router == n.router }?.name ?? "" }, set: { v in
                                    if let i = share.networks.firstIndex(where: { $0.router == n.router }) { share.networks[i].name = v }
                                })).labelsHidden()
                                Text(n.router).font(.caption.monospaced()).foregroundStyle(.secondary)
                                Button { share.networks.removeAll { $0.router == n.router } } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless)
                                    .help(L("Netz entfernen", "Remove network")).accessibilityLabel(L("Netz entfernen", "Remove network"))
                            }
                        } label: { Text(L("Netz", "Network")) }
                    }
                    LabeledContent {
                        HStack(spacing: 8) {
                            Button(detecting ? L("Suche Router …", "Looking for the router…") : L("Aktuelles Netz hinzufügen", "Add Current Network")) {
                                Task { await addCurrentNetwork() }
                            }.disabled(detecting)
                            if !knownNetworks.isEmpty {
                                Menu(L("Bekannte", "Known")) {
                                    ForEach(knownNetworks) { n in Button(n.name) { share.networks.append(n) } }
                                }.fixedSize()
                            }
                        }
                    } label: { Text(share.networks.isEmpty ? L("Netz", "Network") : "") }
                }
            }
            if limitNetworks {
                Text(networkInfo ?? L("Erkennt das Netz am Router (MAC-Adresse), ohne Ortungsdienste, per WLAN und LAN. Anderswo wartet die Freigabe („Unterwegs, pausiert“); ein Klick auf sie im Menü verbindet trotzdem.",
                                      "Recognises the network by its router (MAC address), without Location Services, on Wi-Fi and Ethernet. Elsewhere the share waits (“Away, paused”); clicking it in the menu still connects."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if wakeMACInvalid {
                Label(L("Keine gültige MAC-Adresse (z. B. 00:11:32:aa:bb:cc).", "Not a valid MAC address (for example 00:11:32:aa:bb:cc)."), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack(spacing: 8) {
                Button(testing ? L("Teste …", "Testing…") : L("Server testen", "Test Server")) { Task { await runTest() } }
                    .disabled(share.host.isEmpty || testing)
                Button(L("smb://-Adresse einfügen", "Paste smb:// Address")) { pasteAddress() }
                    .help(L("Adresse aus der Zwischenablage übernehmen, z. B. smb://alex@nas.local/Media", "Use the address on the clipboard, for example smb://alex@nas.local/Media"))
                if let test { Text(test).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
            if let dup = duplicate {
                Label(L("Diese Freigabe gibt es schon als „\(dup.displayName)“.", "This share already exists as “\(dup.displayName)”."), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Text(L("Das Passwort fragt danach „Anmelden …“ ab, macOS sichert es im Schlüsselbund.", "“Sign In…” asks for the password afterwards, and macOS saves it in the keychain."))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("Abbrechen", "Cancel"), action: onCancel).keyboardShortcut(.cancelAction)
                Button(L("Sichern", "Save")) {
                    share.host = share.host.trimmingCharacters(in: .whitespaces)
                    share.share = share.share.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
                    share.user = share.user.trimmingCharacters(in: .whitespaces)
                    share.wakeMAC = share.wakeMAC.flatMap(NetworkIdentity.normalizeMAC)
                    if !limitNetworks { share.networks = [] }
                    for i in share.networks.indices where share.networks[i].name.trimmingCharacters(in: .whitespaces).isEmpty {
                        share.networks[i].name = share.networks[i].router
                    }
                    onSave(share)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(share.host.trimmingCharacters(in: .whitespaces).isEmpty || share.share.isEmpty
                          || share.user.isEmpty || duplicate != nil || wakeMACInvalid
                          || (limitNetworks && share.networks.isEmpty))
            }
        }
        .padding(20)
        .frame(width: 470)
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
    }

    /// Wake on LAN is per server: an empty field shows the MAC another share of this server already has.
    static func prefilledWakeMAC(_ share: Share, others: [Share]) -> String? {
        if let own = share.wakeMAC, !own.isEmpty { return own }
        return Engine.wakeMAC(for: share.host, in: others)
    }

    private var wakeMACInvalid: Bool {
        let raw = (share.wakeMAC ?? "").trimmingCharacters(in: .whitespaces)
        return !raw.isEmpty && NetworkIdentity.normalizeMAC(raw) == nil
    }

    /// Networks other shares already use and this one does not have yet (same name everywhere).
    private var knownNetworks: [KnownNetwork] {
        var seen = Set(share.networks.map(\.router))
        return others.flatMap(\.networks).filter { seen.insert($0.router).inserted }
    }

    private func addCurrentNetwork() async {
        detecting = true
        defer { detecting = false }
        let routers = await detectRouters()
        let new = routers.subtracting(share.networks.map(\.router)).sorted()
        if routers.isEmpty {
            networkInfo = L("Kein Router erkannt. Mit dem Netz verbunden? Über VPN oder nur IPv6 klappt die Erkennung nicht.",
                            "No router found. Connected to the network? Detection does not work over VPN or IPv6 only.")
            return
        }
        guard !new.isEmpty else { networkInfo = L("Dieses Netz ist schon in der Liste.", "This network is already in the list."); return }
        for r in new {
            // Reuse the name another share gave this router.
            let name = others.flatMap(\.networks).first { $0.router == r }?.name
                ?? (share.networks.isEmpty ? L("Heimnetz", "Home network") : L("Netz \(share.networks.count + 1)", "Network \(share.networks.count + 1)"))
            share.networks.append(KnownNetwork(name: name, router: r))
        }
        networkInfo = nil
    }

    /// Gleicher Server + gleiche Freigabe schon vorhanden? Zwei Einträge würden sich denselben Mount teilen.
    private var duplicate: Share? {
        let host = share.host.trimmingCharacters(in: .whitespaces)
        let name = share.share.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !host.isEmpty, !name.isEmpty else { return nil }
        return others.first { $0.matches(host: host, share: name) }
    }

    /// Ganze Adresse ins Server-Feld eingefügt (smb://user@host/share)? → auf die Felder verteilen.
    private func splitAddress(_ v: String) {
        guard v.contains("/") || v.contains("\\"), let p = Share.parse(address: v) else { return }
        share.host = p.host
        share.share = p.share
        if let u = p.user, !u.isEmpty { share.user = u }
        test = L("Adresse übernommen", "Address applied")
    }

    private func pick(_ srv: ServerBrowser.Server) {
        resolving = true
        Task {
            // IPv6-Adressen (oft link-local, ohne Zone nicht nutzbar und als URL-Host ohne [] ungültig) → Bonjour-Name.
            let ip = await ServerBrowser.resolve(srv.endpoint).flatMap { $0.contains(":") ? nil : $0 }
            share.host = ip ?? (srv.name.replacingOccurrences(of: " ", with: "-") + ".local")
            resolving = false
            test = ip.map { "\(srv.name) → \($0)" }
        }
    }

    private func pasteAddress() {
        guard let raw = NSPasteboard.general.string(forType: .string), let p = Share.parse(address: raw) else {
            test = L("Keine smb://-Adresse in der Zwischenablage", "No smb:// address on the clipboard")
            return
        }
        share.host = p.host
        share.share = p.share
        if let u = p.user, !u.isEmpty { share.user = u }
        test = L("Übernommen", "Applied")
    }

    private func runTest() async {
        testing = true
        defer { testing = false }
        let host = share.host.trimmingCharacters(in: .whitespaces)
        let ok = await Mounter.reachable(host, timeout: 4)
        test = ok ? L("✓ \(host) antwortet auf SMB (Port 445)", "✓ \(host) responds to SMB (port 445)")
                   : L("✗ \(host) antwortet nicht auf SMB (Port 445)", "✗ \(host) does not respond to SMB (port 445)")
    }
}

// MARK: Allgemein

struct GeneralTab: View {
    @EnvironmentObject var prefs: Prefs
    @State private var loginItem = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                Toggle(L("Beim Anmelden starten", "Open at Login"), isOn: Binding(get: { loginItem }, set: { on in
                    do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                    catch { Log.write(L("Anmeldeobjekt", "Login item") + ": \(error.localizedDescription)") }
                    loginItem = SMAppService.mainApp.status == .enabled
                }))
                Picker(L("Prüfen alle", "Check every"), selection: $prefs.interval) {
                    Text(L("30 Sekunden", "30 seconds")).tag(30.0)
                    Text(L("1 Minute", "1 minute")).tag(60.0)
                    Text(L("2 Minuten", "2 minutes")).tag(120.0)
                    Text(L("5 Minuten", "5 minutes")).tag(300.0)
                }
                Toggle(L("Freier Speicher im Menü", "Show free space in menu"), isOn: $prefs.showUsage)
            }
            Section(L("Mitteilungen", "Notifications")) {
                Toggle(L("Bei Problemen melden", "Notify about problems"), isOn: $prefs.notify)
                Text(L("Falsches Passwort, Verbindung hing, Verbinden klappt dreimal nicht, neues Update. Höchstens alle 10 Minuten je Freigabe, nicht bei normalem Verlassen des Heimnetzes.",
                       "Wrong password, a hung connection, three failed connection attempts, a new update. At most every 10 minutes per share, and not when you simply leave your home network."))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(L("Auch melden, wenn wieder verbunden", "Also notify when reconnected"), isOn: $prefs.notifyRecovery).disabled(!prefs.notify)
                Button(L("Mitteilungs-Einstellungen öffnen", "Open Notification Settings")) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                }
            }
            Section(L("Passwörter", "Passwords")) {
                Text(L("ShareMount liest keine Passwörter selbst. Es verbindet über den Anmeldedienst von macOS, der das im Schlüsselbund gesicherte Passwort nimmt, genau wie der Finder. Deshalb gibt es nach Updates keine Schlüsselbund-Nachfragen mehr.",
                       "ShareMount never reads passwords itself. It connects through the macOS login service, which uses the password saved in the keychain, just like the Finder. That is why there are no keychain prompts after updates."))
                    .font(.caption).foregroundStyle(.secondary)
                Button(L("Schlüsselbundverwaltung öffnen", "Open Keychain Access")) {
                    // Per Bundle-ID statt festem Pfad (der Ort hat sich zwischen macOS-Versionen schon geändert)
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.keychainaccess") {
                        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { loginItem = SMAppService.mainApp.status == .enabled }
    }
}

// MARK: Updates

struct UpdatesTab: View {
    @EnvironmentObject var updater: Updater
    @EnvironmentObject var prefs: Prefs

    var body: some View {
        Form {
            Section {
                LabeledContent(L("Installiert", "Installed"), value: "v\(AppInfo.version)")
                LabeledContent(L("Status", "Status")) {
                    switch updater.state {
                    case .available(let v): Text(L("v\(v) verfügbar", "v\(v) available")).foregroundStyle(Color.accentColor)
                    case .upToDate: Text(L("Aktuell", "Up to date"))
                    case .checking: Text(L("Suche …", "Checking…"))
                    case .installing(let t): Text(t)
                    case .failed(let m): Text(m).foregroundStyle(.red)
                    case .idle: Text(updater.lastCheck == nil ? L("Noch nicht geprüft", "Not checked yet") : "")
                    }
                }
                if let d = updater.lastCheck {
                    LabeledContent(L("Zuletzt geprüft", "Last checked"), value: d.formatted(date: .abbreviated, time: .shortened))
                }
                HStack {
                    Button(L("Jetzt suchen", "Check Now")) { Task { await updater.check() } }
                    if case .available(let v) = updater.state {
                        Button(L("v\(v) installieren", "Install v\(v)")) { Task { await updater.install() } }.glassProminentButton()
                    }
                }
                Toggle(L("Automatisch suchen (alle 6 Std.)", "Check automatically (every 6 hours)"), isOn: $prefs.autoCheckUpdates)
                Toggle(L("Nach dem Start Fenster zeigen, wenn ein Update da ist", "Show a window after launch when an update is available"), isOn: $prefs.promptUpdates)
                    .disabled(!prefs.autoCheckUpdates)
            }
            if case .available = updater.state, !updater.notes.isEmpty {
                Section(L("Neu in dieser Version", "New in This Version")) {
                    Text(updater.notes).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Protokoll

struct LogTab: View {
    @EnvironmentObject var engine: Engine
    @State private var lines: [String] = []
    @State private var filter = ""
    @State private var problemsOnly = false

    /// Rückfall für Zeilen aus älteren Versionen ohne Log.problemMarker: deutsche und englische Reizwörter
    /// (je nach Sprache, mit der die Zeile geschrieben wurde).
    private static let problemWords = ["nicht", "fehl", "Fehler", "abgelehnt", "hängt", "reagiert", "weg", "Zeitüber",
                                       " not ", "failed", "Error", "rejected", "hung", "responding", "gone", "Timed out", "in use"]

    /// Problemzeile: seit 26.10 steht das Kennzeichen beim Schreiben in der Zeile, alte Zeilen über die Wortliste.
    static func isProblem(_ line: String) -> Bool {
        line.contains("  \(Log.problemMarker) ") || Self.problemWords.contains { line.contains($0) }
    }

    var shown: [String] {
        lines.reversed().filter { l in
            (filter.isEmpty || l.localizedCaseInsensitiveContains(filter)) &&
            (!problemsOnly || Self.isProblem(l))
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TextField(L("Filtern", "Filter"), text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                Toggle(L("Nur Probleme", "Problems only"), isOn: $problemsOnly).toggleStyle(.checkbox)
                Spacer()
                Button { reload() } label: { Image(systemName: "arrow.clockwise") }
                    .help(L("Neu laden", "Reload")).accessibilityLabel(L("Neu laden", "Reload"))
                Button(L("Kopieren", "Copy")) { copy(shown.reversed().joined(separator: "\n")) }
                Button(L("In Konsole", "Open in Console")) { NSWorkspace.shared.open(Log.url) }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, l in
                        Text(l).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Self.isProblem(l) ? Color.orange : Color.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            Text("\(Log.url.path) · " + L("neueste oben", "newest first")).font(.caption).foregroundStyle(.tertiary)
        }
        .padding(16)
        .onAppear { reload() }
        .onChange(of: engine.lastCheck) { _, _ in reload() }
    }

    private func reload() { lines = Log.tail() }
}
