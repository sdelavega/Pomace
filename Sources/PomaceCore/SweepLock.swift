import Foundation
import Darwin

/// One run across the GUI and the sweep agent. Closing the descriptor also releases the lock.
public final class SweepLock: @unchecked Sendable {
    private let mutex = NSLock()
    private var descriptor: Int32

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pomace/sweep.lock")
    }

    private init(descriptor: Int32) { self.descriptor = descriptor }

    public static func acquire(at url: URL = SweepLock.defaultURL) -> SweepLock? {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
        } catch { return nil }
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        return SweepLock(descriptor: descriptor)
    }

    public static func isHeld(at url: URL = SweepLock.defaultURL) -> Bool {
        // A separate open is essential: locking the holder's descriptor would convert its lock.
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return errno != ENOENT }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_SH | LOCK_NB) == 0 else { return true }
        flock(descriptor, LOCK_UN)
        return false
    }

    public func release() {
        mutex.lock()
        defer { mutex.unlock() }
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}
