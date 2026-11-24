import Testing
import Foundation
#if canImport(Darwin)
import Darwin
#endif
import CLegacyFS
import CCowFS
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
}
