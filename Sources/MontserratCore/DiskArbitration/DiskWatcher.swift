import Foundation
#if canImport(DiskArbitration)
import DiskArbitration
#endif

public final class DiskWatcher: @unchecked Sendable {
    public typealias DiskEventCallback = @Sendable (String, DiskEvent) -> Void

    public enum DiskEvent: Sendable {
        case appeared
        case disappeared
        case changed
    }

    private var session: DASession?
    private var callback: DiskEventCallback?

    public init() {}

    public func start(onEvent: @escaping DiskEventCallback) {
        #if canImport(DiskArbitration)
        self.callback = onEvent
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return }
        self.session = session

        let context = Unmanaged.passUnretained(self).toOpaque()

        let appearedCallback: DADiskAppearedCallback = { disk, ctx in
            guard let ctx = ctx else { return }
            let watcher = Unmanaged<DiskWatcher>.fromOpaque(ctx).takeUnretainedValue()
            if let bsdName = DADiskGetBSDName(disk) {
                let name = String(cString: bsdName)
                watcher.callback?(name, .appeared)
            }
        }

        let disappearedCallback: DADiskDisappearedCallback = { disk, ctx in
            guard let ctx = ctx else { return }
            let watcher = Unmanaged<DiskWatcher>.fromOpaque(ctx).takeUnretainedValue()
            if let bsdName = DADiskGetBSDName(disk) {
                let name = String(cString: bsdName)
                watcher.callback?(name, .disappeared)
            }
        }

        DARegisterDiskAppearedCallback(session, nil, appearedCallback, context)
        DARegisterDiskDisappearedCallback(session, nil, disappearedCallback, context)
        DASessionScheduleWithRunLoop(session, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        #endif
    }

    public func stop() {
        #if canImport(DiskArbitration)
        if let session = session {
            DASessionUnscheduleFromRunLoop(session, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            self.session = nil
        }
        self.callback = nil
        #endif
    }

    deinit {
        stop()
    }
}
