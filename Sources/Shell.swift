import Foundation

/// Externe Programme (diskutil, umount, ditto …) – immer im Hintergrund und mit Zeitlimit.
enum Shell {
    @discardableResult
    static func run(_ exe: String, _ args: [String], timeout: TimeInterval = 60) async -> Bool {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            // Genau eine Antwort: entweder meldet sich der terminationHandler oder das Zeitlimit (dann wie bisher
            // beenden und false). Kein Busy-Wait mit usleep mehr, der Thread schläft bis zum Ende des Programms.
            let once = Once()
            p.terminationHandler = { p in once.run { cont.resume(returning: p.terminationStatus == 0) } }
            do { try p.run() } catch { once.run { cont.resume(returning: false) }; return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.run {
                    if p.isRunning { p.terminate() }
                    cont.resume(returning: false)
                }
            }
        }
    }

    /// Führt den ersten Block aus, alle weiteren nicht (Terminierung und Zeitlimit können sich überholen).
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func run(_ block: () -> Void) {
            lock.lock()
            let first = !done
            done = true
            lock.unlock()
            if first { block() }
        }
    }
}
