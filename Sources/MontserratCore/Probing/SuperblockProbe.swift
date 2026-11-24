import Foundation
import Darwin
import CLegacyFS

public struct ProbeResult: Sendable {
    public let fileSystem: FileSystemKind
    public let state: FileSystemState
    public let label: String?
    public let uuid: String?
    public let backupSuperblockBlock: UInt64?

    public init(
        fileSystem: FileSystemKind,
        state: FileSystemState = .unknown,
        label: String? = nil,
        uuid: String? = nil,
        backupSuperblockBlock: UInt64? = nil
    ) {
        self.fileSystem = fileSystem
        self.state = state
        self.label = label
        self.uuid = uuid
        self.backupSuperblockBlock = backupSuperblockBlock
    }
}

public protocol SuperblockReadable {
    func readBytes(offset: UInt64, length: Int) -> Data?
}

public struct DeviceReader: SuperblockReadable {
    private let fd: Int32

    public init?(path: String) {
        var openFd = Darwin.open(path, O_RDONLY)
        if openFd < 0 {
            let altPath: String
            if path.contains("/dev/rdisk") {
                altPath = path.replacingOccurrences(of: "/dev/rdisk", with: "/dev/disk")
            } else if path.contains("/dev/disk") {
                altPath = path.replacingOccurrences(of: "/dev/disk", with: "/dev/rdisk")
            } else {
                return nil
            }
            openFd = Darwin.open(altPath, O_RDONLY)
        }
        if openFd < 0 {
            return nil
        }
        self.fd = openFd
    }

    public func close() {
        Darwin.close(fd)
    }

    public func readBytes(offset: UInt64, length: Int) -> Data? {
        var buffer = [UInt8](repeating: 0, count: length)
        let bytesRead = Darwin.pread(fd, &buffer, length, off_t(offset))
        if bytesRead <= 0 {
            return nil
        }
        return Data(buffer.prefix(bytesRead))
    }
}

public enum SuperblockProbe {
    /// Probes the raw device or disk image file for known filesystem superblocks
    public static func probe(path: String) -> ProbeResult? {
        guard let reader = DeviceReader(path: path) else {
            return nil
        }
        defer { reader.close() }
        return probe(reader: reader)
    }

    /// Probes any byte-readable source (file descriptor, disk image, or FSKit block device resource).
    public static func probe(reader: any SuperblockReadable) -> ProbeResult? {
        // 1. Probe primary ext2/3/4 at offset 1024
        if let extResult = probeExtPrimary(reader: reader) {
            return extResult
        }

        // 2. Probe Btrfs at offset 64 KiB (65536)
        if let btrfsResult = probeBtrfs(reader: reader) {
            return btrfsResult
        }

        // 3. Probe XFS at offset 0
        if let xfsResult = probeXFS(reader: reader) {
            return xfsResult
        }

        // 4. Probe F2FS at offset 1024
        if let f2fsResult = probeF2FS(reader: reader) {
            return f2fsResult
        }

        // 5. Probe NTFS / ExFAT at sector 0
        if let fatNtfsResult = probeVBR(reader: reader) {
            return fatNtfsResult
        }

        // 6. Probe legacy, archival, embedded filesystems, and storage containers via CLegacyFS
        if let legacyResult = probeLegacyFS(reader: reader) {
            return legacyResult
        }

        // 7. Secondary scan: Fall back to searching for ext backup superblocks
        // if no other filesystem primary boot signature was recognized
        if let extBackupResult = probeExtBackup(reader: reader) {
            return extBackupResult
        }

        return nil
    }

    // MARK: - ext2/3/4 Primary Probe
    private static func probeExtPrimary(reader: any SuperblockReadable) -> ProbeResult? {
        if let data = reader.readBytes(offset: 1024, length: 1024), data.count >= 1024 {
            let magic = UInt16(data[56]) | (UInt16(data[57]) << 8)
            if magic == 0xEF53 {
                return parseExtSuperblock(data: data, backupBlock: nil)
            }
        }
        return nil
    }

    // MARK: - ext2/3/4 Backup Superblock Fallback Probe
    private static func probeExtBackup(reader: any SuperblockReadable) -> ProbeResult? {
        let backupOffsets: [(offset: UInt64, block: UInt64)] = [
            (33554432, 8192),
            (134217728, 32768),
            (402653184, 98304),
            (8389632, 8193)
        ]

        for candidate in backupOffsets {
            if let bData = reader.readBytes(offset: candidate.offset, length: 1024), bData.count >= 1024 {
                let bMagic = UInt16(bData[56]) | (UInt16(bData[57]) << 8)
                if bMagic == 0xEF53 {
                    return parseExtSuperblock(data: bData, backupBlock: candidate.block)
                }
            }
        }

        return nil
    }

    private static func parseExtSuperblock(data: Data, backupBlock: UInt64?) -> ProbeResult {
        // State at offset 0x3A (58 dec): 1 = clean, 2 = errors
        let rawState = UInt16(data[58]) | (UInt16(data[59]) << 8)

        // Feature compat (0x5C) and incompat (0x60)
        let compat = UInt32(data[92]) | (UInt32(data[93]) << 8) | (UInt32(data[94]) << 16) | (UInt32(data[95]) << 24)
        let incompat = UInt32(data[96]) | (UInt32(data[97]) << 8) | (UInt32(data[98]) << 16) | (UInt32(data[99]) << 24)

        // Check journal recovery flag: EXT3_FEATURE_INCOMPAT_RECOVER (0x0004)
        var state: FileSystemState = .clean
        if backupBlock != nil {
            state = .backupSuperblockRecoverable
        } else if (incompat & 0x0004) != 0 {
            state = .needsRecovery
        } else if rawState != 1 {
            state = .needsCheck
        }

        // Determine ext2 vs ext3 vs ext4
        let fsKind: FileSystemKind
        if (incompat & (0x0040 | 0x0080 | 0x0200)) != 0 {
            fsKind = .ext4
        } else if (compat & 0x0004) != 0 {
            fsKind = .ext3
        } else {
            fsKind = .ext2
        }

        // UUID: 16 bytes at 0x68 (104 dec)
        let uuidData = data.subdata(in: 104..<120)
        let uuidString = formatUUID(uuidData)

        // Volume label: 16 bytes at 0x78 (120 dec)
        let labelData = data.subdata(in: 120..<136)
        let label = extractString(from: labelData)

        return ProbeResult(
            fileSystem: fsKind,
            state: state,
            label: label.isEmpty ? nil : label,
            uuid: uuidString,
            backupSuperblockBlock: backupBlock
        )
    }

    // MARK: - Btrfs Probe
    private static func probeBtrfs(reader: any SuperblockReadable) -> ProbeResult? {
        guard let data = reader.readBytes(offset: 65536, length: 4096), data.count >= 4096 else {
            return nil
        }

        // Magic: "_BHRfS_M" at offset 0x40 (64 dec)
        let magicData = data.subdata(in: 64..<72)
        guard let magicStr = String(data: magicData, encoding: .ascii), magicStr == "_BHRfS_M" else {
            return nil
        }

        // UUID: 16 bytes at offset 0x20 (32 dec)
        let uuidData = data.subdata(in: 32..<48)
        let uuidString = formatUUID(uuidData)

        // Label: 256 bytes at offset 0x12B (299 dec)
        let labelData = data.subdata(in: 299..<555)
        let label = extractString(from: labelData)

        return ProbeResult(
            fileSystem: .btrfs,
            state: .clean,
            label: label.isEmpty ? nil : label,
            uuid: uuidString
        )
    }

    // MARK: - XFS Probe
    private static func probeXFS(reader: any SuperblockReadable) -> ProbeResult? {
        guard let data = reader.readBytes(offset: 0, length: 512), data.count >= 512 else {
            return nil
        }

        // Magic: "XFSB" at offset 0
        let magic = String(data: data.subdata(in: 0..<4), encoding: .ascii)
        guard magic == "XFSB" else { return nil }

        // UUID: 16 bytes at offset 32
        let uuidData = data.subdata(in: 32..<48)
        let uuidString = formatUUID(uuidData)

        // Label: 12 bytes at offset 108
        let labelData = data.subdata(in: 108..<120)
        let label = extractString(from: labelData)

        return ProbeResult(
            fileSystem: .xfs,
            state: .clean,
            label: label.isEmpty ? nil : label,
            uuid: uuidString
        )
    }

    // MARK: - F2FS Probe
    private static func probeF2FS(reader: any SuperblockReadable) -> ProbeResult? {
        guard let data = reader.readBytes(offset: 1024, length: 512), data.count >= 512 else {
            return nil
        }

        // Magic at offset 0: 0xF2F52010 (little endian: 0x10, 0x20, 0xF5, 0xF2)
        if data[0] == 0x10 && data[1] == 0x20 && data[2] == 0xF5 && data[3] == 0xF2 {
            return ProbeResult(fileSystem: .f2fs, state: .clean)
        }
        return nil
    }

    // MARK: - Volume Boot Record (NTFS, ExFAT, FAT)
    private static func probeVBR(reader: any SuperblockReadable) -> ProbeResult? {
        guard let data = reader.readBytes(offset: 0, length: 512), data.count >= 512 else {
            return nil
        }

        // Check NTFS: offset 3 has "NTFS    "
        if let oem = String(data: data.subdata(in: 3..<11), encoding: .ascii), oem.hasPrefix("NTFS") {
            return ProbeResult(fileSystem: .ntfs, state: .clean)
        }

        // Check ExFAT: offset 3 has "EXFAT   "
        if let oem = String(data: data.subdata(in: 3..<11), encoding: .ascii), oem.hasPrefix("EXFAT") {
            return ProbeResult(fileSystem: .exfat, state: .clean)
        }

        return nil
    }

    // MARK: - CLegacyFS Multi-Format Superblock and Container Probe
    private final class LegacyProbeReaderBox {
        let reader: any SuperblockReadable
        init(reader: any SuperblockReadable) {
            self.reader = reader
        }
    }

    private static func probeLegacyFS(reader: any SuperblockReadable) -> ProbeResult? {
        let box = LegacyProbeReaderBox(reader: reader)
        let ctxPtr = Unmanaged.passUnretained(box).toOpaque()

        let readCallback: legacyfs_read_fn = { rawCtx, offset, length, buffer in
            guard let rawCtx, let buffer else { return EINVAL }
            if length == 0 { return 0 }
            let holder = Unmanaged<LegacyProbeReaderBox>.fromOpaque(rawCtx).takeUnretainedValue()
            guard let data = holder.reader.readBytes(offset: offset, length: length),
                  data.count == length else {
                return EIO
            }
            data.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: length)
            return 0
        }

        var info = legacyfs_probe_info_t()
        let rc = legacyfs_probe_io(readCallback, ctxPtr, 0, &info)
        guard rc == 0 else { return nil }

        guard let fsKind = mapLegacyKind(info.kind) else { return nil }
        let label = withUnsafeBytes(of: info.label) { rawBuf -> String in
            let prefix = rawBuf.prefix(while: { $0 != 0 })
            return String(decoding: prefix, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let uuid = withUnsafeBytes(of: info.uuid) { rawBuf -> String in
            let prefix = rawBuf.prefix(while: { $0 != 0 })
            return String(decoding: prefix, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let state: FileSystemState = (info.needs_recovery != 0) ? .needsRecovery : .clean
        return ProbeResult(
            fileSystem: fsKind,
            state: state,
            label: label.isEmpty ? nil : label,
            uuid: uuid.isEmpty ? nil : uuid
        )
    }

    private static func mapLegacyKind(_ kind: legacyfs_kind_t) -> FileSystemKind? {
        switch kind {
        case LEGACYFS_KIND_REISERFS: return .reiserfs
        case LEGACYFS_KIND_MINIX: return .minix
        case LEGACYFS_KIND_CRAMFS: return .cramfs
        case LEGACYFS_KIND_ROMFS: return .romfs
        case LEGACYFS_KIND_ISO9660: return .iso9660
        case LEGACYFS_KIND_SQUASHFS: return .squashfs
        case LEGACYFS_KIND_EROFS: return .erofs
        case LEGACYFS_KIND_UFS: return .ufs
        case LEGACYFS_KIND_JFS: return .jfs
        case LEGACYFS_KIND_SYSV: return .sysv
        case LEGACYFS_KIND_REISER4: return .reiser4
        case LEGACYFS_KIND_BTRFS: return .btrfs
        case LEGACYFS_KIND_XFS: return .xfs
        case LEGACYFS_KIND_F2FS: return .f2fs
        case LEGACYFS_KIND_NILFS2: return .nilfs2
        case LEGACYFS_KIND_ZFS: return .zfs
        case LEGACYFS_KIND_GFS2: return .gfs2
        case LEGACYFS_KIND_OCFS2: return .ocfs2
        case LEGACYFS_KIND_BCACHEFS: return .bcachefs
        case LEGACYFS_KIND_BEFS: return .befs
        case LEGACYFS_KIND_HPFS: return .hpfs
        case LEGACYFS_KIND_AFFS: return .affs
        case LEGACYFS_KIND_HFS: return .hfs
        case LEGACYFS_KIND_UDF: return .udf
        case LEGACYFS_KIND_VMFS: return .vmfs
        case LEGACYFS_KIND_REFS: return .refs
        case LEGACYFS_KIND_WBFS: return .wbfs
        case LEGACYFS_KIND_FATX: return .fatx
        case LEGACYFS_KIND_QNX4: return .qnx4
        case LEGACYFS_KIND_QNX6: return .qnx6
        case LEGACYFS_KIND_JFFS2: return .jffs2
        case LEGACYFS_KIND_UBIFS: return .ubifs
        case LEGACYFS_KIND_LUKS1: return .luks1
        case LEGACYFS_KIND_LUKS2: return .luks2
        case LEGACYFS_KIND_LVM2: return .lvm2
        case LEGACYFS_KIND_LINUX_RAID: return .linuxRaid
        case LEGACYFS_KIND_LINUX_SWAP: return .linuxSwap
        default: return nil
        }
    }

    // MARK: - Helpers
    private static func formatUUID(_ data: Data) -> String {
        guard data.count == 16 else { return "" }
        return String(format: "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
                      data[0], data[1], data[2], data[3],
                      data[4], data[5],
                      data[6], data[7],
                      data[8], data[9],
                      data[10], data[11], data[12], data[13], data[14], data[15])
    }

    private static func extractString(from data: Data) -> String {
        let nullTerminated = data.prefix(while: { $0 != 0 })
        return String(data: nullTerminated, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
