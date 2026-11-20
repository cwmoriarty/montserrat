import Foundation

public final class MountManager: Sendable {
    public static let shared = MountManager()

    private let stateDir: URL

    public init(stateDir: URL? = nil) {
        if let dir = stateDir {
            self.stateDir = dir
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.stateDir = home.appendingPathComponent(".montserrat", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.stateDir, withIntermediateDirectories: true)
    }

    private var registryFileURL: URL {
        stateDir.appendingPathComponent("mounts.json")
    }

    // MARK: - Mount
    public func mount(_ request: MountRequest) throws -> MountRecord {
        guard EngineRegistry.isFuseTInstalled() else {
            throw MontserratError.fuseTNotInstalled
        }

        let targetPath = request.target
        let isBlockDevice = targetPath.hasPrefix("/dev/")

        // 1. Probing and Safety check
        let probeResult = SuperblockProbe.probe(path: targetPath)
        let volInfo = isBlockDevice ? DiskProbe.inspectVolume(bsdName: targetPath) : nil

        let fsKind = probeResult?.fileSystem ?? volInfo?.fileSystem.kind ?? .unknown
        guard fsKind.isSupportedByMontserrat else {
            throw MontserratError.unsupportedFileSystem(fsKind.displayName)
        }

        let fsState = probeResult?.state ?? volInfo?.fileSystem.state ?? .unknown
        if !request.readOnly && !request.allowUnclean && (fsState == .needsRecovery || fsState == .needsCheck) {
            // Attempt automatic safe journal recovery before mounting read-write
            if fsKind.isExt {
                let repairResult = try? DiskRepairTool.repair(
                    target: targetPath,
                    force: false,
                    autoFix: true,
                    superblockBlock: probeResult?.backupSuperblockBlock
                )
                if repairResult?.success != true {
                    // Journal recovery failed: fall back to read-only mount
                    var roReq = request
                    roReq.readOnly = true
                    return try mount(roReq)
                }
            } else if fsKind == .ntfs {
                // Clear NTFS dirty flag before read-write mount
                let repairResult = try? DiskRepairTool.repair(
                    target: targetPath,
                    force: false,
                    autoFix: true
                )
                if repairResult?.success != true {
                    var roReq = request
                    roReq.readOnly = true
                    return try mount(roReq)
                }
            } else {
                var roReq = request
                roReq.readOnly = true
                return try mount(roReq)
            }
        }

        if let vol = volInfo, let disk = DiskProbe.inspectDisk(bsdName: vol.wholeDiskBSDName) {
            try SafetyPolicy.validate(disk: disk, volume: vol)
        }

        // 2. Resolve Engine
        guard let engineName = fsKind.defaultEngineName,
              let enginePath = EngineRegistry.findBinary(engineName) else {
            throw MontserratError.engineNotFound(fsKind.defaultEngineName ?? "unknown")
        }

        // 3. Determine Mount Point
        let rawLabel = probeResult?.label ?? volInfo?.fileSystem.label ??
                       (isBlockDevice ? URL(fileURLWithPath: targetPath).lastPathComponent : "MontserratDisk")
        let volumeLabel = rawLabel.replacingOccurrences(of: "/", with: "-")
                                  .replacingOccurrences(of: ":", with: "-")
                                  .replacingOccurrences(of: ",", with: "_")
                                  .trimmingCharacters(in: .whitespacesAndNewlines)

        let targetMountPoint: URL
        var createdMountPoint = false

        if let customPoint = request.mountPoint {
            targetMountPoint = customPoint
        } else {
            let defaultVolumes = URL(fileURLWithPath: "/Volumes", isDirectory: true)
            var candidate = defaultVolumes.appendingPathComponent(volumeLabel, isDirectory: true)
            var counter = 1
            while FileManager.default.fileExists(atPath: candidate.path) {
                candidate = defaultVolumes.appendingPathComponent("\(volumeLabel) \(counter)", isDirectory: true)
                counter += 1
            }
            targetMountPoint = candidate
        }

        if !FileManager.default.fileExists(atPath: targetMountPoint.path) {
            try FileManager.default.createDirectory(at: targetMountPoint, withIntermediateDirectories: true)
            createdMountPoint = true
        }

        // 4. Construct Options
        var mountOptions: [String] = []
        if request.readOnly {
            mountOptions.append("ro")
            if fsKind.isExt {
                mountOptions.append("norecovery")
            }
        } else {
            mountOptions.append("rw")
        }
        mountOptions.append("allow_other")
        mountOptions.append("volname=\(volumeLabel)")

        if request.noAtime {
            mountOptions.append("noatime")
        }

        if fsKind.isExt {
            // Fakeroot bypasses Linux UID mismatches so macOS users have full read-write access
            mountOptions.append("fakeroot")
            // Buffer cache and metadata caching optimization for USB and SD cards
            mountOptions.append("cache_size=\(request.cacheSize)")
            mountOptions.append("attr_timeout=5.0")
            mountOptions.append("entry_timeout=5.0")
            mountOptions.append("negative_timeout=2.0")
            mountOptions.append("max_threads=32")
            mountOptions.append("no_rofd_flush")
            mountOptions.append("auto_cache")

            if let sb = probeResult?.backupSuperblockBlock {
                mountOptions.append("sb=\(sb)")
            }
        } else if fsKind == .ntfs {
            // High throughput cluster writes and Windows naming validation
            mountOptions.append("big_writes")
            mountOptions.append("windows_names")
            mountOptions.append("auto_cache")
        }

        if let owner = request.owner {
            mountOptions.append("uid=\(owner.uid)")
            mountOptions.append("gid=\(owner.gid)")
        }

        if request.allowUnclean && fsKind.isExt {
            mountOptions.append("fakerw")
        }

        let optionsString = mountOptions.joined(separator: ",")
        let logFileURL = stateDir.appendingPathComponent("\(targetMountPoint.lastPathComponent).log")

        // 5. Execute Engine Process
        let process = Process()
        process.executableURL = URL(fileURLWithPath: enginePath)
        process.arguments = ["-o", optionsString, targetPath, targetMountPoint.path]

        // Redirect logs
        FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        if let fileHandle = try? FileHandle(forWritingTo: logFileURL) {
            process.standardOutput = fileHandle
            process.standardError = fileHandle
        }

        do {
            try process.run()
        } catch {
            if createdMountPoint {
                try? FileManager.default.removeItem(at: targetMountPoint)
            }
            throw MontserratError.mountFailed(targetPath, details: error.localizedDescription)
        }

        let pid = process.processIdentifier

        // 6. Wait for mount to become active in system mount table
        var mounted = false
        let deadline = Date().addingTimeInterval(request.timeout)
        while Date() < deadline {
            if MountTable.isMountPoint(targetMountPoint.path) {
                mounted = true
                break
            }
            // Check if process crashed immediately
            if !process.isRunning {
                break
            }
            Thread.sleep(forTimeInterval: 0.2)
        }

        guard mounted else {
            if createdMountPoint {
                try? FileManager.default.removeItem(at: targetMountPoint)
            }
            if !request.readOnly {
                if fsKind == .ntfs && !request.allowUnclean {
                    let repairResult = try? DiskRepairTool.repair(target: targetPath, force: false, autoFix: true)
                    if repairResult?.success == true {
                        var retryReq = request
                        retryReq.allowUnclean = true
                        if let retried = try? mount(retryReq) {
                            return retried
                        }
                    }
                }
                // Auto read-only fail-safe: Retry mount with read-only permissions
                var roReq = request
                roReq.readOnly = true
                return try mount(roReq)
            }
            let logContent = (try? String(contentsOf: logFileURL, encoding: .utf8)) ?? ""
            throw MontserratError.mountFailed(targetPath, details: "Mount process exited or timed out. Log: \(logContent)")
        }

        // 7. Post-Mount Optimizations (Spotlight suppression and periodic sync)
        SyncManager.shared.start()
        if request.suppressSpotlight {
            suppressSpotlightIndexing(at: targetMountPoint)
        }

        // 8. Record Mount
        let record = MountRecord(
            source: targetPath,
            bsdName: volInfo?.bsdName,
            wholeDiskBSDName: volInfo?.wholeDiskBSDName,
            mountPoint: targetMountPoint.path,
            fileSystem: fsKind,
            engine: engineName,
            enginePath: enginePath,
            pid: pid,
            readOnly: request.readOnly,
            volumeName: volumeLabel,
            logFile: logFileURL.path,
            createdMountPoint: createdMountPoint
        )

        saveMountRecord(record)
        return record
    }

    // MARK: - Unmount
    public func unmount(target: String, force: Bool = false, timeout: Double = 15.0) throws {
        let active = activeMounts()
        let matchingRecord = active.first {
            $0.mountPoint == target || $0.source == target || $0.bsdName == target || $0.id == target
        }

        let mountPoint = matchingRecord?.mountPoint ?? target

        // Force hardware barrier flush prior to unmounting
        SyncManager.shared.flushBarrier(mountPoint: mountPoint)

        var unmountArgs = ["unmount"]
        if force { unmountArgs.append("force") }
        unmountArgs.append(mountPoint)

        let result = try CommandRunner.run("/usr/sbin/diskutil", arguments: unmountArgs)
        if !result.isSuccess {
            // Fall back to /sbin/umount for local FUSE-T NFS mountpoints
            var umountArgs: [String] = []
            if force { umountArgs.append("-f") }
            umountArgs.append(mountPoint)
            let fallbackResult = try CommandRunner.run("/sbin/umount", arguments: umountArgs)
            guard fallbackResult.isSuccess else {
                let errText = fallbackResult.stderr.isEmpty ? fallbackResult.stdout : fallbackResult.stderr
                throw MontserratError.unmountFailed(mountPoint, details: errText)
            }
        }

        // If we have an active record with PID, wait for engine process to cleanly terminate
        if let rec = matchingRecord, rec.pid > 0 {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if kill(rec.pid, 0) != 0 {
                    // Process has exited
                    break
                }
                Thread.sleep(forTimeInterval: 0.2)
            }
        }

        // Clean up created directory if empty
        if let rec = matchingRecord, rec.createdMountPoint {
            let url = URL(fileURLWithPath: rec.mountPoint)
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            if contents.isEmpty {
                try? FileManager.default.removeItem(at: url)
            }
        }

        if let rec = matchingRecord {
            removeMountRecord(id: rec.id)
        }
    }

    // MARK: - Eject
    public func eject(target: String) throws {
        let cleanBsd = target.replacingOccurrences(of: "/dev/r", with: "").replacingOccurrences(of: "/dev/", with: "")
        let wholeDiskBsd = DiskProbe.inspectDisk(bsdName: cleanBsd)?.bsdName ?? cleanBsd

        // Unmount any active volumes on this disk
        for rec in activeMounts() where rec.wholeDiskBSDName == wholeDiskBsd {
            try? unmount(target: rec.mountPoint)
        }

        let result = try CommandRunner.run("/usr/sbin/diskutil", arguments: ["eject", wholeDiskBsd])
        guard result.isSuccess else {
            throw MontserratError.commandFailed("diskutil eject", exitCode: result.exitCode, output: result.stderr)
        }
    }

    // MARK: - Device Disappearance / Abrupt Unplug Recovery
    public func handleDeviceDisappeared(bsdName: String) {
        let cleanBsd = bsdName.replacingOccurrences(of: "/dev/r", with: "").replacingOccurrences(of: "/dev/", with: "")
        let records = activeMounts()
        let affected = records.filter { rec in
            rec.bsdName == cleanBsd ||
            rec.wholeDiskBSDName == cleanBsd ||
            rec.source.contains(cleanBsd)
        }

        for rec in affected {
            // 1. Terminate orphaned engine process
            if rec.pid > 0 {
                kill(rec.pid, SIGTERM)
                usleep(100_000)
                if kill(rec.pid, 0) == 0 {
                    kill(rec.pid, SIGKILL)
                }
            }

            // 2. Force system unmount to release VFS node
            _ = try? CommandRunner.run("/usr/sbin/diskutil", arguments: ["unmount", "force", rec.mountPoint])

            // 3. Remove mount point directory if empty
            if rec.createdMountPoint {
                let url = URL(fileURLWithPath: rec.mountPoint)
                let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
                if contents.isEmpty {
                    try? FileManager.default.removeItem(at: url)
                }
            }

            // 4. Clean up registry
            removeMountRecord(id: rec.id)
        }
    }

    // MARK: - Registry Persistence
    public func allRecordedMounts() -> [MountRecord] {
        guard let data = try? Data(contentsOf: registryFileURL),
              let list = try? JSONDecoder().decode([MountRecord].self, from: data) else {
            return []
        }
        return list
    }

    public func activeMounts() -> [MountRecord] {
        reconcileActiveMounts()
        return allRecordedMounts()
    }

    private func saveMountRecord(_ record: MountRecord) {
        var records = allRecordedMounts()
        records.removeAll { $0.id == record.id }
        records.append(record)
        try? JSONEncoder().encode(records).write(to: registryFileURL)
    }

    private func removeMountRecord(id: String) {
        var records = allRecordedMounts()
        records.removeAll { $0.id == id }
        try? JSONEncoder().encode(records).write(to: registryFileURL)
    }

    // MARK: - Reconcile External Ejects
    public func reconcileActiveMounts() {
        let records = allRecordedMounts()
        let sysMounts = Set(MountTable.entries().map { URL(fileURLWithPath: $0.on).standardized.path })

        for rec in records {
            let stdRecMount = URL(fileURLWithPath: rec.mountPoint).standardized.path
            if !sysMounts.contains(stdRecMount) {
                // Volume was unmounted externally (e.g. through Finder or manual umount)
                if rec.pid > 0 && kill(rec.pid, 0) == 0 {
                    kill(rec.pid, SIGTERM)
                    usleep(200_000)
                    if kill(rec.pid, 0) == 0 {
                        kill(rec.pid, SIGKILL)
                    }
                }
                if rec.createdMountPoint {
                    let url = URL(fileURLWithPath: rec.mountPoint)
                    let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
                    if contents.isEmpty {
                        try? FileManager.default.removeItem(at: url)
                    }
                }
                removeMountRecord(id: rec.id)
            }
        }
    }

    // MARK: - Flash and System Optimization
    private func suppressSpotlightIndexing(at mountURL: URL) {
        // Prevent Spotlight and fsevents from thrashing external flash storage
        let noIndexPath = mountURL.appendingPathComponent(".metadata_never_index")
        FileManager.default.createFile(atPath: noIndexPath.path, contents: nil)

        let fseventsDir = mountURL.appendingPathComponent(".fseventsd", isDirectory: true)
        try? FileManager.default.createDirectory(at: fseventsDir, withIntermediateDirectories: true)
        let noLog = fseventsDir.appendingPathComponent("no_log")
        FileManager.default.createFile(atPath: noLog.path, contents: nil)

        _ = try? CommandRunner.run("/usr/bin/mdutil", arguments: ["-i", "off", mountURL.path])
    }

    public static func isOnNetworkShare(path: String) -> Bool {
        #if canImport(Darwin)
        var s = statfs()
        if statfs(path, &s) == 0 {
            var typeName = s.f_fstypename
            let size = MemoryLayout.size(ofValue: typeName)
            let type = withUnsafePointer(to: &typeName) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: size) {
                    String(cString: $0)
                }
            }
            return type == "nfs" || type == "smbfs" || type == "afpfs"
        }
        #endif
        return false
    }
}
