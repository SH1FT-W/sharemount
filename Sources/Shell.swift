import Foundation

/// Externe Programme (diskutil, umount, ditto …) – immer im Hintergrund und mit Zeitlimit.
enum Shell {
    @discardableResult
    static func run(_ exe: String, _ args: [String], timeout: TimeInterval = 60) async -> Bool {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(returning: false); return }
                let deadline = Date().addingTimeInterval(timeout)
                while p.isRunning && Date() < deadline { usleep(100_000) }
                if p.isRunning {
                    p.terminate()
                    cont.resume(returning: false)
                } else {
                    cont.resume(returning: p.terminationStatus == 0)
                }
            }
        }
    }
}
