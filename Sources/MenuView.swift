import SwiftUI
import ServiceManagement

// MARK: - Dropdown (Aufbau wie die System-Menüs in macOS 26/27: WLAN, Bluetooth, Kontrollzentrum)

struct MenuView: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var updater: Updater
    @EnvironmentObject var router: Router
    @EnvironmentObject var prefs: Prefs
    @Environment(\.openWindow) private var openWindow
    @State private var loginItem = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)

            notices

            MenuSeparator()
            SectionHeader(title: L("Freigaben", "Shares"))
            VStack(spacing: 0) {
                if engine.shares.isEmpty {
                    Text(L("Noch keine Freigaben. In den Einstellungen hinzufügen.", "No shares yet. Add one in Settings."))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .padding(.horizontal, 9).padding(.vertical, 6)
                }
                ForEach(engine.shares) { s in
                    ShareRow(share: s, status: engine.status[s.id] ?? .checking, usage: engine.usage[s.id],
                             since: engine.connectedSince[s.id]) { settings(edit: s) }
                }
            }
            .padding(.horizontal, 5)

            let foreign = engine.foreignMounts
            if !foreign.isEmpty {
                MenuSeparator()
                SectionHeader(title: L("Weitere SMB-Freigaben", "Other SMB Shares"), detail: L("nicht verwaltet", "not managed"))
                VStack(spacing: 0) {
                    ForEach(foreign, id: \.path) { m in
                        MenuItem(title: m.share, icon: "plus.circle", detail: m.host) {
                            engine.adopt(m)
                        }
                        .help(L("In ShareMount übernehmen: wird dann automatisch verbunden gehalten", "Add to ShareMount to keep it connected automatically"))
                    }
                }
                .padding(.horizontal, 5)
            }

            MenuSeparator()
            VStack(spacing: 0) {
                MenuItem(title: L("Alle neu verbinden", "Reconnect All"), icon: "arrow.clockwise") { engine.reconnectAll() }
                if engine.connectedCount > 0 {
                    MenuItem(title: L("Alle trennen", "Disconnect All"), icon: "eject") { engine.disconnectAll() }
                }
                MenuItem(title: L("Einstellungen …", "Settings…"), icon: "gearshape", shortcut: "⌘,") { settings() }
                    .keyboardShortcut(",")
                ToggleRow(title: L("Beim Anmelden starten", "Open at Login"), isOn: Binding(get: { loginItem }, set: { _ in toggleLoginItem() }))
                updateItem
            }
            .padding(.horizontal, 5)

            MenuSeparator()
            MenuItem(title: L("ShareMount beenden", "Quit ShareMount"), icon: "xmark.rectangle", shortcut: "⌘Q") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
                .padding(.horizontal, 5).padding(.bottom, 5)
        }
        .frame(width: 330)
        .onAppear { loginItem = SMAppService.mainApp.status == .enabled }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("ShareMount").font(.system(size: 13, weight: .semibold))
                Text(engine.summary).font(.system(size: 11))
                    .foregroundStyle(engine.hasProblem ? Color(nsColor: .systemRed) : Color.secondary)
            }
            Spacer()
            Button { Task { await engine.checkAll() } } label: {
                Group {
                    if engine.isChecking { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold)) }
                }
                .frame(width: 16, height: 16)
            }
            .glassCircleButton()
            .help(engine.lastCheck.map { L("Jetzt prüfen", "Check Now") + " (\(RelTime.lastChecked($0)))" } ?? L("Jetzt prüfen", "Check Now"))
            .accessibilityLabel(L("Jetzt prüfen", "Check Now"))
        }
    }

    @ViewBuilder
    private var notices: some View {
        ForEach(engine.shares.filter { engine.misplaced[$0.id] != nil }) { s in
            NoticeRow(icon: "folder.badge.gearshape",
                      text: L("„\(s.displayName)“ liegt auf \(engine.misplaced[s.id] ?? "") statt \(s.cleanMountPath). Skripte/Backups mit dem festen Pfad finden sie so nicht.",
                             "“\(s.displayName)” is mounted at \(engine.misplaced[s.id] ?? "") instead of \(s.cleanMountPath). Scripts and backups that use the fixed path won’t find it."),
                      action: (L("Pfad korrigieren (trennt kurz)", "Fix Path (briefly disconnects)"), { engine.fixMountPath(s) }))
        }
        ForEach(engine.shares.filter { engine.blockedPaths[$0.id] != nil }) { s in
            NoticeRow(icon: "folder.badge.questionmark",
                      text: L("„\(s.displayName)“ liegt nicht unter \(s.cleanMountPath): dort steht ein leerer Ordner von einem abgebrochenen Mount. Im Terminal entfernen: sudo rmdir \"\(s.cleanMountPath)\"",
                             "“\(s.displayName)” is not mounted at \(s.cleanMountPath) because an empty folder from an interrupted mount is in the way. Remove it in Terminal: sudo rmdir \"\(s.cleanMountPath)\""),
                      action: (L("Befehl kopieren", "Copy Command"), { copy("sudo rmdir \"\(s.cleanMountPath)\"") }))
        }
    }

    @ViewBuilder
    private var updateItem: some View {
        switch updater.state {
        case .available(let v):
            MenuItem(title: L("Update auf v\(v) installieren", "Update to v\(v)"), icon: "arrow.down.app.fill", detail: "v\(AppInfo.version)") {
                Task { await updater.install() }
            }
            .help(updater.notes)
        case .installing(let text):
            MenuItem(title: text, icon: "arrow.down.app") {}.disabled(true)
        case .failed(let msg):
            MenuItem(title: L("Nach Updates suchen …", "Check for Updates…"), icon: "arrow.down.app", detail: "v\(AppInfo.version)") {
                Task { await updater.check() }
            }
            Text(msg).font(.system(size: 11)).foregroundStyle(Color(nsColor: .systemRed))
                .lineLimit(2).padding(.horizontal, 33).padding(.bottom, 3)
        default:
            EmptyView()   // Suchen von Hand: Einstellungen → Updates
        }
        if let d = updater.tokenExpiresSoon {
            Text(L("GitHub-Token läuft am \(d.formatted(date: .numeric, time: .omitted)) ab", "GitHub token expires on \(d.formatted(date: .numeric, time: .omitted))"))
                .font(.system(size: 11)).foregroundStyle(Color(nsColor: .systemOrange))
                .padding(.horizontal, 33).padding(.bottom, 3)
        }
    }

    private func settings(edit: Share? = nil) {
        if let edit { router.tab = .shares; router.editing = edit }
        openWindow(id: "settings")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func toggleLoginItem() {
        do {
            if loginItem { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch {
            Log.write(L("Anmeldeobjekt", "Login item") + ": \(error.localizedDescription)")
        }
        loginItem = SMAppService.mainApp.status == .enabled
    }
}

func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

/// Eine Freigabe wie ein Gerät im Bluetooth-Menü: runder Knopf (blau = verbunden), Name, Server/Speicher.
/// Klick öffnet im Finder (bzw. verbindet), Rechtsklick zeigt alle Aktionen.
struct ShareRow: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var prefs: Prefs
    let share: Share
    let status: ShareStatus
    let usage: Usage?
    let since: Date?
    let edit: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle().fill(status.color)
                if status.isBusy || engine.signingIn == share.id {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: status.symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(status.glyph)
                }
            }
            .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(share.displayName).font(.system(size: 13)).lineLimit(1)
                    Spacer(minLength: 4)
                    if prefs.showUsage, let usage, status.isMounted {
                        Text(usage.freeText).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                if prefs.showUsage, let usage, status.isMounted { UsageBar(fraction: usage.fraction) }
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(status.isProblem ? status.color : Color.secondary)
                    .lineLimit(2)
            }

            if hover && share.enabled {
                Button(action: primaryAction) {
                    Image(systemName: actionIcon).font(.system(size: 12, weight: .medium)).frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .help(actionHelp)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(cardShape(8).fill(Color.primary.opacity(hover ? 0.08 : 0)))
        .contentShape(Rectangle())
        .onTapGesture {
            if status == .authFailed { engine.signIn(share) } else { engine.open(share) }
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .contextMenu {
            if let p = engine.path(of: share) {
                Button(L("Im Finder öffnen", "Open in Finder")) { engine.open(share) }
                Button(L("Im Terminal öffnen", "Open in Terminal")) {
                    NSWorkspace.shared.open([URL(fileURLWithPath: p)],
                                            withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                            configuration: NSWorkspace.OpenConfiguration())
                }
                Button(L("Pfad kopieren", "Copy Path") + " (\(p))") { copy(p) }
                Divider()
                Button(L("Trennen", "Disconnect")) { engine.disconnect(share) }
            } else {
                Button(L("Jetzt verbinden", "Connect Now")) { engine.connect(share) }.disabled(!share.enabled)
            }
            Button(L("Adresse kopieren", "Copy Address")) { copy(share.address) }
            Button(L("Anmelden …", "Sign In…")) { engine.signIn(share) }
            Divider()
            Button(L("Bearbeiten …", "Edit…"), action: edit)
        }
        // VoiceOver: eine Zeile = ein Element („config, Verbunden, …“) mit Haupt- und Trenn-Aktion.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: actionHelp) { primaryAction() }
        .help(status.isMounted ? L("Klicken öffnet \(share.displayName) im Finder", "Click to open \(share.displayName) in Finder")
              : status == .authFailed ? L("Klicken zum Anmelden", "Click to sign in") : L("Klicken zum Verbinden", "Click to connect"))
    }

    private var subtitle: String {
        if status.isMounted {
            let path = engine.path(of: share).map { $0 == share.cleanMountPath ? "" : " · \($0)" } ?? ""
            return share.host + (since.map { " · " + RelTime.connected(since: $0) } ?? "") + path
        }
        return "\(share.host) · \(status.text)"
    }

    private var actionIcon: String {
        status.isMounted ? "eject" : status == .authFailed ? "key" : "arrow.clockwise"
    }
    private var actionHelp: String {
        status.isMounted ? L("Trennen", "Disconnect") : status == .authFailed ? L("Anmelden …", "Sign In…") : L("Jetzt verbinden", "Connect Now")
    }
    private func primaryAction() {
        if status.isMounted { engine.disconnect(share) }
        else if status == .authFailed { engine.signIn(share) }
        else { engine.connect(share) }
    }
}
