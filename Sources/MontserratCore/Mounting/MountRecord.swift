import Foundation

public struct MountRecord: Codable, Sendable, Identifiable, Equatable {
    public var id: String { bsdName ?? source }
    public let source: String
    public let bsdName: String?
    public let wholeDiskBSDName: String?
    public let mountPoint: String
    public let fileSystem: FileSystemKind
    public let engine: String
    public let enginePath: String
    public let pid: Int32
    public let readOnly: Bool
    public let volumeName: String
    public let logFile: String
    public let createdMountPoint: Bool
    public let mountedAt: Date

    public init(
        source: String,
        bsdName: String?,
        wholeDiskBSDName: String?,
        mountPoint: String,
        fileSystem: FileSystemKind,
        engine: String,
        enginePath: String,
        pid: Int32,
        readOnly: Bool,
        volumeName: String,
        logFile: String,
        createdMountPoint: Bool,
        mountedAt: Date = Date()
    ) {
        self.source = source
        self.bsdName = bsdName
        self.wholeDiskBSDName = wholeDiskBSDName
        self.mountPoint = mountPoint
        self.fileSystem = fileSystem
        self.engine = engine
        self.enginePath = enginePath
        self.pid = pid
        self.readOnly = readOnly
        self.volumeName = volumeName
        self.logFile = logFile
        self.createdMountPoint = createdMountPoint
        self.mountedAt = mountedAt
    }
}
