import SwiftUI
import UserNotifications

#if !SNAPSHOT
@main
#endif
struct ShareMountApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var engine = Engine()
    @StateObject private var updater = Updater()
    @StateObject private var router = Router.shared
    @StateObject private var prefs = Prefs.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(engine).environmentObject(updater)
                .environmentObject(router).environmentObject(prefs)
        } label: {
            Image(nsImage: MenuBarIcon.make(connected: engine.connectedCount > 0, problem: engine.hasProblem,
                                            waiting: !engine.networkReady))
        }
        .menuBarExtraStyle(.window)

        Window("ShareMount", id: "settings") {
            SettingsView()
                .environmentObject(engine).environmentObject(updater)
                .environmentObject(router).environmentObject(prefs)
        }
        .windowResizability(.contentSize)
    }
}

/// Mitteilungen auch zeigen, wenn ShareMount gerade vorne ist (Einstellungsfenster offen).
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        Task { @MainActor in Notifier.requestAuthorization() }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .list] }
}

/// Welcher Reiter/welche Freigabe im Einstellungsfenster gezeigt werden soll (vom Menü aus gesteuert).
@MainActor
final class Router: ObservableObject {
    static let shared = Router()
    enum Tab: String, CaseIterable, Identifiable {
        case shares, general, updates, log
        var id: String { rawValue }
        var title: String {
            switch self {
            case .shares: return L("Freigaben", "Shares")
            case .general: return L("Allgemein", "General")
            case .updates: return L("Updates", "Updates")
            case .log: return L("Protokoll", "Log")
            }
        }
        var icon: String {
            switch self {
            case .shares: return "externaldrive.connected.to.line.below"
            case .general: return "gearshape"
            case .updates: return "arrow.down.app"
            case .log: return "doc.text.magnifyingglass"
            }
        }
    }
    @Published var tab: Tab = .shares
    @Published var editing: Share?
}

/// Menüleisten-Symbol wie bei den System-Extras in macOS 26/27: ein monochromes Template-Symbol,
/// Zustand nur als Abzeichen (Ausrufezeichen = Problem), gedimmt solange nichts verbunden ist.
enum MenuBarIcon {
    static func make(connected: Bool, problem: Bool, waiting: Bool) -> NSImage {
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let name = problem ? "externaldrive.badge.exclamationmark" : "externaldrive.connected.to.line.below"
        guard let sym = NSImage(systemSymbolName: name, accessibilityDescription: "ShareMount")?
            .withSymbolConfiguration(cfg) else { return NSImage() }
        let size = NSSize(width: sym.size.width, height: max(sym.size.height, 16))
        let img = NSImage(size: size, flipped: false) { _ in
            sym.draw(in: NSRect(x: 0, y: (size.height - sym.size.height) / 2, width: sym.size.width, height: sym.size.height),
                     from: .zero, operation: .sourceOver, fraction: connected || problem ? 1 : waiting ? 0.35 : 0.5)
            return true
        }
        img.isTemplate = true
        return img
    }
}

// MARK: - Status-Darstellung

extension ShareStatus {
    var color: Color {
        switch self {
        case .mounted: return .accentColor
        case .stale: return Color(nsColor: .systemOrange)
        case .failed, .authFailed: return Color(nsColor: .systemRed)
        case .mounting, .checking, .waitingForNetwork, .unreachable, .disconnected, .disabled:
            return Color.primary.opacity(0.12)
        }
    }

    /// Weiß auf Farbe, dunkel auf dem grauen „inaktiv“-Kreis (wie im WLAN-/Bluetooth-Menü).
    var glyph: Color {
        switch self {
        case .mounted, .stale, .failed, .authFailed: return .white
        default: return .primary
        }
    }

    var symbol: String {
        switch self {
        case .mounted: return "externaldrive.fill"
        case .mounting, .checking: return "arrow.triangle.2.circlepath"
        case .waitingForNetwork: return "wifi"
        case .stale: return "hourglass"
        case .failed: return "exclamationmark"
        case .authFailed: return "key.fill"
        case .unreachable: return "wifi.slash"
        case .disconnected: return "eject.fill"
        case .disabled: return "pause.fill"
        }
    }
}
