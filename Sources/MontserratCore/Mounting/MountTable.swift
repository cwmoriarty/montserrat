import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct MountTableEntry: Codable, Sendable, Equatable {
    public let from: String
    public let on: String
    public let type: String

    public init(from: String, on: String, type: String) {
        self.from = from
        self.on = on
        self.type = type
    }
}

public enum MountTable {
    private static func stringFromTuple<T>(_ tuple: T) -> String {
        var copy = tuple
        let size = MemoryLayout<T>.size
        return withUnsafePointer(to: &copy) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: size) {
                String(cString: $0)
            }
        }
    }

    public static func entries() -> [MountTableEntry] {
        var mntbuf: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&mntbuf, MNT_NOWAIT)
        guard count > 0, let buf = mntbuf else { return [] }

        var list: [MountTableEntry] = []
        for i in 0..<Int(count) {
            let stat = buf[i]
            let from = stringFromTuple(stat.f_mntfromname)
            let on = stringFromTuple(stat.f_mntonname)
            let type = stringFromTuple(stat.f_fstypename)
            list.append(MountTableEntry(from: from, on: on, type: type))
        }
        return list
    }

    public static func isMountPoint(_ path: String) -> Bool {
        let stdPath = URL(fileURLWithPath: path).standardized.path
        return entries().contains { URL(fileURLWithPath: $0.on).standardized.path == stdPath }
    }
}
