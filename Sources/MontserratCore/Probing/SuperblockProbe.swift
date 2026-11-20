import Foundation
import Darwin

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

public struct DeviceReader {
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

        // 6. Secondary scan: Fall back to searching for ext backup superblocks
        // if no other filesystem primary boot signature was recognized
        if let extBackupResult = probeExtBackup(reader: reader) {
            return extBackupResult
        }

        return nil
    }

    // MARK: - ext2/3/4 Primary Probe
    private static func probeExtPrimary(reader: DeviceReader) -> ProbeResult? {
        if let data = reader.readBytes(offset: 1024, length: 1024), data.count >= 1024 {
            let magic = UInt16(data[56]) | (UInt16(data[57]) << 8)
            if magic == 0xEF53 {
                return parseExtSuperblock(data: data, backupBlock: nil)
            }
        }
        return nil
    }

    // MARK: - ext2/3/4 Backup Superblock Fallback Probe
    private static func probeExtBackup(reader: DeviceReader) -> ProbeResult? {
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
    private static func probeBtrfs(reader: DeviceReader) -> ProbeResult? {
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
    private static func probeXFS(reader: DeviceReader) -> ProbeResult? {
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
    private static func probeF2FS(reader: DeviceReader) -> ProbeResult? {
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
    private static func probeVBR(reader: DeviceReader) -> ProbeResult? {
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
