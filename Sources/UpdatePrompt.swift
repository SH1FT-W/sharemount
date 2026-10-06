import SwiftUI

/// Fenster „Neue Version verfügbar“ – erscheint nach dem Start (und wenn im Betrieb eine neue Version
/// auftaucht), solange die Version nicht übersprungen wurde. Kein Modal: ShareMount prüft im Hintergrund weiter.
@MainActor
enum UpdatePrompt {
    private static var window: NSWindow?

    static func show(_ updater: Updater) {
        if let window, window.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: UpdatePromptView(close: close).environmentObject(updater))
        host.sizingOptions = .preferredContentSize
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = L("ShareMount-Update", "ShareMount Update")
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    static func close() {
        window?.close()
        window = nil
    }
}

struct UpdatePromptView: View {
    @EnvironmentObject var updater: Updater
    let close: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable().frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Neue Version von ShareMount", "A New Version of ShareMount Is Available")).font(.system(size: 15, weight: .semibold))
                    Text(L("v\(version) ist da, installiert ist v\(AppInfo.version).", "Version \(version) is available. You have version \(AppInfo.version)."))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if !updater.notes.isEmpty {
                    ScrollView {
                        Text(updater.notes)
                            .font(.system(size: 12))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .frame(maxHeight: 170)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
                }
                status
                HStack(spacing: 8) {
                    Button(L("Überspringen", "Skip This Version")) {
                        Prefs.shared.skippedUpdate = version
                        Log.write(L("Update v\(version) übersprungen", "Update v\(version) skipped"))
                        close()
                    }
                    .help(L("Diese Version überspringen: erst bei der nächsten wieder fragen. Installieren geht weiter über das Menü.", "Skip this version and ask again with the next one. You can still install it from the menu."))
                    Spacer()
                    Button(L("Später", "Remind Me Later"), action: close).keyboardShortcut(.cancelAction)
                    Button(L("Jetzt installieren", "Install Now")) { Task { await updater.install() } }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
                .disabled(installing)
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 20).padding(.bottom, 18).padding(.top, 26)
        .frame(width: 500)
        .onChange(of: updater.state) { _, s in
            // Inzwischen aktuell (z. B. über das Menü installiert) → Fenster hat sich erledigt.
            if s == .upToDate { close() }
        }
    }

    private var version: String {
        if case .available(let v) = updater.state { return v }
        return updater.offeredVersion ?? "?"
    }

    private var installing: Bool {
        if case .installing = updater.state { return true }
        return false
    }

    @ViewBuilder private var status: some View {
        switch updater.state {
        case .installing(let t):
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text(t) }
                .font(.system(size: 12)).foregroundStyle(.secondary)
        case .failed(let m):
            Label(m, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12)).foregroundStyle(Color(nsColor: .systemRed))
                .fixedSize(horizontal: false, vertical: true)
        default:
            EmptyView()
        }
    }
}
