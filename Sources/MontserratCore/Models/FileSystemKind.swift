import Foundation

public enum FileSystemKind: String, Codable, Sendable, CaseIterable {
    // Primary Read-Write Filesystems
    case ext2
    case ext3
    case ext4
    case ntfs
    case xfs
    case btrfs

    // Read-Only Mountable Filesystems (Upstream FUSE or legacyfs)
    case reiserfs
    case minix
    case cramfs
    case romfs
    case iso9660
    case squashfs
    case erofs
    case ufs
    case jfs
    case sysv
    case udf

    // Superblock Detection-Only Filesystems
    case f2fs
    case reiser4
    case nilfs2
    case gfs2
    case ocfs2
    case bcachefs
    case befs
    case hpfs
    case affs
    case hfs
    case refs
    case wbfs
    case fatx
    case qnx4
    case qnx6
    case jffs2
    case ubifs

    // Storage Pools, Encrypted Volumes, and Volume Managers
    case zfs
    case vmfs
    case luks1
    case luks2
    case lvm2
    case linuxRaid
    case linuxSwap

    // Native macOS-Handled Filesystems
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
        case .ntfs: return "NTFS"
        case .reiserfs: return "ReiserFS"
        case .minix: return "Minix"
        case .cramfs: return "CramFS"
        case .romfs: return "ROMFS"
        case .iso9660: return "ISO9660"
        case .squashfs: return "SquashFS"
        case .erofs: return "EROFS"
        case .ufs: return "UFS/UFS2"
        case .jfs: return "JFS"
        case .sysv: return "SysV"
        case .btrfs: return "Btrfs"
        case .xfs: return "XFS"
        case .f2fs: return "F2FS"
        case .reiser4: return "Reiser4"
        case .nilfs2: return "NILFS2"
        case .gfs2: return "GFS2"
        case .ocfs2: return "OCFS2"
        case .bcachefs: return "BCacheFS"
        case .befs: return "BeFS"
        case .hpfs: return "HPFS"
        case .affs: return "Amiga FFS"
        case .hfs: return "Classic HFS"
        case .udf: return "UDF"
        case .refs: return "ReFS"
        case .wbfs: return "WBFS"
        case .fatx: return "FATX"
        case .qnx4: return "QNX4"
        case .qnx6: return "QNX6"
        case .jffs2: return "JFFS2"
        case .ubifs: return "UBIFS"
        case .zfs: return "ZFS"
        case .vmfs: return "VMFS"
        case .luks1: return "LUKS1"
        case .luks2: return "LUKS2"
        case .lvm2: return "LVM2"
        case .linuxRaid: return "Linux RAID"
        case .linuxSwap: return "Linux Swap"
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

    public var isCowFS: Bool {
        switch self {
        case .xfs, .btrfs: return true
        default: return false
        }
    }

    /// True only for filesystems with compiled read-write mount, check, and format engines.
    public var isSupportedByMontserrat: Bool {
        switch self {
        case .ext2, .ext3, .ext4, .ntfs, .xfs, .btrfs:
            return true
        default:
            return false
        }
    }

    /// True for legacy and archival filesystems supported in read-only mode via upstream FUSE or legacyfs.
    public var isReadOnlySupported: Bool {
        switch self {
        case .reiserfs, .minix, .cramfs, .romfs, .iso9660, .squashfs, .erofs, .ufs, .jfs, .sysv, .udf:
            return true
        default:
            return false
        }
    }

    /// True for any filesystem Montserrat can mount (either read-write or read-only).
    public var isMountableByMontserrat: Bool {
        isSupportedByMontserrat || isReadOnlySupported
    }

    /// True for encrypted or pooled containers with guided unlock/activation workflows in Montserrat.
    public var isGuidedContainer: Bool {
        switch self {
        case .luks1, .luks2, .lvm2:
            return true
        default:
            return false
        }
    }

    /// True for volume managers, RAID members, swap partitions, and encrypted containers.
    public var isContainer: Bool {
        switch self {
        case .zfs, .vmfs, .luks1, .luks2, .lvm2, .linuxRaid, .linuxSwap:
            return true
        default:
            return false
        }
    }

    /// True for filesystems and containers that Montserrat probes and identifies at the superblock level
    /// without attempting to mount directly as a raw filesystem.
    public var isDetectionOnly: Bool {
        switch self {
        case .f2fs, .reiser4, .nilfs2, .gfs2, .ocfs2, .bcachefs,
             .befs, .hpfs, .affs, .hfs, .refs, .wbfs, .fatx, .qnx4, .qnx6,
             .jffs2, .ubifs, .zfs, .vmfs, .luks1, .luks2, .lvm2, .linuxRaid, .linuxSwap:
            return true
        default:
            return false
        }
    }

    /// Ordered FUSE engine binary candidates: active user-space read-write or upstream FUSE tools are preferred,
    /// falling back to `fuse-*` / `legacyfs-mount`.
    public var engineCandidates: [String] {
        switch self {
        case .ext2, .ext3, .ext4:
            return ["fuse2fs"]
        case .ntfs:
            return ["ntfs-3g"]
        case .xfs:
            return ["xfsfuse", "fuse-xfs", "legacyfs-mount"]
        case .btrfs:
            return ["btrfsfuse", "fuse-btrfs", "legacyfs-mount"]
        case .squashfs:
            return ["squashfuse", "fuse-squashfs", "legacyfs-mount"]
        case .erofs:
            return ["erofsfuse", "fuse-erofs", "legacyfs-mount"]
        case .iso9660:
            return ["fuseiso", "fuse-iso9660", "legacyfs-mount"]
        case .udf:
            return ["fuse-udf", "legacyfs-mount"]
        case .reiserfs:
            return ["fuse-reiserfs", "legacyfs-mount"]
        case .minix:
            return ["fuse-minix", "legacyfs-mount"]
        case .cramfs:
            return ["fuse-cramfs", "legacyfs-mount"]
        case .romfs:
            return ["fuse-romfs", "legacyfs-mount"]
        case .ufs:
            return ["fuse-ufs", "legacyfs-mount"]
        case .jfs:
            return ["fuse-jfs", "legacyfs-mount"]
        case .sysv:
            return ["fuse-sysv", "legacyfs-mount"]
        default:
            return []
        }
    }

    public var defaultEngineName: String? {
        engineCandidates.first
    }

    /// True if native Apple FSKit extension `MontserratFSKit` can mount this filesystem directly on macOS 15.4+.
    public var isFSKitCapable: Bool {
        isExt || isCowFS || isReadOnlySupported
    }

    /// Explicit `-t <format>` argument when invoking `legacyfs-mount`.
    public var legacyFSFormatFlag: String? {
        switch self {
        case .reiserfs: return "reiserfs"
        case .minix: return "minix"
        case .cramfs: return "cramfs"
        case .romfs: return "romfs"
        case .iso9660: return "iso9660"
        case .squashfs: return "squashfs"
        case .erofs: return "erofs"
        case .ufs: return "ufs"
        case .jfs: return "jfs"
        case .sysv: return "sysv"
        case .btrfs: return "btrfs"
        case .xfs: return "xfs"
        case .udf: return "udf"
        default: return nil
        }
    }
}
