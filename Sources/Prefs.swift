import Foundation

/// Einstellungen pro Mac (UserDefaults) – im Gegensatz zu den Freigaben, die über iCloud Drive wandern.
@MainActor
final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let d = UserDefaults.standard

    /// Mitteilung, wenn eine Freigabe verloren geht, das Passwort abgelehnt wird oder ein Update da ist.
    @Published var notify: Bool { didSet { d.set(notify, forKey: "notify") } }
    /// Auch melden, wenn eine verlorene Freigabe wieder verbunden ist.
    @Published var notifyRecovery: Bool { didSet { d.set(notifyRecovery, forKey: "notifyRecovery") } }
    /// Sekunden zwischen den regelmäßigen Prüfungen.
    @Published var interval: Double { didSet { d.set(interval, forKey: "interval") } }
    @Published var showUsage: Bool { didSet { d.set(showUsage, forKey: "showUsage") } }
    @Published var autoCheckUpdates: Bool { didSet { d.set(autoCheckUpdates, forKey: "autoCheckUpdates") } }
    /// Nach dem Start ein Fenster „Neue Version“ zeigen (sonst nur Menüeintrag + Mitteilung).
    @Published var promptUpdates: Bool { didSet { d.set(promptUpdates, forKey: "promptUpdates") } }

    private init() {
        d.register(defaults: ["notify": true, "notifyRecovery": false, "interval": 60.0,
                              "showUsage": true, "autoCheckUpdates": true, "promptUpdates": true])
        notify = d.bool(forKey: "notify")
        notifyRecovery = d.bool(forKey: "notifyRecovery")
        interval = d.double(forKey: "interval")
        showUsage = d.bool(forKey: "showUsage")
        autoCheckUpdates = d.bool(forKey: "autoCheckUpdates")
        promptUpdates = d.bool(forKey: "promptUpdates")
    }

    /// „Diese Version überspringen“ im Update-Fenster – für diese Version kein Fenster/keine Mitteilung mehr.
    var skippedUpdate: String? {
        get { d.string(forKey: "skippedUpdate") }
        set { d.set(newValue, forKey: "skippedUpdate") }
    }

    /// Für welche Version zuletzt „Update ist da“ gemeldet wurde (je Version nur eine Mitteilung).
    var notifiedUpdate: String? {
        get { d.string(forKey: "notifiedUpdate") }
        set { d.set(newValue, forKey: "notifiedUpdate") }
    }

    /// Versionshinweise, die nach dem Neustart einmal angezeigt werden.
    var pendingNotes: (version: String, notes: String)? {
        get {
            guard let v = d.string(forKey: "pendingNotesVersion") else { return nil }
            return (v, d.string(forKey: "pendingNotes") ?? "")
        }
        set {
            d.set(newValue?.version, forKey: "pendingNotesVersion")
            d.set(newValue?.notes, forKey: "pendingNotes")
        }
    }
}
