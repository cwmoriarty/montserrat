import Foundation
import CAppleExplorer
#if canImport(Darwin)
import Darwin
#endif

public struct BackupVolumeSummary: Codable, Sendable, Identifiable {
    public var id: UInt32 { index }
    public let index: UInt32
    public let kind: String
    public let name: String
    public let role: String
    public let isEncrypted: Bool
    public let isTimeMachine: Bool
    public let snapshotCount: UInt32
}

public struct BackupSnapshotSummary: Codable, Sendable, Identifiable {
    public var id: String { name }
    public let xid: UInt64
    public let timestampSec: Int64
    public let name: String
}

public struct BackupBundleInfo: Codable, Sendable {
    public let target: String
    public let containerKind: String
    public let containerEncrypted: Bool
    public let virtualSize: UInt64
    public let bandSize: UInt32
    public let partitionCount: UInt32
    public let volumeCount: UInt32
    public let primaryFileSystem: String
    public let label: String
    public let hasBackupsDB: Bool
    public let hasAPFSSnapshots: Bool
    public let volumes: [BackupVolumeSummary]
    public let snapshots: [BackupSnapshotSummary]
}

public final class BackupBundleManager: @unchecked Sendable {
    public static let shared = BackupBundleManager()

    public init() {}

    private static func containerKindString(_ k: aex_container_kind_t) -> String {
        switch k {
        case AEX_CONTAINER_SPARSEBUNDLE: return "sparsebundle"
        case AEX_CONTAINER_SPARSEIMAGE:  return "sparseimage"
        case AEX_CONTAINER_UDIF_DMG:     return "udif-dmg"
        default:                         return "raw"
        }
    }

    private static func fsKindString(_ k: aex_fs_kind_t) -> String {
        switch k {
        case AEX_FS_HFS:     return "Classic HFS"
        case AEX_FS_HFSPLUS: return "HFS+"
        case AEX_FS_APFS:    return "APFS"
        default:             return "Unknown"
        }
    }

    public func inspectBackup(target: String, password: String? = nil) throws -> BackupBundleInfo {
        var cProbe = aex_probe_info_t()
        let rc: Int32 = target.withCString { cTarget in
            if let password {
                return password.withCString { cPass in
                    aex_probe_path(cTarget, cPass, &cProbe)
                }
            } else {
                return aex_probe_path(cTarget, nil, &cProbe)
            }
        }
        if rc == -EACCES {
            throw MontserratError.mountFailed(target, details: "Encrypted sparsebundle, disk image, or FileVault 2 volume requires a passphrase.")
        }
        guard rc == 0 else {
            let reason = String(cString: aex_strerror(rc))
            throw MontserratError.unsupportedFileSystem("Could not inspect backup target '\(target)': \(reason)")
        }

        let primaryLabel = withUnsafeBytes(of: cProbe.primary_label) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }

        var cVols = [aex_volume_desc_t](repeating: aex_volume_desc_t(), count: 16)
        var volCount: Int = 0
        _ = target.withCString { cTarget in
            if let password {
                return password.withCString { cPass in
                    aex_list_volumes_path(cTarget, cPass, &cVols, 16, &volCount)
                }
            } else {
                return aex_list_volumes_path(cTarget, nil, &cVols, 16, &volCount)
            }
        }

        var volumes: [BackupVolumeSummary] = []
        for i in 0..<min(volCount, 16) {
            let v = cVols[i]
            let vName = withUnsafeBytes(of: v.name) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            let vRole = withUnsafeBytes(of: v.role) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            volumes.append(BackupVolumeSummary(
                index: v.index,
                kind: Self.fsKindString(v.kind),
                name: vName,
                role: vRole,
                isEncrypted: v.is_encrypted != 0,
                isTimeMachine: v.is_time_machine != 0,
                snapshotCount: v.snapshot_count
            ))
        }

        var snapshots: [BackupSnapshotSummary] = []
        if cProbe.primary_fs != AEX_FS_UNKNOWN {
            var fsPtr: OpaquePointer?
            let openRC: Int32 = target.withCString { cTarget in
                if let password {
                    return password.withCString { cPass in
                        var opts = aex_open_options_t(partition_index: -1, volume_index: -1, snapshot_name: nil, password: cPass)
                        return aex_open_path(cTarget, &opts, &fsPtr)
                    }
                } else {
                    var opts = aex_open_options_t(partition_index: -1, volume_index: -1, snapshot_name: nil, password: nil)
                    return aex_open_path(cTarget, &opts, &fsPtr)
                }
            }
            if openRC == 0, let fs = fsPtr {
                defer { aex_close(fs) }
                var cSnaps = [aex_snapshot_desc_t](repeating: aex_snapshot_desc_t(), count: 128)
                var snapCount: Int = 0
                if aex_list_snapshots(fs, &cSnaps, 128, &snapCount) == 0 {
                    for i in 0..<min(snapCount, 128) {
                        let s = cSnaps[i]
                        let sName = withUnsafeBytes(of: s.name) { raw in
                            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
                        }
                        snapshots.append(BackupSnapshotSummary(
                            xid: s.xid,
                            timestampSec: s.timestamp_sec,
                            name: sName
                        ))
                    }
                }
            }
        }

        return BackupBundleInfo(
            target: target,
            containerKind: Self.containerKindString(cProbe.container_kind),
            containerEncrypted: cProbe.container_encrypted != 0,
            virtualSize: cProbe.virtual_size,
            bandSize: cProbe.band_size,
            partitionCount: cProbe.partition_count,
            volumeCount: cProbe.volume_count,
            primaryFileSystem: Self.fsKindString(cProbe.primary_fs),
            label: primaryLabel.isEmpty ? "MacBackup" : primaryLabel,
            hasBackupsDB: cProbe.has_backups_db != 0,
            hasAPFSSnapshots: cProbe.has_apfs_snapshots != 0,
            volumes: volumes,
            snapshots: snapshots
        )
    }

    public func extractBackupPath(
        target: String,
        sourcePath: String = "/",
        destinationPath: String,
        volumeIndex: Int = -1,
        snapshotName: String? = nil,
        password: String? = nil
    ) throws {
        var fsPtr: OpaquePointer?
        let rc: Int32 = target.withCString { cTarget in
            let openBlock: (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { cSnap, cPass in
                var opts = aex_open_options_t(
                    partition_index: -1,
                    volume_index: Int32(volumeIndex),
                    snapshot_name: cSnap,
                    password: cPass
                )
                return aex_open_path(cTarget, &opts, &fsPtr)
            }
            if let snapshotName, let password {
                return snapshotName.withCString { cs in password.withCString { cp in openBlock(cs, cp) } }
            } else if let snapshotName {
                return snapshotName.withCString { cs in openBlock(cs, nil) }
            } else if let password {
                return password.withCString { cp in openBlock(nil, cp) }
            } else {
                return openBlock(nil, nil)
            }
        }
        guard rc == 0, let fs = fsPtr else {
            throw MontserratError.mountFailed(target, details: String(cString: aex_strerror(rc)))
        }
        defer { aex_close(fs) }

        let extRC = sourcePath.withCString { cSrc in
            destinationPath.withCString { cDst in
                aex_extract_path(fs, cSrc, cDst)
            }
        }
        guard extRC == 0 else {
            throw MontserratError.commandFailed("apple-explorer extract", exitCode: 1, output: String(cString: aex_strerror(extRC)))
        }
    }

    /// Mounts a `.sparsebundle`, `.backupbundle`, `.sparseimage`, `.dmg`, `Backups.backupdb` drive, or APFS snapshot timeline read-only.
    /// If the sparsebundle contains a Linux/NTFS filesystem instead of HFS/HFS+/APFS, falls back to `montserrat-mapper --mode sparsebundle`.
    public func mountBackup(
        target: String,
        mountPoint: URL? = nil,
        volumeIndex: Int = -1,
        snapshotName: String? = nil,
        password: String? = nil
    ) throws -> UnlockedContainerSession {
        let info = try inspectBackup(target: target, password: password)

        guard EngineRegistry.isFuseTInstalled() else {
            throw MontserratError.fuseTNotInstalled
        }

        let owner = MountManager.defaultConsoleOwner()
        let stateDir = PrivilegeManager.isRoot
            ? MountManager.systemStateDir
            : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".montserrat", isDirectory: true)
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

        // Case 1: Apple HFS, HFS+ (Backups.backupdb), or APFS (+ FileVault 2 / Snapshots) -> mount directly via apple-explorer-mount
        if info.primaryFileSystem != "Unknown" {
            guard let aexMountBin = EngineRegistry.findBinary("apple-explorer-mount") else {
                throw MontserratError.engineNotFound("apple-explorer-mount")
            }

            let sanitized = info.label
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let baseLabel = sanitized.isEmpty ? "MacBackup" : sanitized

            let destURL: URL
            if let mountPoint {
                destURL = mountPoint
            } else {
                let volsRoot = URL(fileURLWithPath: "/Volumes", isDirectory: true)
                var cand = volsRoot.appendingPathComponent(baseLabel, isDirectory: true)
                var idx = 1
                while FileManager.default.fileExists(atPath: cand.path) {
                    cand = volsRoot.appendingPathComponent("\(baseLabel) \(idx)", isDirectory: true)
                    idx += 1
                }
                destURL = cand
            }
            try FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)

            var args = ["-f"]
            if volumeIndex >= 0 {
                args.append(contentsOf: ["--volume", "\(volumeIndex)"])
            }
            if let snapshotName, !snapshotName.isEmpty {
                args.append(contentsOf: ["--snapshot", snapshotName])
            }
            if password != nil {
                args.append("--password-stdin")
            }
            let opts = "ro,volname=\(baseLabel),uid=\(owner.uid),gid=\(owner.gid)"
            args.append(contentsOf: ["-o", opts, target, destURL.path])

            let stdinPipe = Pipe()
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: aexMountBin)
            proc.arguments = args
            proc.standardInput = (password != nil) ? stdinPipe : FileHandle.nullDevice
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try proc.run()

            if let password, let pwData = (password + "\n").data(using: .utf8) {
                try? stdinPipe.fileHandleForWriting.write(contentsOf: pwData)
                try? stdinPipe.fileHandleForWriting.close()
            }

            let deadline = Date().addingTimeInterval(20.0)
            var mounted = false
            while Date() < deadline {
                if MountTable.isMountPoint(destURL.path) {
                    mounted = true
                    break
                }
                if !proc.isRunning { break }
                Thread.sleep(forTimeInterval: 0.15)
            }
            guard mounted else {
                if proc.isRunning { proc.terminate() }
                try? FileManager.default.removeItem(at: destURL)
                throw MontserratError.mountFailed(target, details: "Timed out waiting for apple-explorer-mount on \(destURL.path).")
            }

            let shortID = String(UUID().uuidString.prefix(8)).lowercased()
            let session = UnlockedContainerSession(
                id: "backup-\(shortID)",
                source: target,
                containerKind: info.containerKind,
                volumeName: baseLabel,
                mapperMountPoint: destURL.path,
                virtualBlockPath: target,
                pid: proc.processIdentifier,
                readOnly: true,
                innerFileSystem: info.primaryFileSystem,
                mountedVolumePoint: destURL.path
            )
            ContainerManager.shared.registerExternalSession(session)
            return session
        }

        // Case 2: Non-Apple filesystem inside a .sparsebundle/.sparseimage/.dmg -> expose bundle.raw via montserrat-mapper --mode sparsebundle
        guard let mapperBin = EngineRegistry.findBinary("montserrat-mapper") else {
            throw MontserratError.engineNotFound("montserrat-mapper")
        }
        let shortID = String(UUID().uuidString.prefix(8)).lowercased()
        let mapperBase = stateDir.appendingPathComponent("mapper/bundle-\(shortID)", isDirectory: true)
        try FileManager.default.createDirectory(at: mapperBase, withIntermediateDirectories: true)

        var args = ["-f", "--mode", "sparsebundle", "--ro", "--name", "bundle.raw", "--uid", "\(owner.uid)", "--gid", "\(owner.gid)"]
        if password != nil { args.append("--passphrase-stdin") }
        args.append(contentsOf: [target, mapperBase.path])

        let stdinPipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: mapperBin)
        proc.arguments = args
        proc.standardInput = (password != nil) ? stdinPipe : FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()

        if let password, let pwData = (password + "\n").data(using: .utf8) {
            try? stdinPipe.fileHandleForWriting.write(contentsOf: pwData)
            try? stdinPipe.fileHandleForWriting.close()
        }

        let virtualPath = mapperBase.appendingPathComponent("bundle.raw").path
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
            throw MontserratError.mountFailed(target, details: "Timed out waiting for montserrat-mapper sparsebundle stream.")
        }

        let innerProbe = SuperblockProbe.probe(path: virtualPath)
        var session = UnlockedContainerSession(
            id: "bundle-\(shortID)",
            source: target,
            containerKind: info.containerKind,
            volumeName: info.label,
            mapperMountPoint: mapperBase.path,
            virtualBlockPath: virtualPath,
            pid: proc.processIdentifier,
            readOnly: true,
            innerFileSystem: innerProbe?.fileSystem.displayName,
            mountedVolumePoint: nil
        )
        if let inner = innerProbe, inner.fileSystem.isMountableByMontserrat {
            let mntReq = MountRequest(target: virtualPath, readOnly: true, mountPoint: mountPoint)
            if let rec = try? MountManager.shared.mount(mntReq) {
                session.mountedVolumePoint = rec.mountPoint
            }
        }
        ContainerManager.shared.registerExternalSession(session)
        return session
    }
}
