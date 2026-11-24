import Foundation
import CCowFS
#if canImport(Darwin)
import Darwin
#endif

public struct LUKSContainerInfo: Codable, Sendable {
    public let version: Int
    public let cipher: String
    public let cipherMode: String
    public let hashSpec: String
    public let payloadOffset: UInt64
    public let payloadBytes: UInt64
    public let sectorSize: UInt32
    public let keyBytes: UInt32
    public let activeSlots: Int
    public let uuid: String
    public let label: String?
}

public struct LVMLogicalVolumeInfo: Codable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let sizeBytes: UInt64
    public let pvByteOffset: UInt64
    public let innerFileSystem: String?
    public let innerLabel: String?
}

public struct LVMVolumeGroupInfo: Codable, Sendable {
    public let vgName: String
    public let pvUUID: String
    public let extentBytes: UInt64
    public let logicalVolumes: [LVMLogicalVolumeInfo]
}

public struct UnlockedContainerSession: Codable, Sendable, Identifiable {
    public let id: String
    public let source: String
    public let containerKind: String
    public let volumeName: String
    public let mapperMountPoint: String
    public let virtualBlockPath: String
    public let pid: Int32
    public let readOnly: Bool
    public let innerFileSystem: String?
    public var mountedVolumePoint: String?
}

private final class LUKSDecryptedReader: SuperblockReadable {
    let ctx: OpaquePointer
    let maxBytes: UInt64

    init(ctx: OpaquePointer) {
        self.ctx = ctx
        self.maxBytes = cowfs_luks_size(ctx)
    }

    func readBytes(offset: UInt64, length: Int) -> Data? {
        guard length > 0, offset + UInt64(length) <= maxBytes else { return nil }
        var buf = [UInt8](repeating: 0, count: length)
        let rc = cowfs_luks_pread(ctx, offset, length, &buf)
        guard rc == 0 else { return nil }
        return Data(buf)
    }
}

private struct OffsetSliceReader: SuperblockReadable {
    let baseReader: DeviceReader
    let baseOffset: UInt64
    let sliceBytes: UInt64

    func readBytes(offset: UInt64, length: Int) -> Data? {
        guard length > 0, offset + UInt64(length) <= sliceBytes else { return nil }
        return baseReader.readBytes(offset: baseOffset + offset, length: length)
    }
}

public final class ContainerManager: @unchecked Sendable {
    public static let shared = ContainerManager()

    private let stateDir: URL
    private let lock = NSLock()

    public init(stateDir: URL? = nil) {
        if let stateDir {
            self.stateDir = stateDir
        } else if PrivilegeManager.isRoot {
            self.stateDir = MountManager.systemStateDir
        } else {
            self.stateDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".montserrat", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.stateDir, withIntermediateDirectories: true)
    }

    private var sessionsFileURL: URL {
        stateDir.appendingPathComponent("containers.json")
    }

    // MARK: - LUKS1 / LUKS2 Inspection & Unlock
    public func inspectLUKS(target: String) throws -> LUKSContainerInfo {
        var cInfo = cowfs_luks_info_t()
        let rc = target.withCString { cowfs_luks_probe($0, &cInfo) }
        guard rc == 0 else {
            throw MontserratError.unsupportedFileSystem("Target \(target) does not contain a valid LUKS1 or LUKS2 header.")
        }

        let cipher = withUnsafeBytes(of: cInfo.cipher) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        let mode = withUnsafeBytes(of: cInfo.cipher_mode) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        let hash = withUnsafeBytes(of: cInfo.hash_spec) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        let uuid = withUnsafeBytes(of: cInfo.uuid) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        let label = withUnsafeBytes(of: cInfo.label) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }

        return LUKSContainerInfo(
            version: Int(cInfo.version),
            cipher: cipher,
            cipherMode: mode,
            hashSpec: hash,
            payloadOffset: cInfo.payload_offset,
            payloadBytes: cInfo.payload_bytes,
            sectorSize: cInfo.sector_size,
            keyBytes: cInfo.key_bytes,
            activeSlots: Int(cInfo.active_slots),
            uuid: uuid,
            label: label.isEmpty ? nil : label
        )
    }

    public func formatLUKS(target: String, passphrase: String, label: String = "", totalBytesIfFile: UInt64 = 0) throws {
        let isBlockDevice = target.hasPrefix("/dev/") || target.hasPrefix("disk")
        if isBlockDevice {
            _ = try SafetyPolicy.validateBlockDevice(target: target)
        }
        let rc = target.withCString { cTarget in
            passphrase.withCString { cPass in
                label.withCString { cLabel in
                    cowfs_luks_format(cTarget, cPass, cLabel, totalBytesIfFile)
                }
            }
        }
        guard rc == 0 else {
            throw MontserratError.commandFailed("luks format", exitCode: 1, output: String(cString: strerror(-rc)))
        }
    }

    /// Unlocks a LUKS1/LUKS2 container in-process to verify the passphrase and inspect the inner superblock.
    public func probeUnlockedLUKSPayload(target: String, passphrase: String) throws -> ProbeResult? {
        var ctx: OpaquePointer?
        let rc = target.withCString { cTarget in
            passphrase.withCString { cPass in
                cowfs_luks_unlock(cTarget, cPass, 1, &ctx)
            }
        }
        if rc == -EACCES {
            throw MontserratError.mountFailed(target, details: "Invalid LUKS passphrase.")
        }
        if rc == -ENOTSUP {
            throw MontserratError.unsupportedFileSystem("LUKS container uses an unsupported KDF or cipher (PBKDF2 + AES-XTS-Plain64 supported natively).")
        }
        guard rc == 0, let validCtx = ctx else {
            throw MontserratError.mountFailed(target, details: "LUKS unlock failed: \(String(cString: strerror(-rc)))")
        }
        defer { cowfs_luks_close(validCtx) }
        return SuperblockProbe.probe(reader: LUKSDecryptedReader(ctx: validCtx))
    }

    /// Unlocks a LUKS container via `montserrat-mapper` and optionally mounts the inner filesystem.
    public func unlockLUKS(
        target: String,
        passphrase: String,
        readOnly: Bool = false,
        mountInnerVolume: Bool = true
    ) throws -> UnlockedContainerSession {
        let isBlockDevice = target.hasPrefix("/dev/") || target.hasPrefix("disk")
        if isBlockDevice {
            _ = try SafetyPolicy.validateBlockDevice(target: target)
        }

        // Verify passphrase and probe inner filesystem before spawning mapper
        let innerProbe = try probeUnlockedLUKSPayload(target: target, passphrase: passphrase)

        guard EngineRegistry.isFuseTInstalled() else {
            throw MontserratError.fuseTNotInstalled
        }
        guard let mapperBin = EngineRegistry.findBinary("montserrat-mapper") else {
            throw MontserratError.engineNotFound("montserrat-mapper")
        }

        let info = try inspectLUKS(target: target)
        let shortID = String((info.uuid.isEmpty ? UUID().uuidString : info.uuid).prefix(8))
        let mapperBase = stateDir.appendingPathComponent("mapper/luks-\(shortID)", isDirectory: true)
        try FileManager.default.createDirectory(at: mapperBase, withIntermediateDirectories: true)

        let owner = MountManager.defaultConsoleOwner()
        var args = ["-f", "--mode", "luks", "--uid", "\(owner.uid)", "--gid", "\(owner.gid)"]
        if readOnly { args.append("--ro") }
        args.append(contentsOf: [target, mapperBase.path])

        let stdinPipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: mapperBin)
        proc.arguments = args
        proc.standardInput = stdinPipe
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        try proc.run()
        if let passData = (passphrase + "\n").data(using: .utf8) {
            try? stdinPipe.fileHandleForWriting.write(contentsOf: passData)
        }
        try? stdinPipe.fileHandleForWriting.close()

        let virtualPath = mapperBase.appendingPathComponent("volume.raw").path
        let deadline = Date().addingTimeInterval(15.0)
        var ready = false
        while Date() < deadline {
            if MountTable.isMountPoint(mapperBase.path) && FileManager.default.fileExists(atPath: virtualPath) {
                ready = true
                break
            }
            if !proc.isRunning {
                break
            }
            Thread.sleep(forTimeInterval: 0.15)
        }

        guard ready else {
            if proc.isRunning { proc.terminate() }
            try? FileManager.default.removeItem(at: mapperBase)
            throw MontserratError.mountFailed(target, details: "Timed out waiting for montserrat-mapper to expose decrypted block device.")
        }

        var session = UnlockedContainerSession(
            id: "luks-\(shortID)",
            source: target,
            containerKind: "LUKS\(info.version)",
            volumeName: info.label ?? "LUKS-\(shortID)",
            mapperMountPoint: mapperBase.path,
            virtualBlockPath: virtualPath,
            pid: proc.processIdentifier,
            readOnly: readOnly,
            innerFileSystem: innerProbe?.fileSystem.displayName,
            mountedVolumePoint: nil
        )

        if mountInnerVolume, let inner = innerProbe, inner.fileSystem.isMountableByMontserrat {
            let mntReq = MountRequest(target: virtualPath, readOnly: readOnly || inner.fileSystem.isReadOnlySupported)
            if let mntRec = try? MountManager.shared.mount(mntReq) {
                session.mountedVolumePoint = mntRec.mountPoint
            }
        }

        saveSession(session)
        return session
    }

    // MARK: - LVM2 Volume Group Scan & Activation
    public func scanLVM2(target: String) throws -> LVMVolumeGroupInfo {
        var cVg = cowfs_lvm_vg_info_t()
        let rc = target.withCString { cowfs_lvm_scan($0, &cVg) }
        guard rc == 0 else {
            throw MontserratError.unsupportedFileSystem("Target \(target) does not contain a valid LVM2 physical volume label.")
        }

        let vgName = withUnsafeBytes(of: cVg.vg_name) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        let pvUUID = withUnsafeBytes(of: cVg.pv_uuid) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }

        let devReader = DeviceReader(path: target)
        defer { devReader?.close() }

        var lvs: [LVMLogicalVolumeInfo] = []
        let count = Int(min(cVg.lv_count, 16))
        withUnsafePointer(to: &cVg.lvs) { tuplePtr in
            let base = UnsafeRawPointer(tuplePtr).assumingMemoryBound(to: cowfs_lvm_lv_t.self)
            for i in 0..<count {
                let item = base[i]
                let lvName = withUnsafeBytes(of: item.name) { raw in
                    String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
                }
                var innerFS: String? = nil
                var innerLabel: String? = nil
                if let devReader {
                    let slice = OffsetSliceReader(baseReader: devReader, baseOffset: item.pv_byte_offset, sliceBytes: item.size_bytes)
                    if let probed = SuperblockProbe.probe(reader: slice) {
                        innerFS = probed.fileSystem.displayName
                        innerLabel = probed.label
                    }
                }
                lvs.append(LVMLogicalVolumeInfo(
                    name: lvName,
                    sizeBytes: item.size_bytes,
                    pvByteOffset: item.pv_byte_offset,
                    innerFileSystem: innerFS,
                    innerLabel: innerLabel
                ))
            }
        }

        return LVMVolumeGroupInfo(
            vgName: vgName,
            pvUUID: pvUUID,
            extentBytes: cVg.extent_bytes,
            logicalVolumes: lvs
        )
    }

    public func activateLVM2(
        target: String,
        lvName: String? = nil,
        readOnly: Bool = false,
        mountVolumes: Bool = true
    ) throws -> [UnlockedContainerSession] {
        let isBlockDevice = target.hasPrefix("/dev/") || target.hasPrefix("disk")
        if isBlockDevice {
            _ = try SafetyPolicy.validateBlockDevice(target: target)
        }

        let vg = try scanLVM2(target: target)
        let selectedLVs = vg.logicalVolumes.filter { lvName == nil || $0.name == lvName }
        guard !selectedLVs.isEmpty else {
            throw MontserratError.diskNotFound("No matching logical volumes found in volume group '\(vg.vgName)'.")
        }

        guard EngineRegistry.isFuseTInstalled() else {
            throw MontserratError.fuseTNotInstalled
        }
        guard let mapperBin = EngineRegistry.findBinary("montserrat-mapper") else {
            throw MontserratError.engineNotFound("montserrat-mapper")
        }

        let owner = MountManager.defaultConsoleOwner()
        var activated: [UnlockedContainerSession] = []

        for lv in selectedLVs {
            let sessionID = "lvm-\(vg.vgName)-\(lv.name)"
            let mapperBase = stateDir.appendingPathComponent("mapper/\(sessionID)", isDirectory: true)
            try FileManager.default.createDirectory(at: mapperBase, withIntermediateDirectories: true)

            let rawFileName = "\(lv.name).raw"
            var args = [
                "-f", "--mode", "lvm",
                "--offset", "\(lv.pvByteOffset)",
                "--size", "\(lv.sizeBytes)",
                "--name", rawFileName,
                "--uid", "\(owner.uid)",
                "--gid", "\(owner.gid)"
            ]
            if readOnly { args.append("--ro") }
            args.append(contentsOf: [target, mapperBase.path])

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: mapperBin)
            proc.arguments = args
            proc.standardInput = FileHandle.nullDevice
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try proc.run()

            let virtualPath = mapperBase.appendingPathComponent(rawFileName).path
            let deadline = Date().addingTimeInterval(15.0)
            var ready = false
            while Date() < deadline {
                if MountTable.isMountPoint(mapperBase.path) && FileManager.default.fileExists(atPath: virtualPath) {
                    ready = true
                    break
                }
                if !proc.isRunning { break }
                Thread.sleep(forTimeInterval: 0.15)
            }
            guard ready else {
                if proc.isRunning { proc.terminate() }
                try? FileManager.default.removeItem(at: mapperBase)
                continue
            }

            var session = UnlockedContainerSession(
                id: sessionID,
                source: target,
                containerKind: "LVM2",
                volumeName: "\(vg.vgName)/\(lv.name)",
                mapperMountPoint: mapperBase.path,
                virtualBlockPath: virtualPath,
                pid: proc.processIdentifier,
                readOnly: readOnly,
                innerFileSystem: lv.innerFileSystem,
                mountedVolumePoint: nil
            )

            if mountVolumes, let innerProbe = SuperblockProbe.probe(path: virtualPath), innerProbe.fileSystem.isMountableByMontserrat {
                let req = MountRequest(target: virtualPath, readOnly: readOnly || innerProbe.fileSystem.isReadOnlySupported)
                if let rec = try? MountManager.shared.mount(req) {
                    session.mountedVolumePoint = rec.mountPoint
                }
            }

            saveSession(session)
            activated.append(session)
        }

        return activated
    }

    // MARK: - Lock / Deactivate Sessions
    public func activeSessions() -> [UnlockedContainerSession] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: sessionsFileURL),
              let list = try? JSONDecoder().decode([UnlockedContainerSession].self, from: data) else {
            return []
        }
        let sysMounts = Set(MountTable.entries().map { MountTable.canonicalPath($0.on) })
        return list.filter { sysMounts.contains(MountTable.canonicalPath($0.mapperMountPoint)) }
    }

    public func closeContainer(targetOrID: String) throws {
        let active = activeSessions()
        let matches = active.filter {
            $0.id == targetOrID ||
            $0.source == targetOrID ||
            $0.mapperMountPoint == targetOrID ||
            $0.virtualBlockPath == targetOrID
        }
        guard !matches.isEmpty else {
            throw MontserratError.diskNotFound("No active unlocked LUKS or LVM2 container matches '\(targetOrID)'.")
        }

        for session in matches {
            if let innerMount = session.mountedVolumePoint {
                try? MountManager.shared.unmount(target: innerMount, force: true)
            } else {
                try? MountManager.shared.unmount(target: session.virtualBlockPath, force: true)
            }

            let unmountRes = try? CommandRunner.run("/usr/sbin/diskutil", arguments: ["unmount", "force", session.mapperMountPoint])
            if unmountRes?.isSuccess != true {
                _ = try? CommandRunner.run("/sbin/umount", arguments: ["-f", session.mapperMountPoint])
            }
            if session.pid > 1 && MountManager.isVerifiedEngineProcess(
                pid: session.pid,
                expectedEnginePath: "montserrat-mapper",
                expectedEngineName: "montserrat-mapper"
            ) {
                kill(session.pid, SIGTERM)
            }
            try? FileManager.default.removeItem(atPath: session.mapperMountPoint)
            removeSession(id: session.id)
        }
    }

    private func saveSession(_ session: UnlockedContainerSession) {
        lock.lock()
        defer { lock.unlock() }
        var list = (try? JSONDecoder().decode([UnlockedContainerSession].self, from: Data(contentsOf: sessionsFileURL))) ?? []
        list.removeAll { $0.id == session.id }
        list.append(session)
        try? JSONEncoder().encode(list).write(to: sessionsFileURL, options: .atomic)
    }

    private func removeSession(id: String) {
        lock.lock()
        defer { lock.unlock() }
        guard var list = try? JSONDecoder().decode([UnlockedContainerSession].self, from: Data(contentsOf: sessionsFileURL)) else {
            return
        }
        list.removeAll { $0.id == id }
        try? JSONEncoder().encode(list).write(to: sessionsFileURL, options: .atomic)
    }
}
