import AppKit

/// Schneller Benutzerwechsel: Jeder angemeldete Benutzer hat seine eigene ShareMount-Kopie. Ist die eigene Sitzung
/// gerade im Hintergrund (anderer Benutzer vorne), läuft das Prüfen und Verbinden weiter – Fenster wie
/// „Neue Version“ warten aber, bis man wieder vorne ist, statt ungesehen aufzugehen.
@MainActor
enum Session {
    private(set) static var isActive = true
    private static var waiting: [() -> Void] = []
    private static var returnHandlers: [() -> Void] = []
    private static var started = false

    /// Wird bei jedem Zurückwechseln in diese Sitzung aufgerufen (zusätzlich zum onReturn von start).
    static func onReturn(_ block: @escaping () -> Void) { returnHandlers.append(block) }

    static func start(onReturn: @escaping () -> Void) {
        guard !started else { return }
        started = true
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                isActive = false
                Log.write(L("Benutzer gewechselt, ShareMount läuft im Hintergrund weiter", "User switched, ShareMount keeps running in the background"))
            }
        }
        nc.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                isActive = true
                Log.write(L("Wieder vorne (Benutzerwechsel)", "Back in front (user switch)"))
                let run = waiting
                waiting.removeAll()
                run.forEach { $0() }
                returnHandlers.forEach { $0() }
                onReturn()
            }
        }
    }

    /// Sofort, wenn die Sitzung vorne ist – sonst sobald der Benutzer zurückwechselt.
    static func whenActive(_ block: @escaping () -> Void) {
        if isActive { block() } else { waiting.append(block) }
    }
}
