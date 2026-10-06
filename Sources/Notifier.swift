import Foundation
import UserNotifications

/// Mitteilungen in der Mitteilungszentrale. Pro Freigabe höchstens eine offene Meldung je Art,
/// und dieselbe Art nicht öfter als alle 10 Minuten – ein wackliges NAS soll nicht spammen.
@MainActor
enum Notifier {
    private static var lastSent: [String: Date] = [:]
    private static var authorized: Bool?
    /// Mitteilungen, die vor der Antwort auf die Berechtigungsabfrage kamen (z. B. „aktualisiert“ direkt nach
    /// einem Update). Nach einem Wechsel der Bundle-ID fragt macOS neu; ohne Warteschlange ginge die verloren.
    private static var queued: [UNNotificationRequest] = []

    /// Ohne App-Bundle (Selbsttest, Snapshot-Werkzeug) stürzt UNUserNotificationCenter ab.
    private static var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    static func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, _ in
            Task { @MainActor in
                authorized = ok
                if ok { queued.forEach(deliver) }
                queued = []
            }
        }
    }

    static func send(_ key: String, title: String, body: String, force: Bool = false) {
        guard available, force || Prefs.shared.notify else { return }
        if !force, let last = lastSent[key], Date().timeIntervalSince(last) < 600 { return }
        lastSent[key] = Date()
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        let r = UNNotificationRequest(identifier: key, content: c, trigger: nil)
        if authorized == nil { queued.removeAll { $0.identifier == key }; queued.append(r) }
        else { deliver(r) }
    }

    private static func deliver(_ r: UNNotificationRequest) {
        UNUserNotificationCenter.current().add(r, withCompletionHandler: nil)
    }

    static func clear(_ key: String) {
        guard available else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [key])
    }
}
