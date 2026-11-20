import Foundation

public enum FileSystemKind: String, Codable, Sendable, CaseIterable {
    case ext2
    case ext3
    case ext4
    case btrfs
    case xfs
    case f2fs
    case ntfs
    case fat12
    case fat16
    case fat32
    case exfat
    case apfs
    case hfsplus
    case unknown

    public var displayName: String {
        switch self {
        case .ext2: return "ext2"
        case .ext3: return "ext3"
        case .ext4: return "ext4"
        case .btrfs: return "Btrfs"
        case .xfs: return "XFS"
        case .f2fs: return "F2FS"
        case .ntfs: return "NTFS"
        case .fat12: return "FAT12"
        case .fat16: return "FAT16"
        case .fat32: return "FAT32"
        case .exfat: return "exFAT"
        case .apfs: return "APFS"
        case .hfsplus: return "HFS+"
        case .unknown: return "Unknown"
        }
    }

    public var isExt: Bool {
        switch self {
        case .ext2, .ext3, .ext4: return true
        default: return false
        }
    }

    public var isSupportedByMontserrat: Bool {
        switch self {
        case .ext2, .ext3, .ext4, .ntfs, .btrfs, .xfs, .f2fs:
            return true
        default:
            return false
        }
    }

    public var defaultEngineName: String? {
        switch self {
        case .ext2, .ext3, .ext4:
            return "fuse2fs"
        case .ntfs:
            return "ntfs-3g"
        case .btrfs:
            return "btrfs-fuse"
        case .xfs:
            return "xfs-fuse"
        case .f2fs:
            return "f2fs-fuse"
        default:
            return nil
        }
    }
}
