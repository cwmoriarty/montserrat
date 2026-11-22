import Foundation

public struct FileSystemInfo: Codable, Sendable, Equatable {
    public let kind: FileSystemKind
    public let label: String?
    public let uuid: String?
    public let state: FileSystemState
    public let isVerified: Bool

    public init(
        kind: FileSystemKind,
        label: String? = nil,
        uuid: String? = nil,
        state: FileSystemState = .unknown,
        isVerified: Bool = false
    ) {
        self.kind = kind
        self.label = label
        self.uuid = uuid
        self.state = state
        self.isVerified = isVerified
    }
}

public struct VolumeInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String { bsdName }
    public let bsdName: String
    public let wholeDiskBSDName: String
    public let size: UInt64
    public let partitionType: String?
    public let partitionUUID: String?
    public var fileSystem: FileSystemInfo
    public var systemMountPoint: String?
    public var montserratMountPoint: String?

    public var isMounted: Bool {
        if let sys = systemMountPoint?.trimmingCharacters(in: .whitespacesAndNewlines), !sys.isEmpty {
            return true
        }
        if let mont = montserratMountPoint?.trimmingCharacters(in: .whitespacesAndNewlines), !mont.isEmpty {
            return true
        }
        return false
    }

    public var effectiveMountPoint: String? {
        if let mont = montserratMountPoint?.trimmingCharacters(in: .whitespacesAndNewlines), !mont.isEmpty {
            return mont
        }
        if let sys = systemMountPoint?.trimmingCharacters(in: .whitespacesAndNewlines), !sys.isEmpty {
            return sys
        }
        return nil
    }

    public init(
        bsdName: String,
        wholeDiskBSDName: String,
        size: UInt64,
        partitionType: String? = nil,
        partitionUUID: String? = nil,
        fileSystem: FileSystemInfo,
        systemMountPoint: String? = nil,
        montserratMountPoint: String? = nil
    ) {
        self.bsdName = bsdName
        self.wholeDiskBSDName = wholeDiskBSDName
        self.size = size
        self.partitionType = partitionType
        self.partitionUUID = partitionUUID
        self.fileSystem = fileSystem
        self.systemMountPoint = systemMountPoint
        self.montserratMountPoint = montserratMountPoint
    }
}

public struct DiskInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String { bsdName }
    public let bsdName: String
    public let size: UInt64
    public let name: String
    public let connection: String?
    public let isInternal: Bool
    public let isRemovable: Bool
    public let isEjectable: Bool
    public let isDiskImage: Bool
    public let isProtected: Bool
    public var volumes: [VolumeInfo]

    public init(
        bsdName: String,
        size: UInt64,
        name: String,
        connection: String? = nil,
        isInternal: Bool,
        isRemovable: Bool,
        isEjectable: Bool,
        isDiskImage: Bool,
        isProtected: Bool = false,
        volumes: [VolumeInfo] = []
    ) {
        self.bsdName = bsdName
        self.size = size
        self.name = name
        self.connection = connection
        self.isInternal = isInternal
        self.isRemovable = isRemovable
        self.isEjectable = isEjectable
        self.isDiskImage = isDiskImage
        self.isProtected = isProtected
        self.volumes = volumes
    }
}
