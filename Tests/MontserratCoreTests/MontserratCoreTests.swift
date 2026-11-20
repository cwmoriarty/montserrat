import Testing
import Foundation
@testable import MontserratCore
@testable import MontserratFSKit

@Suite("Montserrat Core and Filesystem Engine Tests")
struct MontserratCoreTests {

    @Test("Verify FileSystemKind classification")
    func testFileSystemKind() {
        #expect(FileSystemKind.ext4.isExt)
        #expect(FileSystemKind.ext3.isExt)
        #expect(FileSystemKind.ext2.isExt)
        #expect(!FileSystemKind.btrfs.isExt)
        #expect(!FileSystemKind.xfs.isExt)
        #expect(!FileSystemKind.f2fs.isExt)
        #expect(FileSystemKind.ext4.isSupportedByMontserrat)
        #expect(FileSystemKind.btrfs.isSupportedByMontserrat)
        #expect(FileSystemKind.xfs.isSupportedByMontserrat)
        #expect(FileSystemKind.f2fs.isSupportedByMontserrat)
        #expect(FileSystemKind.ext4.defaultEngineName == "fuse2fs")
        #expect(FileSystemKind.ntfs.defaultEngineName == "ntfs-3g")
        #expect(FileSystemKind.btrfs.defaultEngineName == "btrfs-fuse")
        #expect(FileSystemKind.xfs.defaultEngineName == "xfs-fuse")
        #expect(FileSystemKind.f2fs.defaultEngineName == "f2fs-fuse")
    }

    @Test("Verify Safety Policy protects internal disks")
    func testInternalDiskProtection() {
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

    @Test("Verify ext4 Superblock Parsing from synthetic byte buffer")
    func testExt4SuperblockParsing() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".img")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        var buffer = Data(repeating: 0, count: 4096)
        // Magic at 1024 + 56 = 1080 (0xEF53 -> 0x53, 0xEF)
        buffer[1080] = 0x53
        buffer[1081] = 0xEF
        // State at 1024 + 58 = 1082 (1 = clean)
        buffer[1082] = 0x01
        buffer[1083] = 0x00
        // Incompat features at 1024 + 96 = 1120 (0x0040 = extents)
        buffer[1120] = 0x40
        buffer[1121] = 0x00
        buffer[1122] = 0x00
        buffer[1123] = 0x00
        // Label at 1024 + 120 = 1144 ("TEST_EXT4")
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

        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        let fh = try FileHandle(forUpdating: tempURL)
        defer { try? fh.close() }

        // Primary superblock at offset 1024 is deliberately all zeroes (corrupted)
        let zeroBuf = Data(repeating: 0, count: 2048)
        try fh.write(contentsOf: zeroBuf)

        // Write valid ext4 backup superblock at block 8192 (offset 33,554,432)
        try fh.seek(toOffset: 33554432)
        var backupBuf = Data(repeating: 0, count: 1024)
        // Magic at 56
        backupBuf[56] = 0x53
        backupBuf[57] = 0xEF
        backupBuf[58] = 0x01 // Clean
        backupBuf[96] = 0x40 // Extents
        let labelData = "RESCUE_VOL".data(using: .utf8)!
        backupBuf.replaceSubrange(120..<(120 + labelData.count), with: labelData)
        try fh.write(contentsOf: backupBuf)

        let probeResult = SuperblockProbe.probe(path: tempURL.path)
        #expect(probeResult != nil)
        #expect(probeResult?.fileSystem == .ext4)
        #expect(probeResult?.state == .backupSuperblockRecoverable)
        #expect(probeResult?.backupSuperblockBlock == 8192)
        #expect(probeResult?.label == "RESCUE_VOL")
    }

    @Test("Verify Btrfs Superblock Probing")
    func testBtrfsSuperblockProbing() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".img")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        let fh = try FileHandle(forUpdating: tempURL)
        defer { try? fh.close() }

        // Btrfs superblock at 64 KiB (65536)
        try fh.seek(toOffset: 65536)
        var buf = Data(repeating: 0, count: 4096)
        // Magic: "_BHRfS_M" at offset 64
        let magic = "_BHRfS_M".data(using: .ascii)!
        buf.replaceSubrange(64..<(64 + magic.count), with: magic)
        // Label at offset 299
        let label = "BTRFS_DRIVE".data(using: .utf8)!
        buf.replaceSubrange(299..<(299 + label.count), with: label)
        try fh.write(contentsOf: buf)

        let probeResult = SuperblockProbe.probe(path: tempURL.path)
        #expect(probeResult != nil)
        #expect(probeResult?.fileSystem == .btrfs)
        #expect(probeResult?.label == "BTRFS_DRIVE")
    }

    @Test("Verify XFS Superblock Probing")
    func testXfsSuperblockProbing() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".img")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        var buf = Data(repeating: 0, count: 512)
        // Magic: "XFSB" at offset 0
        let magic = "XFSB".data(using: .ascii)!
        buf.replaceSubrange(0..<4, with: magic)
        // Label at offset 108
        let label = "XFS_DATA".data(using: .utf8)!
        buf.replaceSubrange(108..<(108 + label.count), with: label)

        try buf.write(to: tempURL)

        let probeResult = SuperblockProbe.probe(path: tempURL.path)
        #expect(probeResult != nil)
        #expect(probeResult?.fileSystem == .xfs)
        #expect(probeResult?.label == "XFS_DATA")
    }

    @Test("Verify F2FS Superblock Probing")
    func testF2fsSuperblockProbing() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".img")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        let fh = try FileHandle(forUpdating: tempURL)
        defer { try? fh.close() }

        try fh.seek(toOffset: 1024)
        var buf = Data(repeating: 0, count: 512)
        // Magic at offset 0: 0xF2F52010 -> 0x10, 0x20, 0xF5, 0xF2
        buf[0] = 0x10
        buf[1] = 0x20
        buf[2] = 0xF5
        buf[3] = 0xF2
        try fh.write(contentsOf: buf)

        let probeResult = SuperblockProbe.probe(path: tempURL.path)
        #expect(probeResult != nil)
        #expect(probeResult?.fileSystem == .f2fs)
    }

    @Test("Verify Device Disappearance and Unplug Signal Cleanup")
    func testDeviceDisappearanceCleanup() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manager = MountManager(stateDir: tempDir)
        // Clean call when disk is not mounted should be safe and non-throwing
        manager.handleDeviceDisappeared(bsdName: "disk99s1")
        #expect(manager.activeMounts().isEmpty)
    }

    @Test("Verify Apple FSKit Framework Detection and Capabilities")
    func testFSKitFrameworkDetection() {
        if #available(macOS 15.4, *) {
            let check = FSKitSupport.checkAvailability()
            #expect(check.available == true)
            let preferred = MontserratFSKitManager.shared.preferredEngine(for: "/dev/disk4s1")
            #expect(preferred == .fskit)
        }
    }

    @Test("Verify External Unmount Reconciliation and Cleanup")
    func testExternalUnmountReconciliation() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manager = MountManager(stateDir: tempDir)
        let mountDir = tempDir.appendingPathComponent("StaleMount", isDirectory: true)
        try? FileManager.default.createDirectory(at: mountDir, withIntermediateDirectories: true)

        let record = MountRecord(
            source: "/dev/disk99s1",
            bsdName: "disk99s1",
            wholeDiskBSDName: "disk99",
            mountPoint: mountDir.path,
            fileSystem: .ext4,
            engine: "fuse2fs",
            enginePath: "/usr/local/share/montserrat/engines/bin/fuse2fs",
            pid: 999999,
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
}
