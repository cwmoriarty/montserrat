import Testing
import Foundation
#if canImport(Darwin)
import Darwin
#endif
import CLegacyFS
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

        // Production read-write engine support
        #expect(FileSystemKind.ext4.isSupportedByMontserrat)
        #expect(FileSystemKind.ext3.isSupportedByMontserrat)
        #expect(FileSystemKind.ext2.isSupportedByMontserrat)
        #expect(FileSystemKind.ntfs.isSupportedByMontserrat)

        // Detection-only filesystems must not be marked as mount-supported
        #expect(!FileSystemKind.btrfs.isSupportedByMontserrat)
        #expect(!FileSystemKind.xfs.isSupportedByMontserrat)
        #expect(!FileSystemKind.f2fs.isSupportedByMontserrat)
        #expect(FileSystemKind.btrfs.isDetectionOnly)
        #expect(FileSystemKind.xfs.isDetectionOnly)
        #expect(FileSystemKind.f2fs.isDetectionOnly)

        #expect(FileSystemKind.ext4.defaultEngineName == "fuse2fs")
        #expect(FileSystemKind.ntfs.defaultEngineName == "ntfs-3g")
        #expect(FileSystemKind.btrfs.defaultEngineName == nil)
        #expect(FileSystemKind.xfs.defaultEngineName == nil)
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
        #expect(ver == "0.1.0")

        var tablePtr: UnsafePointer<legacyfs_format_desc_t>?
        let count = legacyfs_supported_formats(&tablePtr)
        #expect(count >= 37)
        #expect(tablePtr != nil)
        #expect(EngineRegistry.legacyFSDriverAliases.count == 10)
    }
}
