import Foundation
import Network

/// Findet SMB-Server im Heimnetz (Bonjour „_smb._tcp“) – für die Server-Vorschläge im Editor.
@MainActor
final class ServerBrowser: ObservableObject {
    struct Server: Identifiable, Hashable {
        let name: String
        let endpoint: NWEndpoint
        var id: String { name }
    }

    @Published private(set) var servers: [Server] = []
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjour(type: "_smb._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let list = results.compactMap { r -> Server? in
                if case .service(let name, _, _, _) = r.endpoint { return Server(name: name, endpoint: r.endpoint) }
                return nil
            }
            Task { @MainActor in self?.servers = list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
        }
        b.start(queue: .global())
        browser = b
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    /// Dienst → IP-Adresse (kurz verbinden und die Gegenstelle ablesen). nil nach 4 s.
    static func resolve(_ endpoint: NWEndpoint) async -> String? {
        await withCheckedContinuation { cont in
            let conn = NWConnection(to: endpoint, using: .tcp)
            let lock = NSLock()
            var done = false
            let finish: (String?) -> Void = { host in
                lock.lock(); let first = !done; done = true; lock.unlock()
                guard first else { return }
                conn.cancel()
                cont.resume(returning: host)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case .hostPort(let host, _) = conn.currentPath?.remoteEndpoint {
                        var s = "\(host)"
                        if let pct = s.firstIndex(of: "%") { s = String(s[..<pct]) }   // IPv6-Zonen-Suffix
                        finish(s)
                    } else { finish(nil) }
                case .failed, .cancelled: finish(nil)
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 4) { finish(nil) }
        }
    }
}
