import Testing
import Foundation
#if canImport(Darwin)
import Darwin
#endif
import CLegacyFS
import CAppleExplorer
import CCowFS
import CommonCrypto
@testable import MontserratCore
@testable import MontserratFSKit

@Suite("Montserrat Core and Filesystem Engine Tests")
struct MontserratCoreTests {

    @Test("Verify FileSystemKind support and detection-only classification")
    func testFileSystemKind() {
        #expect(FileSystemKind.ext4.isExt)
        #expect(FileSystemKind.ext3.isExt)
        #expect(FileSystemKind.ext2.isExt)
        #expect(!FileSystemKind.btrfs.isExt)
        #expect(!FileSystemKind.xfs.isExt)
        #expect(!FileSystemKind.f2fs.isExt)

        // Production read-write engine support (ext2/3/4, NTFS, XFS, Btrfs)
        #expect(FileSystemKind.ext4.isSupportedByMontserrat)
        #expect(FileSystemKind.ext3.isSupportedByMontserrat)
        #expect(FileSystemKind.ext2.isSupportedByMontserrat)
        #expect(FileSystemKind.ntfs.isSupportedByMontserrat)
        #expect(FileSystemKind.xfs.isSupportedByMontserrat)
        #expect(FileSystemKind.btrfs.isSupportedByMontserrat)
        #expect(FileSystemKind.xfs.isFSKitCapable)
        #expect(FileSystemKind.btrfs.isFSKitCapable)
        #expect(FileSystemKind.udf.isReadOnlySupported)
        #expect(FileSystemKind.udf.isFSKitCapable)

        // Detection-only filesystems must not be marked as mount-supported
        #expect(!FileSystemKind.f2fs.isSupportedByMontserrat)
        #expect(!FileSystemKind.btrfs.isDetectionOnly)
        #expect(!FileSystemKind.xfs.isDetectionOnly)
        #expect(!FileSystemKind.udf.isDetectionOnly)
        #expect(FileSystemKind.f2fs.isDetectionOnly)

        #expect(FileSystemKind.ext4.defaultEngineName == "fuse2fs")
        #expect(FileSystemKind.ntfs.defaultEngineName == "ntfs-3g")
        #expect(FileSystemKind.btrfs.defaultEngineName == "btrfsfuse")
        #expect(FileSystemKind.xfs.defaultEngineName == "xfsfuse")
        #expect(FileSystemKind.udf.defaultEngineName == "fuse-udf")
        #expect(FileSystemKind.hfs.isReadOnlySupported)
        #expect(FileSystemKind.hfs.isFSKitCapable)
        #expect(FileSystemKind.hfs.defaultEngineName == "apple-explorer-mount")
        #expect(FileSystemKind.linuxRaid.isGuidedContainer)
        #expect(FileSystemKind.f2fs.defaultEngineName == nil)
    }

    @Test("Verify Safety Policy protects internal disks and synthesized APFS containers")
    func testInternalDiskAndSynthesizedAPFSProtection() {
        let internalDisk = DiskInfo(
            bsdName: "disk0",
            size: 1000000000000,
            name: "APPLE SSD AP1024Z",
            connection: "PCI-Express",
            isInternal: true,
            isRemovable: false,
            isEjectable: false,
            isDiskImage: false,
            isProtected: true
        )

        #expect(throws: MontserratError.self) {
            try SafetyPolicy.validate(disk: internalDisk)
        }

        // Apple Silicon synthesized APFS container (disk3) has isInternal=true even if virtual
        let synthesizedApfsContainer = DiskInfo(
            bsdName: "disk3",
            size: 1000000000000,
            name: "AppleAPFSMedia",
            connection: "Virtual Interface",
            isInternal: true,
            isRemovable: false,
            isEjectable: false,
            isDiskImage: true,
            isProtected: true
        )

        #expect(throws: MontserratError.self) {
            try SafetyPolicy.validate(disk: synthesizedApfsContainer)
        }

        // Protected partition type GUID check
        let externalDisk = DiskInfo(
            bsdName: "disk4",
            size: 64000000000,
            name: "External Drive",
            connection: "USB",
            isInternal: false,
            isRemovable: true,
            isEjectable: true,
            isDiskImage: false,
            isProtected: false
        )
        let efiVolume = VolumeInfo(
            bsdName: "disk4s1",
            wholeDiskBSDName: "disk4",
            size: 209715200,
            partitionType: "C12A7328-F81F-11D2-BA4B-00A0C93EC93B",
            partitionUUID: "11111111-2222-3333-4444-555555555555",
            fileSystem: FileSystemInfo(kind: .fat32)
        )

        #expect(throws: MontserratError.self) {
            try SafetyPolicy.validate(disk: externalDisk, volume: efiVolume)
        }

        // Token boundary check: disk1 is reserved, disk10 through disk19 are not
        #expect(SafetyPolicy.isReservedInternalDiskName("disk0"))
        #expect(SafetyPolicy.isReservedInternalDiskName("disk1"))
        #expect(SafetyPolicy.isReservedInternalDiskName("disk3s1"))
        #expect(!SafetyPolicy.isReservedInternalDiskName("disk10"))
        #expect(!SafetyPolicy.isReservedInternalDiskName("disk15"))
        #expect(!SafetyPolicy.isReservedInternalDiskName("disk15s1"))
    }

    @Test("Verify Safety Policy allows external disks")
    func testExternalDiskAllowed() {
        let externalDisk = DiskInfo(
            bsdName: "disk4",
            size: 64000000000,
            name: "SanDisk Ultra",
            connection: "USB",
            isInternal: false,
            isRemovable: true,
            isEjectable: true,
            isDiskImage: false,
            isProtected: false
        )

        #expect(throws: Never.self) {
            try SafetyPolicy.validate(disk: externalDisk)
        }
    }

    @Test("Verify proc_pidpath verification prevents signaling unrelated processes")
    func testProcessIdentityVerification() {
        let currentPid = getpid()
        // Current test runner process is not fuse2fs or ntfs-3g
        let isVerified = MountManager.isVerifiedEngineProcess(
            pid: currentPid,
            expectedEnginePath: "/usr/local/share/montserrat/engines/bin/fuse2fs",
            expectedEngineName: "fuse2fs"
        )
        #expect(isVerified == false)

        // PID 1 (launchd) must never be verified as an engine process
        let isPid1Verified = MountManager.isVerifiedEngineProcess(
            pid: 1,
            expectedEnginePath: "/usr/local/share/montserrat/engines/bin/fuse2fs",
            expectedEngineName: "fuse2fs"
        )
        #expect(isPid1Verified == false)
    }

    @Test("Verify Root Binary Security rejects world-writable and user-owned binaries")
    func testBinarySecurityValidation() throws {
        let tempBin = FileManager.default.temporaryDirectory.appendingPathComponent("test_bin_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempBin) }

        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: tempBin)

        // World-writable binary (0777) must always be rejected
        Darwin.chmod(tempBin.path, 0o777)
        #expect(EngineRegistry.isBinarySafeToExecute(atPath: tempBin.path, requireRootOwned: false) == false)

        // Owner-only executable (0755) is safe for non-root user execution
        Darwin.chmod(tempBin.path, 0o755)
        #expect(EngineRegistry.isBinarySafeToExecute(atPath: tempBin.path, requireRootOwned: false) == true)

        // When root ownership is required by daemon, a file in user temp dir must be rejected
        if geteuid() != 0 {
            #expect(EngineRegistry.isBinarySafeToExecute(atPath: tempBin.path, requireRootOwned: true) == false)
        }
    }

    @Test("Verify NFS export filtering removes sole export cleanly")
    func testNFSExportFiltering() {
        let singleLine = "\"/Volumes/LinuxData\" -maproot=nobody -ro 127.0.0.1\n"
        let filtered = NFSShareTool.filterExports(content: singleLine, removingMountPoint: "/Volumes/LinuxData")
        #expect(filtered.isEmpty)

        let multiLine = """
        "/Volumes/First" -maproot=nobody -ro 127.0.0.1
        "/Volumes/Second" -maproot=nobody -ro 192.168.1.0
        """
        let remaining = NFSShareTool.filterExports(content: multiLine, removingMountPoint: "/Volumes/First")
        #expect(!remaining.contains("/Volumes/First"))
        #expect(remaining.contains("/Volumes/Second"))
    }

    @Test("Verify ext4 Superblock Parsing from synthetic byte buffer")
    func testExt4SuperblockParsing() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".img")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        var buffer = Data(repeating: 0, count: 4096)
        buffer[1080] = 0x53
        buffer[1081] = 0xEF
        buffer[1082] = 0x01
        buffer[1083] = 0x00
        buffer[1120] = 0x40
        buffer[1121] = 0x00
        buffer[1122] = 0x00
        buffer[1123] = 0x00
        let labelData = "TEST_EXT4".data(using: .utf8)!
        buffer.replaceSubrange(1144..<(1144 + labelData.count), with: labelData)

        try buffer.write(to: tempURL)

        let probeResult = SuperblockProbe.probe(path: tempURL.path)
        #expect(probeResult != nil)
        #expect(probeResult?.fileSystem == .ext4)
        #expect(probeResult?.state == .clean)
        #expect(probeResult?.label == "TEST_EXT4")
    }

    @Test("Verify Backup Superblock Auto-Recovery on Corrupted Primary")
    func testBackupSuperblockRecovery() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".img")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let totalSize = 8389632 + 2048
        var buffer = Data(repeating: 0, count: totalSize)

        let sbOffset = 8389632
        buffer[sbOffset + 56] = 0x53
        buffer[sbOffset + 57] = 0xEF
        buffer[sbOffset + 58] = 0x01
        buffer[sbOffset + 59] = 0x00
        buffer[sbOffset + 96] = 0x40

        let labelData = "RECOVERED_EXT4".data(using: .utf8)!
        buffer.replaceSubrange((sbOffset + 120)..<(sbOffset + 120 + labelData.count), with: labelData)

        try buffer.write(to: tempURL)

        let probeResult = SuperblockProbe.probe(path: tempURL.path)
        #expect(probeResult != nil)
        #expect(probeResult?.fileSystem == .ext4)
        #expect(probeResult?.state == .backupSuperblockRecoverable)
        #expect(probeResult?.backupSuperblockBlock == 8193)
        #expect(probeResult?.label == "RECOVERED_EXT4")
    }

    @Test("Verify Btrfs Superblock Probing")
    func testBtrfsSuperblockProbing() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".img")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let totalSize = 65536 + 4096
        var buffer = Data(repeating: 0, count: totalSize)

        let magic = "_BHRfS_M".data(using: .ascii)!
        buffer.replaceSubrange((65536 + 64)..<(65536 + 72), with: magic)

        let label = "BTRFS_VOL".data(using: .utf8)!
        buffer.replaceSubrange((65536 + 299)..<(65536 + 299 + label.count), with: label)

        try buffer.write(to: tempURL)

        let probeResult = SuperblockProbe.probe(path: tempURL.path)
        #expect(probeResult != nil)
        #expect(probeResult?.fileSystem == .btrfs)
        #expect(probeResult?.state == .clean)
        #expect(probeResult?.label == "BTRFS_VOL")
    }

    @Test("Verify XFS Superblock Probing")
    func testXFSSuperblockProbing() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".img")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        var buffer = Data(repeating: 0, count: 2048)
        let magic = "XFSB".data(using: .ascii)!
        buffer.replaceSubrange(0..<4, with: magic)

        let label = "XFS_DATA".data(using: .utf8)!
        buffer.replaceSubrange(108..<(108 + label.count), with: label)

        try buffer.write(to: tempURL)

        let probeResult = SuperblockProbe.probe(path: tempURL.path)
        #expect(probeResult != nil)
        #expect(probeResult?.fileSystem == .xfs)
        #expect(probeResult?.state == .clean)
        #expect(probeResult?.label == "XFS_DATA")
    }

    @Test("Verify F2FS Superblock Probing")
    func testF2FSSuperblockProbing() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".img")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        var buffer = Data(repeating: 0, count: 4096)
        buffer[1024] = 0x10
        buffer[1025] = 0x20
        buffer[1026] = 0xF5
        buffer[1027] = 0xF2

        try buffer.write(to: tempURL)

        let probeResult = SuperblockProbe.probe(path: tempURL.path)
        #expect(probeResult != nil)
        #expect(probeResult?.fileSystem == .f2fs)
        #expect(probeResult?.state == .clean)
    }

    @Test("Verify Device Disappearance and Unplug Signal Cleanup")
    func testDeviceDisappearanceCleanup() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manager = MountManager(stateDir: tempDir)
        manager.handleDeviceDisappeared(bsdName: "disk99s1")
        #expect(manager.activeMounts().isEmpty)
    }

    @Test("Verify Apple FSKit Framework Detection and Capabilities")
    func testFSKitFrameworkDetection() {
        let check = FSKitSupport.checkAvailability()
        let preferred = MontserratFSKitManager.shared.preferredEngine(for: "/dev/disk4s1")
        #if canImport(FSKit)
        if #available(macOS 15.4, *) {
            #expect(check.available == true)
            #expect(preferred == .fskit)
        } else {
            #expect(check.available == false)
            #expect(preferred == .fuseT)
        }
        #else
        #expect(check.available == false)
        #expect(preferred == .fuseT)
        #endif
    }

    @Test("Verify External Unmount Reconciliation and Cleanup without signaling unrelated PID")
    func testExternalUnmountReconciliation() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manager = MountManager(stateDir: tempDir)
        let mountDir = tempDir.appendingPathComponent("StaleMount", isDirectory: true)
        try? FileManager.default.createDirectory(at: mountDir, withIntermediateDirectories: true)

        // Use current test runner PID to verify reconcileActiveMounts checks proc_pidpath and does NOT kill us
        let record = MountRecord(
            source: "/dev/disk99s1",
            bsdName: "disk99s1",
            wholeDiskBSDName: "disk99",
            mountPoint: mountDir.path,
            fileSystem: .ext4,
            engine: "fuse2fs",
            enginePath: "/usr/local/share/montserrat/engines/bin/fuse2fs",
            pid: getpid(),
            readOnly: false,
            volumeName: "StaleMount",
            logFile: tempDir.appendingPathComponent("log.txt").path,
            createdMountPoint: true
        )

        let regFile = tempDir.appendingPathComponent("mounts.json")
        try? JSONEncoder().encode([record]).write(to: regFile)

        #expect(FileManager.default.fileExists(atPath: mountDir.path))
        manager.reconcileActiveMounts()

        #expect(!FileManager.default.fileExists(atPath: mountDir.path))
        #expect(manager.activeMounts().isEmpty)
    }

    @Test("Verify Notification Event formatting and dispatch")
    func testNotificationEvents() {
        let mounted = NotificationEventType.volumeMounted(
            volume: "disk4s1",
            fsKind: "ext4",
            mountPoint: "/Volumes/DATA"
        )
        #expect(mounted.title == "Volume Mounted")
        #expect(mounted.body.contains("disk4s1"))
        #expect(mounted.body.contains("/Volumes/DATA"))

        let unmounted = NotificationEventType.volumeUnmounted(volume: "disk4s1")
        #expect(unmounted.title == "Volume Unmounted")
        #expect(unmounted.body.contains("disk4s1"))

        let failed = NotificationEventType.mountFailed(volume: "disk4s1", error: "Device busy")
        #expect(failed.title == "Mount Failed")
        #expect(failed.body.contains("Device busy"))
    }

    @Test("Verify MountTable canonicalPath resolves macOS symlinks")
    func testMountTableCanonicalPath() throws {
        #expect(MountTable.canonicalPath("/var/tmp") == MountTable.canonicalPath("/private/var/tmp"))

        let baseDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDir) }

        let realDir = baseDir.appendingPathComponent("real", isDirectory: true)
        let linkDir = baseDir.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkDir, withDestinationURL: realDir)

        #expect(MountTable.canonicalPath(linkDir.path) == MountTable.canonicalPath(realDir.path))
    }

    @Test("Verify MountManager merges read-only daemon state without mutating it")
    func testMountManagerMergedReadOnlyRegistry() throws {
        let baseDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDir) }

        let userDir = baseDir.appendingPathComponent("user", isDirectory: true)
        let daemonDir = baseDir.appendingPathComponent("daemon", isDirectory: true)
        try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: daemonDir, withIntermediateDirectories: true)

        let daemonRecord = MountRecord(
            source: "/dev/disk98s1",
            bsdName: "disk98s1",
            wholeDiskBSDName: "disk98",
            mountPoint: "/Volumes/DaemonVol",
            fileSystem: .ext4,
            engine: "fuse2fs",
            enginePath: "/Library/Application Support/Montserrat/engines/bin/fuse2fs",
            pid: getpid(),
            readOnly: false,
            volumeName: "DaemonVol",
            logFile: daemonDir.appendingPathComponent("d.log").path,
            createdMountPoint: false
        )
        let daemonFile = daemonDir.appendingPathComponent("mounts.json")
        try JSONEncoder().encode([daemonRecord]).write(to: daemonFile)

        let manager = MountManager(stateDir: userDir, additionalReadOnlyStateDirs: [daemonDir])
        #expect(manager.allRecordedMounts().contains(where: { $0.id == daemonRecord.id }))

        // Non-root reconcile must NOT delete daemonDir/mounts.json or signal daemonRecord PID
        manager.reconcileActiveMounts()
        #expect(FileManager.default.fileExists(atPath: daemonFile.path))
        #expect(manager.allRecordedMounts().contains(where: { $0.id == daemonRecord.id }))
    }

    @Test("Verify PrivilegeManager shell argument escaping")
    func testPrivilegeManagerShellEscaping() {
        #expect(PrivilegeManager.escapeShellArgument("/tmp/a b") == "'/tmp/a b'")
        #expect(PrivilegeManager.escapeShellArgument("it's") == "'it'\\''s'")
    }

    @Test("Verify SuperblockProbe accepts custom SuperblockReadable source")
    func testSuperblockProbeCustomReadable() {
        struct MemoryReader: SuperblockReadable {
            let bytes: Data
            func readBytes(offset: UInt64, length: Int) -> Data? {
                let start = Int(offset)
                guard start < bytes.count else { return nil }
                let end = min(bytes.count, start + length)
                return bytes.subdata(in: start..<end)
            }
        }

        var buf = Data(repeating: 0, count: 4096)
        buf[1024 + 56] = 0x53
        buf[1024 + 57] = 0xEF
        buf[1024 + 58] = 0x01
        buf[1024 + 96] = 0x40
        let label = "MEM_EXT4".data(using: .utf8)!
        buf.replaceSubrange((1024 + 120)..<(1024 + 120 + label.count), with: label)

        let probed = SuperblockProbe.probe(reader: MemoryReader(bytes: buf))
        #expect(probed?.fileSystem == .ext4)
        #expect(probed?.label == "MEM_EXT4")
        #expect(probed?.state == .clean)
    }

    @Test("Verify CLegacyFS C library linkage and format registry")
    func testCLegacyFSLinkage() {
        #expect(montserrat_legacyfs_linked() == 1)
        let ver = String(cString: legacyfs_version())
        #expect(ver == "0.2.0")

        var tablePtr: UnsafePointer<legacyfs_format_desc_t>?
        let count = legacyfs_supported_formats(&tablePtr)
        #expect(count >= 37)
        #expect(tablePtr != nil)
        #expect(EngineRegistry.legacyFSDriverAliases.count == 13)
    }

    @Test("Verify read-only legacyfs tier, upstream-first engine candidates, and container flags")
    func testLegacyFSTierAndEnginePriority() {
        #expect(FileSystemKind.reiserfs.isReadOnlySupported)
        #expect(FileSystemKind.squashfs.isReadOnlySupported)
        #expect(FileSystemKind.ufs.isReadOnlySupported)
        #expect(FileSystemKind.jfs.isReadOnlySupported)
        #expect(!FileSystemKind.reiserfs.isSupportedByMontserrat)
        #expect(FileSystemKind.reiserfs.isMountableByMontserrat)

        // Upstream FUSE binary is preferred before falling back to legacyfs-mount
        #expect(FileSystemKind.squashfs.engineCandidates == ["squashfuse", "fuse-squashfs", "legacyfs-mount"])
        #expect(FileSystemKind.erofs.engineCandidates == ["erofsfuse", "fuse-erofs", "legacyfs-mount"])
        #expect(FileSystemKind.reiserfs.engineCandidates == ["fuse-reiserfs", "legacyfs-mount"])

        // Storage containers are identified without pretending to mount directly
        #expect(FileSystemKind.luks2.isContainer)
        #expect(FileSystemKind.lvm2.isContainer)
        #expect(FileSystemKind.zfs.isContainer)
        #expect(!FileSystemKind.luks2.isMountableByMontserrat)
    }

    @Test("Verify SuperblockProbe identifies ReiserFS, SquashFS, JFS, LUKS2, and LVM2")
    func testLegacyFSSuperblockProbing() throws {
        struct SliceReader: SuperblockReadable {
            let bytes: Data
            func readBytes(offset: UInt64, length: Int) -> Data? {
                let start = Int(offset)
                guard start + length <= bytes.count else { return nil }
                return bytes.subdata(in: start..<(start + length))
            }
        }

        // 1. ReiserFS 3.6 at 64 KiB
        var rfs = Data(repeating: 0, count: 131072)
        let sb = 65536
        // s_block_count = 32, s_free_blocks = 20, s_root_block = 18, s_blocksize = 4096
        rfs[sb + 0] = 32
        rfs[sb + 4] = 20
        rfs[sb + 8] = 18
        rfs[sb + 44] = 0x00; rfs[sb + 45] = 0x10 // 4096 LE16
        rfs.replaceSubrange((sb + 52)..<(sb + 61), with: Data("ReIsEr2Fs".utf8))
        rfs.replaceSubrange((sb + 100)..<(sb + 110), with: Data("OLD_LINUX\0".utf8))
        let rfsProbe = SuperblockProbe.probe(reader: SliceReader(bytes: rfs))
        #expect(rfsProbe?.fileSystem == .reiserfs)
        #expect(rfsProbe?.label == "OLD_LINUX")

        // 2. SquashFS 4.0 at offset 0 ("hsqs")
        var sqsh = Data(repeating: 0, count: 8192)
        sqsh.replaceSubrange(0..<4, with: Data("hsqs".utf8))
        sqsh[4] = 3 // inodes
        sqsh[12] = 0x00; sqsh[13] = 0x10; sqsh[14] = 0x00; sqsh[15] = 0x00 // block_size = 4096
        sqsh[28] = 4; sqsh[29] = 0 // s_major = 4
        sqsh[40] = 0x00; sqsh[41] = 0x10 // bytes_used = 4096
        let sqshProbe = SuperblockProbe.probe(reader: SliceReader(bytes: sqsh))
        #expect(sqshProbe?.fileSystem == .squashfs)

        // 3. JFS1 at 32 KiB ("JFS1")
        var jfs = Data(repeating: 0, count: 65536)
        jfs.replaceSubrange(32768..<(32768 + 4), with: Data("JFS1".utf8))
        jfs[32768 + 4] = 1 // version = 1
        jfs[32768 + 16] = 0x00; jfs[32768 + 17] = 0x10 // s_bsize = 4096
        jfs.replaceSubrange((32768 + 144)..<(32768 + 151), with: Data("AIX_JFS".utf8))
        let jfsProbe = SuperblockProbe.probe(reader: SliceReader(bytes: jfs))
        #expect(jfsProbe?.fileSystem == .jfs)
        #expect(jfsProbe?.label == "AIX_JFS")

        // 4. LUKS2 encrypted container at offset 0
        var luks = Data(repeating: 0, count: 8192)
        luks.replaceSubrange(0..<6, with: Data([0x4C, 0x55, 0x4B, 0x53, 0xBA, 0xBE]))
        luks[6] = 0x00; luks[7] = 0x02 // big-endian version 2
        luks.replaceSubrange(24..<34, with: Data("CRYPT_ROOT".utf8))
        let luksProbe = SuperblockProbe.probe(reader: SliceReader(bytes: luks))
        #expect(luksProbe?.fileSystem == .luks2)
        #expect(luksProbe?.label == "CRYPT_ROOT")

        // 5. LVM2 physical volume at sector 1 (offset 512)
        var lvm = Data(repeating: 0, count: 8192)
        lvm.replaceSubrange(512..<520, with: Data("LABELONE".utf8))
        lvm.replaceSubrange((512 + 24)..<(512 + 32), with: Data("LVM2 001".utf8))
        let lvmProbe = SuperblockProbe.probe(reader: SliceReader(bytes: lvm))
        #expect(lvmProbe?.fileSystem == .lvm2)
    }

    @Test("Verify ROMFS read-only file extraction through CLegacyFS")
    func testROMFSReadThroughCLegacyFS() throws {
        // Construct a minimal valid big-endian ROMFS image in memory containing /hello.txt -> "Hello archival world"
        var img = [UInt8](repeating: 0, count: 4096)
        func putBE32(_ off: Int, _ val: UInt32) {
            img[off]     = UInt8((val >> 24) & 0xFF)
            img[off + 1] = UInt8((val >> 16) & 0xFF)
            img[off + 2] = UInt8((val >> 8) & 0xFF)
            img[off + 3] = UInt8(val & 0xFF)
        }
        let magic = Array("-rom1fs-".utf8)
        img.replaceSubrange(0..<8, with: magic)
        putBE32(8, 512) // full_size
        let volName = Array("ROMVOL".utf8) // padded to 16 bytes -> root starts at offset 32
        img.replaceSubrange(16..<(16 + volName.count), with: volName)

        // Offset 32: root directory header (type 1, spec_info = first child at 64, name ".")
        putBE32(32, 1)
        putBE32(36, 64)
        img[48] = UInt8(ascii: ".")

        // Offset 64: regular file (type 2), next=0, size=20, name="hello.txt" (16B padded -> data at 96)
        putBE32(64, 2)
        putBE32(72, 20)
        let fname = Array("hello.txt".utf8)
        img.replaceSubrange(80..<(80 + fname.count), with: fname)
        let payload = Array("Hello archival world".utf8)
        img.replaceSubrange(96..<(96 + payload.count), with: payload)

        var sum: UInt32 = 0
        for i in stride(from: 0, to: 512, by: 4) where i != 12 {
            let word = (UInt32(img[i]) << 24) | (UInt32(img[i + 1]) << 16) | (UInt32(img[i + 2]) << 8) | UInt32(img[i + 3])
            sum = sum &+ word
        }
        putBE32(12, 0 &- sum)

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("romfs_\(UUID().uuidString).img")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try Data(img).write(to: tempURL)

        let probed = SuperblockProbe.probe(path: tempURL.path)
        #expect(probed?.fileSystem == .romfs)
        #expect(probed?.label == "ROMVOL")

        var fs: OpaquePointer?
        let openRc = tempURL.path.withCString { legacyfs_open_path($0, LEGACYFS_KIND_UNKNOWN, &fs) }
        #expect(openRc == 0)
        #expect(fs != nil)
        defer { if let fs { legacyfs_close(fs) } }

        var ino: UInt64 = 0
        let lookRc = "/hello.txt".withCString { legacyfs_lookup_path(fs, $0, &ino) }
        #expect(lookRc == 0)

        var outBuf = [UInt8](repeating: 0, count: 64)
        var got = 0
        let readRc = legacyfs_read(fs, ino, 0, outBuf.count, &outBuf, &got)
        #expect(readRc == 0)
        #expect(got == 20)
        #expect(String(decoding: outBuf.prefix(got), as: UTF8.self) == "Hello archival world")
    }

    @Test("Verify XFS v5 format, read-write CCowFS round trip, legacyfs v0.2.0 interoperability, and xfsck")
    func testXFSReadWriteRoundTripAndFsck() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("xfs_rw_\(UUID().uuidString).img")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try Data(repeating: 0, count: 16 * 1024 * 1024).write(to: tempURL)

        let fmtOpts = FormatOptions(type: .xfs, label: "XFS_RW_VOL", blockSize: 4096, force: true)
        _ = try DiskFormatTool.format(target: tempURL.path, options: fmtOpts)

        let probed = SuperblockProbe.probe(path: tempURL.path)
        #expect(probed?.fileSystem == .xfs)
        #expect(probed?.label == "XFS_RW_VOL")

        var fs: OpaquePointer?
        #expect(tempURL.path.withCString { cowfs_mount_path(COWFS_KIND_XFS, $0, 0, &fs) } == 0)
        guard let fs else { return }

        let rootIno = cowfs_root_ino(fs)
        var docsIno: UInt64 = 0
        #expect("docs".withCString { cowfs_mkdir(fs, rootIno, $0, 0o755, &docsIno) } == 0)

        var fileIno: UInt64 = 0
        #expect("notes.txt".withCString { cowfs_create(fs, docsIno, $0, 0o644, &fileIno) } == 0)
        let payload = Array("XFS v5 Castagnoli CRC32c read-write test\n".utf8)
        var written = 0
        #expect(payload.withUnsafeBytes { cowfs_write(fs, fileIno, 0, payload.count, $0.baseAddress, &written) } == 0)
        #expect(written == payload.count)

        var symIno: UInt64 = 0
        #expect("latest.txt".withCString { n in "docs/notes.txt".withCString { t in cowfs_symlink(fs, rootIno, n, t, &symIno) } } == 0)

        cowfs_unmount(fs)

        // Verify xfsck read-only consistency check
        let checkRes = try DiskRepairTool.repair(target: tempURL.path, force: true, autoFix: false)
        #expect(checkRes.success)
        #expect(checkRes.wasClean)

        // Verify legacyfs v0.2.0 read-only XFS reader can also browse and read the written XFS v5 tree
        var lfs: OpaquePointer?
        #expect(tempURL.path.withCString { legacyfs_open_path($0, LEGACYFS_KIND_XFS, &lfs) } == 0)
        if let lfs {
            defer { legacyfs_close(lfs) }
            var foundIno: UInt64 = 0
            #expect("/docs/notes.txt".withCString { legacyfs_lookup_path(lfs, $0, &foundIno) } == 0)
            var rbuf = [UInt8](repeating: 0, count: 64)
            var got = 0
            #expect(legacyfs_read(lfs, foundIno, 0, rbuf.count, &rbuf, &got) == 0)
            #expect(Array(rbuf.prefix(got)) == payload)
        }
    }

    @Test("Verify Btrfs CoW format, read-write CCowFS round trip, legacyfs v0.2.0 interoperability, and btrfsck")
    func testBtrfsReadWriteRoundTripAndFsck() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("btrfs_rw_\(UUID().uuidString).img")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try Data(repeating: 0, count: 16 * 1024 * 1024).write(to: tempURL)

        let fmtOpts = FormatOptions(type: .btrfs, label: "BTRFS_RW_VOL", blockSize: 16384, force: true)
        _ = try DiskFormatTool.format(target: tempURL.path, options: fmtOpts)

        let probed = SuperblockProbe.probe(path: tempURL.path)
        #expect(probed?.fileSystem == .btrfs)
        #expect(probed?.label == "BTRFS_RW_VOL")

        var fs: OpaquePointer?
        #expect(tempURL.path.withCString { cowfs_mount_path(COWFS_KIND_BTRFS, $0, 0, &fs) } == 0)
        guard let fs else { return }

        let rootIno = cowfs_root_ino(fs)
        var dirIno: UInt64 = 0
        #expect("subvol".withCString { cowfs_mkdir(fs, rootIno, $0, 0o755, &dirIno) } == 0)

        var fileIno: UInt64 = 0
        #expect("readme.md".withCString { cowfs_create(fs, dirIno, $0, 0o644, &fileIno) } == 0)
        let payload = Array("Btrfs Copy-on-Write tree transaction payload\n".utf8)
        var written = 0
        #expect(payload.withUnsafeBytes { cowfs_write(fs, fileIno, 0, payload.count, $0.baseAddress, &written) } == 0)
        #expect(written == payload.count)

        cowfs_unmount(fs)

        // Verify btrfsck read-only consistency check
        let checkRes = try DiskRepairTool.repair(target: tempURL.path, force: true, autoFix: false)
        #expect(checkRes.success)
        #expect(checkRes.wasClean)

        // Verify legacyfs v0.2.0 read-only Btrfs reader can also browse and read the written Btrfs tree
        var lfs: OpaquePointer?
        #expect(tempURL.path.withCString { legacyfs_open_path($0, LEGACYFS_KIND_BTRFS, &lfs) } == 0)
        if let lfs {
            defer { legacyfs_close(lfs) }
            var foundIno: UInt64 = 0
            #expect("/subvol/readme.md".withCString { legacyfs_lookup_path(lfs, $0, &foundIno) } == 0)
            var rbuf = [UInt8](repeating: 0, count: 64)
            var got = 0
            #expect(legacyfs_read(lfs, foundIno, 0, rbuf.count, &rbuf, &got) == 0)
            #expect(Array(rbuf.prefix(got)) == payload)
        }
    }

    @Test("Verify LUKS encrypted container format, AES-XTS-Plain64 unlock, inner superblock probe, and passphrase rejection")
    func testLUKSFormatUnlockAndInnerProbe() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("luks_\(UUID().uuidString).img")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try ContainerManager.shared.formatLUKS(
            target: tempURL.path,
            passphrase: "correct-horse-battery",
            label: "ENCRYPTED",
            totalBytesIfFile: 8 * 1024 * 1024
        )

        let outerProbe = SuperblockProbe.probe(path: tempURL.path)
        #expect(outerProbe?.fileSystem == .luks1)
        #expect(outerProbe?.fileSystem.isGuidedContainer == true)

        let info = try ContainerManager.shared.inspectLUKS(target: tempURL.path)
        #expect(info.version == 1)
        #expect(info.cipher == "aes")
        #expect(info.cipherMode == "xts-plain64")
        #expect(info.activeSlots == 1)

        // Wrong passphrase must fail closed
        #expect(throws: MontserratError.self) {
            _ = try ContainerManager.shared.probeUnlockedLUKSPayload(target: tempURL.path, passphrase: "wrong-password")
        }

        // Write a synthetic ext4 superblock inside the encrypted payload via AES-XTS-Plain64
        var luksCtx: OpaquePointer?
        let unlockRc = tempURL.path.withCString { cPath in
            "correct-horse-battery".withCString { cPass in
                cowfs_luks_unlock(cPath, cPass, 0, &luksCtx)
            }
        }
        #expect(unlockRc == 0)
        if let luksCtx {
            var extSb = [UInt8](repeating: 0, count: 1024)
            extSb[56] = 0x53
            extSb[57] = 0xEF
            extSb[58] = 0x01
            extSb[96] = 0x40
            let lbl = Array("INNER_EXT4".utf8)
            extSb.replaceSubrange(120..<(120 + lbl.count), with: lbl)
            #expect(cowfs_luks_pwrite(luksCtx, 1024, extSb.count, &extSb) == 0)
            cowfs_luks_close(luksCtx)
        }

        let innerProbe = try ContainerManager.shared.probeUnlockedLUKSPayload(
            target: tempURL.path,
            passphrase: "correct-horse-battery"
        )
        #expect(innerProbe?.fileSystem == .ext4)
        #expect(innerProbe?.label == "INNER_EXT4")
    }

    @Test("Verify LVM2 volume group metadata scan and inner logical volume superblock detection")
    func testLVM2VolumeGroupScan() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("lvm2_\(UUID().uuidString).img")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        var img = [UInt8](repeating: 0, count: 4 * 1024 * 1024)
        func putLE32(_ off: Int, _ val: UInt32) {
            img[off]     = UInt8(val & 0xFF)
            img[off + 1] = UInt8((val >> 8) & 0xFF)
            img[off + 2] = UInt8((val >> 16) & 0xFF)
            img[off + 3] = UInt8((val >> 24) & 0xFF)
        }
        func putLE64(_ off: Int, _ val: UInt64) {
            putLE32(off, UInt32(val & 0xFFFFFFFF))
            putLE32(off + 4, UInt32(val >> 32))
        }

        // Sector 1 (512): LABELONE + pv_header at +32
        img.replaceSubrange(512..<520, with: Array("LABELONE".utf8))
        putLE64(512 + 8, 1)
        putLE32(512 + 20, 32)
        img.replaceSubrange((512 + 24)..<(512 + 32), with: Array("LVM2 001".utf8))

        let pvh = 512 + 32
        img.replaceSubrange(pvh..<(pvh + 32), with: Array("AbCdEf1234567890GhIjKl0987654321".utf8))
        putLE64(pvh + 32, UInt64(img.count))
        // Data area 0: pe_start = 1 MiB (1048576)
        putLE64(pvh + 40, 1_048_576)
        putLE64(pvh + 48, 0)
        // Terminator {0, 0} at pvh + 56..71
        // Metadata area 0: offset = 4096, size = 65536
        putLE64(pvh + 72, 4096)
        putLE64(pvh + 80, 65536)

        // MDA header at 4096
        let fmtt: [UInt8] = Array(" LVM2 x[5A%r0N*>".utf8)
        img.replaceSubrange((4096 + 4)..<(4096 + 20), with: fmtt)
        putLE32(4096 + 20, 1)
        putLE64(4096 + 24, 4096)
        putLE64(4096 + 32, 65536)

        let vgText = """
        ubuntu_vg {
            extent_size = 2048
            logical_volumes {
                root_lv {
                    segment1 {
                        start_extent = 0
                        extent_count = 2
                        type = "striped"
                        stripe_count = 1
                        stripes = [
                            "pv0", 0
                        ]
                    }
                }
            }
        }
        """
        let vgBytes = Array(vgText.utf8)
        putLE64(4096 + 40, 512)
        putLE64(4096 + 48, UInt64(vgBytes.count))
        img.replaceSubrange((4096 + 512)..<(4096 + 512 + vgBytes.count), with: vgBytes)

        // Place an ext4 superblock inside root_lv at pe_start (1_048_576) + 1024
        let extOff = 1_048_576 + 1024
        img[extOff + 56] = 0x53
        img[extOff + 57] = 0xEF
        img[extOff + 58] = 0x01
        img[extOff + 96] = 0x40
        let rootLbl = Array("LVM_ROOT".utf8)
        img.replaceSubrange((extOff + 120)..<(extOff + 120 + rootLbl.count), with: rootLbl)

        try Data(img).write(to: tempURL)

        let vg = try ContainerManager.shared.scanLVM2(target: tempURL.path)
        #expect(vg.vgName == "ubuntu_vg")
        #expect(vg.extentBytes == 2048 * 512)
        #expect(vg.logicalVolumes.count == 1)
        #expect(vg.logicalVolumes.first?.name == "root_lv")
        #expect(vg.logicalVolumes.first?.pvByteOffset == 1_048_576)
        #expect(vg.logicalVolumes.first?.innerFileSystem == "ext4")
        #expect(vg.logicalVolumes.first?.innerLabel == "LVM_ROOT")
    }

    @Test("Verify One-Click Recovery Handoff writes diagnostic JSON and TestDisk-NG auto-snapshot flags")
    func testRecoveryHandoffGeneration() throws {
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("handoff_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let imgURL = workDir.appendingPathComponent("damaged.img")
        var buf = Data(repeating: 0, count: 8389632 + 2048)
        let sbOffset = 8389632
        buf[sbOffset + 56] = 0x53
        buf[sbOffset + 57] = 0xEF
        buf[sbOffset + 58] = 0x01
        buf[sbOffset + 96] = 0x40
        try buf.write(to: imgURL)

        let handoff = try RecoveryHandoff.prepareHandoff(target: imgURL.path, preferPhotoRec: false, baseDir: workDir)
        #expect(FileManager.default.fileExists(atPath: handoff.reportFileURL.path))
        #expect(handoff.report.detectedFileSystem == "ext4")
        #expect(handoff.report.backupSuperblockBlock == 8193)
        #expect(handoff.arguments.contains("--auto-snapshot"))
        #expect(handoff.arguments.contains("--handoff-report"))
        #expect(handoff.arguments.contains(handoff.reportFileURL.path))
    }

    @Test("Verify apple-explorer .sparsebundle inspection and tree extraction via BackupBundleManager")
    func testAppleExplorerSparsebundleAndExtraction() throws {
        #expect(montserrat_apple_explorer_linked() == 1)
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("aex_sb_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let srcDir = workDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        let expectedText = "Montserrat + apple-explorer sparsebundle verification\n"
        try expectedText.write(to: srcDir.appendingPathComponent("Documents/Note.txt"), atomically: true, encoding: .utf8)

        let bundleURL = workDir.appendingPathComponent("TestArchive.sparsebundle")
        let createRes = try CommandRunner.run("/usr/bin/hdiutil", arguments: [
            "create", "-fs", "APFS", "-volname", "TMArchive",
            "-format", "UDSB", "-srcfolder", srcDir.path, bundleURL.path
        ])
        #expect(createRes.isSuccess)

        let info = try BackupBundleManager.shared.inspectBackup(target: bundleURL.path)
        #expect(info.containerKind == "sparsebundle")
        #expect(info.primaryFileSystem == "APFS")
        #expect(info.label == "TMArchive")
        #expect(info.volumeCount >= 1)

        let outDir = workDir.appendingPathComponent("extracted", isDirectory: true)
        try BackupBundleManager.shared.extractBackupPath(
            target: bundleURL.path,
            sourcePath: "/Documents",
            destinationPath: outDir.path
        )
        let restored = try String(contentsOf: outDir.appendingPathComponent("Note.txt"), encoding: .utf8)
        #expect(restored == expectedText)
    }

    @Test("Verify RFC 9106 Argon2id KDF and LUKS2 Argon2id keyslot container unlock")
    func testLUKS2Argon2idUnlock() throws {
        let salt = [UInt8](repeating: 0x42, count: 16)
        var k1 = [UInt8](repeating: 0, count: 32)
        var k2 = [UInt8](repeating: 0, count: 32)
        let rc1 = "argon2id-pass".withCString { cp in
            cowfs_argon2_derive(COWFS_ARGON2_ID, cp, 13, salt, salt.count, 2, 256, 2, &k1, 32)
        }
        let rc2 = "argon2id-pass".withCString { cp in
            cowfs_argon2_derive(COWFS_ARGON2_ID, cp, 13, salt, salt.count, 2, 256, 2, &k2, 32)
        }
        #expect(rc1 == 0 && rc2 == 0)
        #expect(k1 == k2)
        #expect(k1.contains(where: { $0 != 0 }))

        // Build a valid LUKS2 container using an Argon2id keyslot (stripes=1, AES-128-XTS 32-byte key)
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("luks2_argon2id_\(UUID().uuidString).img")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let totalSize = 512 * 1024
        var img = [UInt8](repeating: 0, count: totalSize)
        func putBE16(_ off: Int, _ v: UInt16) { img[off] = UInt8(v >> 8); img[off + 1] = UInt8(v & 0xFF) }
        func putBE64(_ off: Int, _ v: UInt64) {
            for b in 0..<8 { img[off + b] = UInt8((v >> ((7 - b) * 8)) & 0xFF) }
        }

        let masterKey = [UInt8](0..<32).map { UInt8(($0 * 7 + 13) & 0xFF) }
        let slotSalt = [UInt8](0..<32).map { UInt8(0xA0 + $0) }
        let digSalt = [UInt8](0..<32).map { UInt8(0x50 + $0) }

        // Digest = PBKDF2-HMAC-SHA256(masterKey, digSalt, 1000, 32)
        var digBytes = [UInt8](repeating: 0, count: 32)
        _ = masterKey.withUnsafeBytes { mkRaw in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                mkRaw.baseAddress?.assumingMemoryBound(to: Int8.self),
                masterKey.count,
                digSalt, digSalt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                1000, &digBytes, digBytes.count
            )
        }

        // Derive 32-byte slot key via Argon2id (time=2, memory=128 KiB, cpus=1)
        var slotKey = [UInt8](repeating: 0, count: 32)
        let passStr = "luks2-argon2id-secret"
        #expect(passStr.withCString { cp in
            cowfs_argon2_derive(COWFS_ARGON2_ID, cp, passStr.utf8.count, slotSalt, slotSalt.count, 2, 128, 1, &slotKey, 32)
        } == 0)

        // Encrypt 512-byte keyslot area (stripes=1 -> first 32 bytes = masterKey) using AES-128-XTS sector 0
        func xtsEncryptSector(_ k1Half: [UInt8], _ k2Half: [UInt8], _ sectorNum: UInt64, _ plain: [UInt8]) -> [UInt8] {
            var tweak = [UInt8](repeating: 0, count: 16)
            for i in 0..<8 { tweak[i] = UInt8((sectorNum >> (i * 8)) & 0xFF) }
            var moved = 0
            _ = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                        k2Half, 16, nil, tweak, 16, &tweak, 16, &moved)
            var out = [UInt8](repeating: 0, count: plain.count)
            for b in 0..<(plain.count / 16) {
                var blk = [UInt8](repeating: 0, count: 16)
                for i in 0..<16 { blk[i] = plain[b * 16 + i] ^ tweak[i] }
                _ = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                            k1Half, 16, nil, blk, 16, &blk, 16, &moved)
                for i in 0..<16 { out[b * 16 + i] = blk[i] ^ tweak[i] }
                let carry = (tweak[15] >> 7) & 1
                for i in stride(from: 15, through: 1, by: -1) { tweak[i] = (tweak[i] << 1) | (tweak[i - 1] >> 7) }
                tweak[0] = (tweak[0] << 1) ^ (carry != 0 ? 0x87 : 0x00)
            }
            return out
        }

        var afPlain = [UInt8](repeating: 0, count: 512)
        afPlain.replaceSubrange(0..<32, with: masterKey)
        let afCipher = xtsEncryptSector(Array(slotKey[0..<16]), Array(slotKey[16..<32]), 0, afPlain)
        img.replaceSubrange(32768..<(32768 + 512), with: afCipher)

        // Encrypt inner ext4 superblock at payload offset 65536 + 1024 (sector 2 of payload, 512B sectors)
        var innerSec = [UInt8](repeating: 0, count: 512)
        innerSec[56] = 0x53; innerSec[57] = 0xEF; innerSec[58] = 0x01; innerSec[96] = 0x40
        let lbl = Array("ARGON2_EXT4".utf8)
        innerSec.replaceSubrange(120..<(120 + lbl.count), with: lbl)
        let encSec = xtsEncryptSector(Array(masterKey[0..<16]), Array(masterKey[16..<32]), 2, innerSec)
        img.replaceSubrange((65536 + 1024)..<(65536 + 1536), with: encSec)

        // LUKS2 binary header + JSON metadata at 4096
        let luksMagic: [UInt8] = [0x4C, 0x55, 0x4B, 0x53, 0xBA, 0xBE]
        img.replaceSubrange(0..<6, with: luksMagic)
        putBE16(6, 2)
        putBE64(8, 16384) // hdr_size = 16 KiB (4 KiB binary + 12 KiB JSON)
        putBE64(16, 1)
        let labelBytes = Array("ARGON2VOL".utf8)
        img.replaceSubrange(24..<(24 + labelBytes.count), with: labelBytes)
        let uuidBytes = Array("11112222-3333-4444-5555-666677778888".utf8)
        img.replaceSubrange(168..<(168 + uuidBytes.count), with: uuidBytes)

        let jsonMeta = """
        {
          "keyslots": {
            "0": {
              "type": "luks2",
              "key_size": 32,
              "kdf": {
                "type": "argon2id",
                "time": 2,
                "memory": 128,
                "cpus": 1,
                "salt": "\(Data(slotSalt).base64EncodedString())"
              },
              "af": { "type": "luks1", "stripes": 1, "hash": "sha256" },
              "area": { "type": "raw", "encryption": "aes-xts-plain64", "key_size": 32, "offset": "32768", "size": "4096" }
            }
          },
          "segments": {
            "0": {
              "type": "crypt",
              "offset": "65536",
              "size": "dynamic",
              "iv_tweak": "0",
              "encryption": "aes-xts-plain64",
              "sector_size": 512
            }
          },
          "digests": {
            "0": {
              "type": "pbkdf2",
              "keyslots": ["0"],
              "segments": ["0"],
              "hash": "sha256",
              "iterations": 1000,
              "salt": "\(Data(digSalt).base64EncodedString())",
              "digest": "\(Data(digBytes).base64EncodedString())"
            }
          }
        }
        """
        let jBytes = Array(jsonMeta.utf8)
        img.replaceSubrange(4096..<(4096 + jBytes.count), with: jBytes)
        try Data(img).write(to: tempURL)

        let unlockedProbe = try ContainerManager.shared.probeUnlockedLUKSPayload(target: tempURL.path, passphrase: passStr)
        #expect(unlockedProbe?.fileSystem == .ext4)
        #expect(unlockedProbe?.label == "ARGON2_EXT4")
    }

    @Test("Verify Multi-PV Striped LVM2 Logical Volume Assembly across 2 Disks")
    func testMultiPVStripedLVM2Assembly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mpv_lvm_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        func makePV(uuidRaw: String, includeVG: Bool, vgText: String, stripePayload: [UInt8]) -> Data {
            var img = [UInt8](repeating: 0, count: 2 * 1024 * 1024)
            func putLE32(_ o: Int, _ v: UInt32) {
                img[o] = UInt8(v & 0xFF); img[o+1] = UInt8((v >> 8) & 0xFF)
                img[o+2] = UInt8((v >> 16) & 0xFF); img[o+3] = UInt8((v >> 24) & 0xFF)
            }
            func putLE64(_ o: Int, _ v: UInt64) { putLE32(o, UInt32(v & 0xFFFFFFFF)); putLE32(o + 4, UInt32(v >> 32)) }

            img.replaceSubrange(512..<520, with: Array("LABELONE".utf8))
            putLE64(512 + 8, 1); putLE32(512 + 20, 32)
            img.replaceSubrange((512 + 24)..<(512 + 32), with: Array("LVM2 001".utf8))
            let pvh = 512 + 32
            img.replaceSubrange(pvh..<(pvh + 32), with: Array(uuidRaw.utf8))
            putLE64(pvh + 32, UInt64(img.count))
            putLE64(pvh + 40, 1_048_576) // pe_start = 1 MiB
            if includeVG {
                putLE64(pvh + 72, 4096); putLE64(pvh + 80, 65536)
                img.replaceSubrange((4096 + 4)..<(4096 + 20), with: Array(" LVM2 x[5A%r0N*>".utf8))
                putLE32(4096 + 20, 1); putLE64(4096 + 24, 4096); putLE64(4096 + 32, 65536)
                let vb = Array(vgText.utf8)
                putLE64(4096 + 40, 512); putLE64(4096 + 48, UInt64(vb.count))
                img.replaceSubrange((4096 + 512)..<(4096 + 512 + vb.count), with: vb)
            }
            img.replaceSubrange(1_048_576..<(1_048_576 + stripePayload.count), with: stripePayload)
            return Data(img)
        }

        let vgText = """
        striped_vg {
            extent_size = 1024
            physical_volumes {
                pv0 { id = "PV0000-1111-2222-3333-4444-5555-666666" pe_start = 2048 }
                pv1 { id = "PV1111-1111-2222-3333-4444-5555-777777" pe_start = 2048 }
            }
            logical_volumes {
                fast_lv {
                    segment1 {
                        start_extent = 0
                        extent_count = 2
                        type = "striped"
                        stripe_count = 2
                        stripe_size = 128
                        stripes = [ "pv0", 0, "pv1", 0 ]
                    }
                }
            }
        }
        """
        // stripe_size = 128 sectors = 65536 bytes: chunk 0 on pv0, chunk 1 on pv1!
        var chunk0 = [UInt8](repeating: 0xAA, count: 65536)
        chunk0[1024 + 56] = 0x53; chunk0[1024 + 57] = 0xEF
        var chunk1 = [UInt8](repeating: 0x55, count: 65536)
        let marker = Array("SECOND_STRIPE_PV1".utf8)
        chunk1.replaceSubrange(0..<marker.count, with: marker)

        let pv0URL = dir.appendingPathComponent("pv0.img")
        let pv1URL = dir.appendingPathComponent("pv1.img")
        try makePV(uuidRaw: "PV000011112222333344445555666666", includeVG: true, vgText: vgText, stripePayload: chunk0).write(to: pv0URL)
        try makePV(uuidRaw: "PV111111112222333344445555777777", includeVG: false, vgText: "", stripePayload: chunk1).write(to: pv1URL)

        let c0 = strdup(pv0URL.path)
        let c1 = strdup(pv1URL.path)
        defer { free(c0); free(c1) }
        let ptrs: [UnsafePointer<CChar>?] = [UnsafePointer(c0), UnsafePointer(c1)]
        var lvCtx: OpaquePointer?
        let rc = ptrs.withUnsafeBufferPointer { buf in
            "fast_lv".withCString { cLv in
                cowfs_lvm_open_lv(buf.baseAddress, 2, cLv, 1, &lvCtx)
            }
        }
        #expect(rc == 0)
        if let lv = lvCtx {
            defer { cowfs_lvm_close_lv(lv) }
            #expect(cowfs_lvm_lv_size(lv) == 2 * 1024 * 512)
            var checkMagic = [UInt8](repeating: 0, count: 2)
            #expect(cowfs_lvm_lv_pread(lv, 1024 + 56, 2, &checkMagic) == 0)
            #expect(checkMagic == [0x53, 0xEF])

            var checkStripe2 = [UInt8](repeating: 0, count: marker.count)
            #expect(cowfs_lvm_lv_pread(lv, 65536, marker.count, &checkStripe2) == 0)
            #expect(checkStripe2 == marker)
        }
    }

    @Test("Verify Linux mdadm v1.2 RAID-5 Assembly and Degraded Single-Disk XOR Parity Reconstruction")
    func testMdadmRAID5AndDegradedParity() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mdraid5_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // 3-disk RAID-5 (v1.2 superblock at 4096, data_offset = 131072 = 256 sectors, chunk = 65536 = 128 sectors, layout = 2 left-symmetric)
        // Stripe 0 (layout 2, N=3): pd = (3-1) - (0%3) = 2 -> chunk 0 on disk 0, chunk 1 on disk 1, parity on disk 2!
        let chunkBytes = 65536
        var d0Payload = [UInt8](repeating: 0, count: chunkBytes * 2)
        var d1Payload = [UInt8](repeating: 0, count: chunkBytes * 2)
        // Put ext4 superblock on virtual chunk 0 (disk 0) and distinct text on virtual chunk 1 (disk 1, which we will delete!)
        d0Payload[1024 + 56] = 0x53; d0Payload[1024 + 57] = 0xEF; d0Payload[1024 + 58] = 0x01; d0Payload[1024 + 96] = 0x40
        let lbl = Array("RAID5_EXT4".utf8)
        d0Payload.replaceSubrange((1024 + 120)..<(1024 + 120 + lbl.count), with: lbl)

        let secretOnDisk1 = Array("RECONSTRUCTED_VIA_RAID5_XOR_PARITY".utf8)
        d1Payload.replaceSubrange(128..<(128 + secretOnDisk1.count), with: secretOnDisk1)

        var d2Parity = [UInt8](repeating: 0, count: chunkBytes * 2)
        for i in 0..<d2Parity.count {
            d2Parity[i] = d0Payload[i] ^ d1Payload[i]
        }

        let setUUID: [UInt8] = [0xDE,0xAD,0xBE,0xEF, 0x11,0x22,0x33,0x44, 0x55,0x66,0x77,0x88, 0x99,0xAA,0xBB,0xCC]
        func writeMember(role: UInt16, payload: [UInt8], url: URL) throws {
            var img = [UInt8](repeating: 0, count: 131072 + payload.count)
            func putLE16(_ o: Int, _ v: UInt16) { img[o] = UInt8(v & 0xFF); img[o+1] = UInt8(v >> 8) }
            func putLE32(_ o: Int, _ v: UInt32) {
                img[o] = UInt8(v & 0xFF); img[o+1] = UInt8((v >> 8) & 0xFF)
                img[o+2] = UInt8((v >> 16) & 0xFF); img[o+3] = UInt8((v >> 24) & 0xFF)
            }
            func putLE64(_ o: Int, _ v: UInt64) { putLE32(o, UInt32(v & 0xFFFFFFFF)); putLE32(o + 4, UInt32(v >> 32)) }

            let sb = 4096
            putLE32(sb + 0, 0xA92B4EFE) // MD_SB_MAGIC
            putLE32(sb + 4, 1)          // major_version = 1
            img.replaceSubrange((sb + 16)..<(sb + 32), with: setUUID)
            let name = Array("nas:0".utf8)
            img.replaceSubrange((sb + 32)..<(sb + 32 + name.count), with: name)
            putLE32(sb + 72, 5)                         // RAID-5
            putLE32(sb + 76, 2)                         // LEFT_SYMMETRIC
            putLE64(sb + 80, UInt64(payload.count / 512)) // component size sectors
            putLE32(sb + 88, UInt32(chunkBytes / 512))  // chunksize sectors
            putLE32(sb + 92, 3)                         // raid_disks = 3
            putLE64(sb + 128, 256)                      // data_offset = 256 sectors (131072)
            putLE64(sb + 136, UInt64(payload.count / 512))
            putLE64(sb + 144, 8)                        // super_offset = 8 sectors (4096 -> v1.2)
            putLE32(sb + 160, UInt32(role))             // dev_number
            putLE16(sb + 256 + Int(role) * 2, role)     // dev_roles[dev_number] = role
            img.replaceSubrange(131072..<(131072 + payload.count), with: payload)
            try Data(img).write(to: url)
        }

        let m0 = dir.appendingPathComponent("m0.img")
        let m1 = dir.appendingPathComponent("m1.img")
        let m2 = dir.appendingPathComponent("m2.img")
        try writeMember(role: 0, payload: d0Payload, url: m0)
        try writeMember(role: 1, payload: d1Payload, url: m1)
        try writeMember(role: 2, payload: d2Parity, url: m2)

        // 1. Healthy 3-disk inspection
        let memberInfo = try ContainerManager.shared.inspectRAIDMember(target: m0.path)
        #expect(memberInfo.level == 5)
        #expect(memberInfo.majorVersion == 1 && memberInfo.minorVersion == 2)
        #expect(memberInfo.raidDisks == 3)

        // 2. Simulate disk failure: remove m1.img and assemble degraded 2-disk RAID-5 (only m0 + m2)!
        try FileManager.default.removeItem(at: m1)
        let degradedSummary = try ContainerManager.shared.probeAssembledRAID(memberPaths: [m0.path, m2.path])
        #expect(degradedSummary.level == 5)
        #expect(degradedSummary.degraded == true)
        #expect(degradedSummary.innerProbe?.fileSystem == .ext4)
        #expect(degradedSummary.innerProbe?.label == "RAID5_EXT4")

        // Verify exact XOR parity reconstruction of chunk 1 (which lived on the deleted m1.img!)
        let cm0 = strdup(m0.path)
        let cm2 = strdup(m2.path)
        defer { free(cm0); free(cm2) }
        let ptrs: [UnsafePointer<CChar>?] = [UnsafePointer(cm0), UnsafePointer(cm2)]
        var raidPtr: OpaquePointer?
        #expect(ptrs.withUnsafeBufferPointer { cowfs_mdraid_assemble($0.baseAddress, 2, &raidPtr) } == 0)
        if let raid = raidPtr {
            defer { cowfs_mdraid_close(raid) }
            var recovered = [UInt8](repeating: 0, count: secretOnDisk1.count)
            #expect(cowfs_mdraid_pread(raid, UInt64(chunkBytes + 128), secretOnDisk1.count, &recovered) == 0)
            #expect(recovered == secretOnDisk1)
        }
    }
}
