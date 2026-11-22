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
}
