import Testing
import Foundation
@testable import MontserratCore
import CExt2FS

@Suite("Disk Image and Block Device Integration Tests")
struct DiskImageIntegrationTests {

    private func createAndAttachDiskImage(sizeMB: Int = 32) throws -> (imagePath: String, devNode: String) {
        let tempDir = FileManager.default.temporaryDirectory
        let imageURL = tempDir.appendingPathComponent("montserrat_test_\(UUID().uuidString).dmg")

        let createProc = Process()
        createProc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        createProc.arguments = ["create", "-size", "\(sizeMB)m", "-layout", "NONE", "-ov", imageURL.path]
        try createProc.run()
        createProc.waitUntilExit()

        guard createProc.terminationStatus == 0 else {
            throw MontserratError.commandFailed("hdiutil create", exitCode: createProc.terminationStatus, output: "Creation failed")
        }

        let attachProc = Process()
        let pipe = Pipe()
        attachProc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        attachProc.arguments = ["attach", "-nomount", imageURL.path]
        attachProc.standardOutput = pipe
        try attachProc.run()
        attachProc.waitUntilExit()

        guard attachProc.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: imageURL)
            throw MontserratError.commandFailed("hdiutil attach", exitCode: attachProc.terminationStatus, output: "Attach failed")
        }

        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        let outputStr = String(data: outputData, encoding: .utf8) ?? ""
        let parts = outputStr.split(whereSeparator: { $0.isWhitespace })
        guard let firstPart = parts.first, firstPart.hasPrefix("/dev/disk") else {
            try? FileManager.default.removeItem(at: imageURL)
            throw MontserratError.diskNotFound("Could not determine attached disk node from output: \(outputStr)")
        }

        return (imagePath: imageURL.path, devNode: String(firstPart))
    }

    private func detachAndRemove(imagePath: String, devNode: String) {
        let detachProc = Process()
        detachProc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        detachProc.arguments = ["detach", devNode, "-force"]
        try? detachProc.run()
        detachProc.waitUntilExit()

        try? FileManager.default.removeItem(atPath: imagePath)
    }

    @Test("Verify Virtual Disk Image attachment, ext4 mount-write-read round trip, and e2fsck verification")
    func testVirtualDiskInspectionAndRoundTrip() throws {
        let attached = try createAndAttachDiskImage(sizeMB: 32)
        defer {
            detachAndRemove(imagePath: attached.imagePath, devNode: attached.devNode)
        }

        #expect(attached.devNode.hasPrefix("/dev/disk"))

        let bsdName = attached.devNode.replacingOccurrences(of: "/dev/", with: "")
        let inspected = DiskProbe.inspectDisk(bsdName: bsdName)
        #expect(inspected != nil)
        #expect(inspected?.isInternal == false)
        #expect(inspected?.isDiskImage == true)

        let rdevNode = attached.devNode.replacingOccurrences(of: "/dev/disk", with: "/dev/rdisk")
        if let mke2fs = EngineRegistry.findBinary("mke2fs") {
            let formatProc = Process()
            formatProc.executableURL = URL(fileURLWithPath: mke2fs)
            formatProc.arguments = ["-t", "ext4", "-F", "-L", "INTEG_EXT4", rdevNode]
            try formatProc.run()
            formatProc.waitUntilExit()

            #expect(formatProc.terminationStatus == 0)

            let probed = SuperblockProbe.probe(path: attached.devNode)
            #expect(probed != nil)
            #expect(probed?.fileSystem == .ext4)
            #expect(probed?.label == "INTEG_EXT4")
            #expect(probed?.state == .clean)

            // Perform read-write-verify round trip using CExt2FS bridge
            var ctx: OpaquePointer? = nil
            let mountRc = ext4_bridge_mount(attached.devNode, 0, &ctx)
            #expect(mountRc == 0)
            if mountRc == 0, let validCtx = ctx {
                var newIno: UInt64 = 0
                let createRc = "hello.txt".withCString { cName in
                    ext4_bridge_create(validCtx, 2, cName, 0o644, &newIno)
                }
                #expect(createRc == 0)
                #expect(newIno > 2)

                let payload = Array("Montserrat ext4 verification payload\n".utf8)
                var written: Int = 0
                let writeRc = payload.withUnsafeBytes { rawBuf in
                    ext4_bridge_write(validCtx, newIno, 0, payload.count, rawBuf.baseAddress, &written)
                }
                #expect(writeRc == 0)
                #expect(written == payload.count)

                var readBuf = [UInt8](repeating: 0, count: 64)
                var got: Int = 0
                let readRc = readBuf.withUnsafeMutableBytes { rawBuf in
                    ext4_bridge_read(validCtx, newIno, 0, payload.count, rawBuf.baseAddress, &got)
                }
                #expect(readRc == 0)
                #expect(got == payload.count)
                #expect(Array(readBuf.prefix(got)) == payload)

                ext4_bridge_unmount(validCtx)
            }

            // Verify filesystem consistency with e2fsck -fn
            if let e2fsck = EngineRegistry.findBinary("e2fsck") {
                let checkRes = try CommandRunner.run(e2fsck, arguments: ["-fn", rdevNode])
                #expect(checkRes.exitCode == 0)
            }
        }
    }

    @Test("Verify Safety Policy blocks format attempts on protected disk nodes")
    func testSafetyPolicyRejectionOnProtectedDisk() {
        let opts = FormatOptions(type: .ext4, label: "TEST", force: true)

        #expect(throws: MontserratError.self) {
            _ = try DiskFormatTool.format(target: "/dev/disk0", options: opts)
        }

        #expect(throws: MontserratError.self) {
            _ = try DiskFormatTool.format(target: "/dev/disk3", options: opts)
        }
    }

    @Test("Verify DiskFormatTool wipes prior NTFS VBR signature before formatting ext4")
    func testFormatExt4WipesPriorNTFSBootSignature() throws {
        guard EngineRegistry.findBinary("mke2fs") != nil else {
            return
        }

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("reformat_\(UUID().uuidString).img")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        var initialData = Data(repeating: 0, count: 16 * 1024 * 1024)
        let ntfsSignature = "NTFS    ".data(using: .ascii)!
        initialData.replaceSubrange(3..<(3 + ntfsSignature.count), with: ntfsSignature)
        try initialData.write(to: tempURL)

        let opts = FormatOptions(type: .ext4, label: "WIPED_EXT4", blockSize: 1024, force: true)
        _ = try DiskFormatTool.format(target: tempURL.path, options: opts)

        // Corrupt primary ext4 superblock at offset 1024; probe must still recover ext4 via backup superblock
        let fh = try FileHandle(forUpdating: tempURL)
        try fh.seek(toOffset: 1024)
        try fh.write(contentsOf: Data(repeating: 0, count: 1024))
        try fh.close()

        let probeResult = SuperblockProbe.probe(path: tempURL.path)
        #expect(probeResult != nil)
        #expect(probeResult?.fileSystem == .ext4)
        #expect(probeResult?.label == "WIPED_EXT4")
        #expect(probeResult?.state == .backupSuperblockRecoverable)
    }

    @Test("Verify CExt2FS callback IO, symlink, hardlink, rename, timestamps, and e2fsck consistency")
    func testCExt2FSCallbackIOAndFullOperations() throws {
        guard let mke2fs = EngineRegistry.findBinary("mke2fs"),
              let e2fsck = EngineRegistry.findBinary("e2fsck") else {
            return
        }

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("fskit_ops_\(UUID().uuidString).img")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try Data(repeating: 0, count: 16 * 1024 * 1024).write(to: tempURL)

        let fmtRes = try CommandRunner.run(mke2fs, arguments: ["-t", "ext4", "-F", "-L", "FSKIT_OPS", tempURL.path])
        #expect(fmtRes.isSuccess)

        final class FileHandleIOContext {
            let fh: FileHandle
            init(url: URL) throws {
                self.fh = try FileHandle(forUpdating: url)
            }
            deinit {
                try? fh.close()
            }
        }

        let ioCtx = try FileHandleIOContext(url: tempURL)
        let ctxPtr = Unmanaged.passUnretained(ioCtx).toOpaque()

        let readFn: ext4_io_read_fn = { rawCtx, offset, length, buffer, outRead in
            guard let rawCtx, let buffer else { return Int32(-EINVAL) }
            let box = Unmanaged<FileHandleIOContext>.fromOpaque(rawCtx).takeUnretainedValue()
            do {
                try box.fh.seek(toOffset: offset)
                let data = try box.fh.read(upToCount: length) ?? Data()
                data.withUnsafeBytes { rawBuf in
                    if let base = rawBuf.baseAddress {
                        memcpy(buffer, base, data.count)
                    }
                }
                outRead?.pointee = data.count
                return 0
            } catch {
                return Int32(-EIO)
            }
        }

        let writeFn: ext4_io_write_fn = { rawCtx, offset, length, buffer, outWritten in
            guard let rawCtx, let buffer else { return Int32(-EINVAL) }
            let box = Unmanaged<FileHandleIOContext>.fromOpaque(rawCtx).takeUnretainedValue()
            do {
                try box.fh.seek(toOffset: offset)
                let data = Data(bytes: buffer, count: length)
                try box.fh.write(contentsOf: data)
                outWritten?.pointee = length
                return 0
            } catch {
                return Int32(-EIO)
            }
        }

        let flushFn: ext4_io_flush_fn = { rawCtx in
            guard let rawCtx else { return 0 }
            let box = Unmanaged<FileHandleIOContext>.fromOpaque(rawCtx).takeUnretainedValue()
            try? box.fh.synchronize()
            return 0
        }

        var ctx: OpaquePointer? = nil
        let mountRc = "callback-test".withCString { cName in
            ext4_bridge_mount_io(cName, 0, 4096, ctxPtr, readFn, writeFn, flushFn, &ctx)
        }
        #expect(mountRc == 0)
        guard mountRc == 0, let validCtx = ctx else { return }

        // Create file and write payload
        var fileIno: UInt64 = 0
        #expect("alpha.txt".withCString { ext4_bridge_create(validCtx, 2, $0, 0o644, &fileIno) } == 0)
        let payload = Array("Callback IO + full ext4 ops\n".utf8)
        var written = 0
        #expect(payload.withUnsafeBytes { ext4_bridge_write(validCtx, fileIno, 0, payload.count, $0.baseAddress, &written) } == 0)
        #expect(written == payload.count)

        // Set timestamps and mode
        var setAttrs = ext4_item_attrs_t()
        setAttrs.mode = 0o600
        setAttrs.mtime_sec = 1_700_000_000
        setAttrs.atime_sec = 1_700_000_123
        #expect(ext4_bridge_set_attrs(validCtx, fileIno, 0x01 | 0x08 | 0x10, &setAttrs) == 0)

        var gotAttrs = ext4_item_attrs_t()
        #expect(ext4_bridge_get_attrs(validCtx, fileIno, &gotAttrs) == 0)
        #expect((gotAttrs.mode & 0o7777) == 0o600)
        #expect(gotAttrs.mtime_sec == 1_700_000_000)
        #expect(gotAttrs.atime_sec == 1_700_000_123)

        // Fast symlink + slow symlink (> 60 bytes)
        var fastSymIno: UInt64 = 0
        #expect("sym_fast".withCString { name in
            "alpha.txt".withCString { target in
                ext4_bridge_symlink(validCtx, 2, name, target, &fastSymIno)
            }
        } == 0)
        var linkBuf = [CChar](repeating: 0, count: 256)
        var linkLen = 0
        #expect(ext4_bridge_readlink(validCtx, fastSymIno, &linkBuf, linkBuf.count, &linkLen) == 0)
        let readFast = linkBuf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        #expect(readFast == "alpha.txt")

        let longTarget = String(repeating: "sub/", count: 20) + "target.txt"
        var slowSymIno: UInt64 = 0
        #expect("sym_slow".withCString { name in
            longTarget.withCString { target in
                ext4_bridge_symlink(validCtx, 2, name, target, &slowSymIno)
            }
        } == 0)
        var slowBuf = [CChar](repeating: 0, count: 256)
        #expect(ext4_bridge_readlink(validCtx, slowSymIno, &slowBuf, slowBuf.count, &linkLen) == 0)
        let readSlow = slowBuf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        #expect(readSlow == longTarget)

        // Hard link
        #expect("alpha_hard.txt".withCString { ext4_bridge_link(validCtx, fileIno, 2, $0) } == 0)
        #expect(ext4_bridge_get_attrs(validCtx, fileIno, &gotAttrs) == 0)
        #expect(gotAttrs.link_count == 2)

        // Directories + cross-dir rename + non-empty rmdir check
        var dirA: UInt64 = 0
        var dirB: UInt64 = 0
        var subDir: UInt64 = 0
        #expect("dirA".withCString { ext4_bridge_mkdir(validCtx, 2, $0, 0o755, &dirA) } == 0)
        #expect("dirB".withCString { ext4_bridge_mkdir(validCtx, 2, $0, 0o755, &dirB) } == 0)
        #expect("nested".withCString { ext4_bridge_mkdir(validCtx, dirA, $0, 0o755, &subDir) } == 0)
        #expect("dirA".withCString { ext4_bridge_unlink(validCtx, 2, $0) } == -ENOTEMPTY)

        // Move file and nested dir into dirB via rename
        #expect("alpha_hard.txt".withCString { oldN in
            "moved.txt".withCString { newN in
                ext4_bridge_rename(validCtx, 2, oldN, dirB, newN)
            }
        } == 0)
        #expect("nested".withCString { oldN in
            "nested_moved".withCString { newN in
                ext4_bridge_rename(validCtx, dirA, oldN, dirB, newN)
            }
        } == 0)

        // Now dirA is empty and can be unlinked
        #expect("dirA".withCString { ext4_bridge_unlink(validCtx, 2, $0) } == 0)

        var movedIno: UInt64 = 0
        #expect("moved.txt".withCString { ext4_bridge_lookup(validCtx, dirB, $0, &movedIno) } == 0)
        #expect(movedIno == fileIno)

        ext4_bridge_unmount(validCtx)
        try ioCtx.fh.synchronize()

        let checkRes = try CommandRunner.run(e2fsck, arguments: ["-fn", tempURL.path])
        #expect(checkRes.exitCode == 0)
    }
}
