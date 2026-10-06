// Rendert Dropdown + Einstellungen als PNG, ohne die Menüleiste anzufassen.
//   build/snapshot                 → build/snap-*.png mit der Konfiguration des (Test-)Homes
//   build/snapshot --demo <Ordner> → Beispiel-Freigaben für README/Website (./build.sh snapshot)
// Immer mit CFFIXED_USER_HOME=<Test-Home> starten, damit echte Einstellungen und Mounts unberührt bleiben.
import SwiftUI

@main
struct Snap {
    @MainActor static func main() async {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--demo") {
            let out = i + 1 < args.count ? args[i + 1] : "build"
            await demo(out)
            return
        }
        let engine = Engine()
        let updater = Updater()
        let env = environment(engine, updater)
        try? await Task.sleep(nanoseconds: 8_000_000_000)   // ersten Prüfdurchlauf abwarten
        if args.contains("--live") {
            for (name, dark) in [("light", false), ("dark", true)] {
                live(env(MenuView()), "build/live-\(name).png", dark)
            }
            return
        }
        for (name, dark) in [("light", false), ("dark", true)] {
            shot(env(MenuView()), "build/snap-menu-\(name).png", dark)
        }
        updater.preview("2.2", notes: Updater.cleanNotes("## Neu in 2.2\n- Update-Fenster nach dem Start\n- Diese Version überspringen\n- Kleinere Verbesserungen"))
        for (name, dark) in [("light", false), ("dark", true)] {
            shot(env(UpdatePromptView(close: {})), "build/snap-update-\(name).png", dark)
        }
        for tab in Router.Tab.allCases {
            Router.shared.tab = tab
            shot(env(SettingsView()), "build/snap-settings-\(tab).png", false)
        }
    }

    @MainActor static func environment(_ engine: Engine, _ updater: Updater) -> (any View) -> AnyView {
        { v in
            AnyView(AnyView(v).environmentObject(engine).environmentObject(updater)
                .environmentObject(Router.shared).environmentObject(Prefs.shared))
        }
    }

    /// Beispiel-Freigaben auf „nas.local“ – nie die echte Konfiguration, nie echte Mounts.
    @MainActor static func demo(_ out: String) async {
        let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] ?? ""
        guard !home.isEmpty, Store.localDir.path.hasPrefix(home), Store.iCloudRoot.path.hasPrefix(home), Log.url.path.hasPrefix(home) else {
            print("--demo nur mit CFFIXED_USER_HOME=<Test-Home> (sonst würden echte Einstellungen gelesen)")
            exit(1)
        }
        AppInfo.versionOverride = "2.2"
        if let icon = NSImage(contentsOfFile: "Resources/AppIcon.icns") { NSApp.applicationIconImage = icon }
        let engine = Engine()
        let updater = Updater()
        let env = environment(engine, updater)
        let now = Date()
        let tb: Int64 = 1_000_000_000_000
        let media = Share(host: "nas.local", share: "Media", user: "alex")
        let backups = Share(host: "nas.local", share: "Backups", user: "alex")
        let projects = Share(host: "nas.local", share: "Projects", user: "alex")
        let archive = Share(host: "archive.local", share: "Archive", user: "alex")
        engine.preview([
            (media, .mounted("/Volumes/Media"), Usage(free: 3_400_000_000_000, total: 8 * tb), now.addingTimeInterval(-3 * 3600)),
            (backups, .mounted("/Volumes/Backups"), Usage(free: 620_000_000_000, total: 4 * tb), now.addingTimeInterval(-3 * 3600)),
            (projects, .mounted("/Volumes/Projects"), Usage(free: 1_250_000_000_000, total: 2 * tb), now.addingTimeInterval(-25 * 60)),
            (archive, .unreachable, nil, nil),
        ], checked: now.addingTimeInterval(-40))
        try? await Task.sleep(nanoseconds: 600_000_000)
        writeDemoLog(now)

        for (name, dark) in [("light", false), ("dark", true)] {
            shot(env(MenuView()), "\(out)/menu-\(name).png", dark)
        }
        // Reiter-Inhalt ohne Reiterleiste (deren ausgewählter Knopf rendert offscreen leer).
        for (name, dark) in [("light", false), ("dark", true)] {
            shot(env(SharesTab().frame(width: 600, height: 400)), "\(out)/settings-shares-\(name).png", dark)
        }
        updater.preview("2.3", notes: Updater.cleanNotes(L("## Neu in 2.3\n- Schnelleres Wiederverbinden nach dem Aufwachen\n- Kleinere Verbesserungen",
                                                         "## New in 2.3\n- Faster reconnect after wake\n- Minor improvements")))
        for (name, dark) in [("light", false), ("dark", true)] {
            shot(env(UpdatePromptView(close: {})), "\(out)/update-\(name).png", dark)
        }
        print("Demo-Screenshots: \(out)")
    }

    /// Ein glaubwürdiges Protokoll für die Protokoll-Ansicht.
    static func writeDemoLog(_ now: Date) {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let lines: [(TimeInterval, String)] = [
            (-3 * 3600 - 30, L("Start v2.2: 4 Freigabe(n)", "Launch v2.2: 4 share(s)")),
            (-3 * 3600 - 28, L("Netzwerk bereit (en0)", "Network ready (en0)")),
            (-3 * 3600 - 25, L("Media: verbunden → /Volumes/Media", "Media: connected → /Volumes/Media")),
            (-3 * 3600 - 24, L("Backups: verbunden → /Volumes/Backups", "Backups: connected → /Volumes/Backups")),
            (-3 * 3600 - 23, L("Projects: verbunden → /Volumes/Projects", "Projects: connected → /Volumes/Projects")),
            (-3 * 3600 - 20, L("Archive: Server archive.local nicht erreichbar", "Archive: Server archive.local not reachable")),
            (-40 * 60, L("Aufgewacht", "Woke from sleep")),
            (-26 * 60, L("Projects: Server weg, Mount wird gelöst", "Projects: Server gone, unmounting")),
            (-25 * 60, L("Projects: verbunden → /Volumes/Projects", "Projects: connected → /Volumes/Projects")),
        ]
        let text = lines.map { "\(f.string(from: now.addingTimeInterval($0.0)))  \($0.1)" }.joined(separator: "\n") + "\n"
        _ = Log.tail(1)   // ausstehende Schreibvorgänge abwarten
        try? text.write(to: Log.url, atomically: true, encoding: .utf8)
    }

    @MainActor static func live(_ view: AnyView, _ path: String, _ dark: Bool) {
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let win = NSPanel(contentRect: NSRect(x: 200, y: 150, width: size.width, height: size.height),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .popUpMenu
        let fx = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        fx.material = .menu; fx.state = .active; fx.blendingMode = .behindWindow
        fx.wantsLayer = true; fx.layer?.cornerRadius = 14; fx.layer?.masksToBounds = true
        host.frame = fx.bounds
        fx.addSubview(host)
        win.contentView = fx
        win.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", "\(win.windowNumber)", path]
        try? p.run(); p.waitUntilExit()
        win.close()
    }

    @MainActor static func shot(_ view: AnyView, _ path: String, _ dark: Bool) {
        // Offscreen ist das Fenster nie aktiv; ohne das hier wären Standardknöpfe und Schalter grau („inaktiv“).
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor))
            .environment(\.controlActiveState, .key))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let size = host.fittingSize
        let win = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: size.width, height: size.height),
                           styleMask: .borderless, backing: .buffered, defer: false)
        win.contentView = host
        win.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
        win.close()
    }
}
