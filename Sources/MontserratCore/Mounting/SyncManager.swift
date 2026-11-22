import Foundation
#if canImport(AppKit)
import AppKit
#endif

public final class SyncManager: @unchecked Sendable {
    public static let shared = SyncManager()

    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.cwmoriarty.montserrat.sync", qos: .utility)
    private var isRunning = false

    public init() {
        setupPowerNotifications()
    }

    /// Starts periodic background flushing (default every 15 seconds)
    public func start(intervalSeconds: Double = 15.0) {
        queue.async { [weak self] in
            guard let self = self, !self.isRunning else { return }
            self.isRunning = true

            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + intervalSeconds, repeating: intervalSeconds)
            t.setEventHandler { [weak self] in
                self?.performPeriodicSync()
            }
            t.resume()
            self.timer = t
        }
    }

    /// Stops periodic flushing
    public func stop() {
        queue.async {
            self.isRunning = false
            self.timer?.cancel()
            self.timer = nil
        }
    }

    /// Performs asynchronous dirty page write-back without blocking I/O pipelines
    public func performPeriodicSync() {
        #if canImport(Darwin)
        Darwin.sync()
        #endif
    }

    /// Flushes dirty filesystem buffers and commits hardware barriers via F_FULLFSYNC
    public func performFullBarrierSync() {
        #if canImport(Darwin)
        Darwin.sync()

        let mounts = MountManager.shared.activeMounts()
        for mount in mounts {
            flushBarrier(mountPoint: mount.mountPoint)
        }
        #endif
    }

    /// Commits dirty buffers and forces on-disk flash barrier for a specific mountpoint
    public func flushBarrier(mountPoint: String) {
        #if canImport(Darwin)
        let fd = Darwin.open(mountPoint, O_RDONLY)
        if fd >= 0 {
            _ = Darwin.fcntl(fd, F_FULLFSYNC)
            Darwin.close(fd)
        }
        #endif
    }

    private func setupPowerNotifications() {
        #if canImport(AppKit)
        let center = NSWorkspace.shared.notificationCenter

        // Before system goes to sleep: commit hardware barrier immediately
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.performFullBarrierSync()
        }

        // On wake: asynchronous flush
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.performPeriodicSync()
        }
        #endif
    }
}
