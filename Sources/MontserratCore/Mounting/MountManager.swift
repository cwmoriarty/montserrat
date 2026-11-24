import Foundation
#if canImport(Darwin)
import Darwin

@_silgen_name("proc_pidpath")
private func darwin_proc_pidpath(_ pid: Int32, _ buffer: UnsafeMutableRawPointer, _ buffersize: UInt32) -> Int32
#endif

public final class MountManager: @unchecked Sendable {
    public static let shared = MountManager()

    /// Root-owned runtime state directory so non-root CLI/GUI can read daemon-mounted volumes
    /// without allowing unprivileged writes to daemon state.
    public static let systemStateDir = URL(fileURLWithPath: "\(EngineRegistry.privilegedSupportDir)/run", isDirectory: true)

    private let stateDir: URL
    private let additionalReadOnlyStateDirs: [URL]
    private let registryLock = NSLock()

    public init(stateDir: URL? = nil, additionalReadOnlyStateDirs: [URL]? = nil) {
        if let dir = stateDir {
            self.stateDir = dir
            self.additionalReadOnlyStateDirs = additionalReadOnlyStateDirs ?? []
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } else if PrivilegeManager.isRoot {
            let preferred = MountManager.systemStateDir
            if (try? FileManager.default.createDirectory(at: preferred, withIntermediateDirectories: true)) != nil {
                self.stateDir = preferred
            } else {
                let fallback = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".montserrat", isDirectory: true)
                try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
                self.stateDir = fallback
            }
            self.additionalReadOnlyStateDirs = additionalReadOnlyStateDirs ?? []
        } else {
            let userDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".montserrat", isDirectory: true)
            try? FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
            self.stateDir = userDir
            self.additionalReadOnlyStateDirs = additionalReadOnlyStateDirs ?? [MountManager.systemStateDir]
        }
    }

    private var registryFileURL: URL {
        stateDir.appendingPathComponent("mounts.json")
    }

    // MARK: - Process Verification
    /// Resolves the executable path for a running PID via Darwin proc_pidpath.
    public static func executablePath(forPID pid: Int32) -> String? {
        #if canImport(Darwin)
        guard pid > 1 else { return nil }
        var buf = [CChar](repeating: 0, count: 4096)
        let ret = buf.withUnsafeMutableBytes { rawBuf -> Int32 in
            guard let base = rawBuf.baseAddress else { return 0 }
            return darwin_proc_pidpath(pid, base, UInt32(rawBuf.count))
        }
        guard ret > 0 else { return nil }
        return buf.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return nil }
            return String(cString: base)
        }
        #else
        return nil
        #endif
    }

    /// Confirms that a PID currently belongs to the expected Montserrat engine binary
    /// before sending any termination signal. Prevents signaling unrelated processes if a PID was recycled.
    public static func isVerifiedEngineProcess(pid: Int32, expectedEnginePath: String, expectedEngineName: String) -> Bool {
        guard pid > 1 else { return false }
        guard kill(pid, 0) == 0 else { return false }
        guard let actualPath = executablePath(forPID: pid) else { return false }

        let actualResolved = URL(fileURLWithPath: actualPath).resolvingSymlinksInPath().path
        let expectedResolved = URL(fileURLWithPath: expectedEnginePath).resolvingSymlinksInPath().path
        if actualResolved == expectedResolved {
            return true
        }

        let actualName = URL(fileURLWithPath: actualPath).lastPathComponent
        var allowedNames: Set<String> = [
            "fuse2fs",
            "ntfs-3g",
            "lowntfs-3g",
            "legacyfs-mount",
            "squashfuse",
            "erofsfuse",
            "fuseiso",
            expectedEngineName
        ]
        allowedNames.formUnion(EngineRegistry.legacyFSDriverAliases)
        return allowedNames.contains(actualName)
    }

    /// Terminates a verified engine process cleanly (SIGTERM followed by SIGKILL if unresponsive).
    private func terminateEngineProcessIfVerified(_ rec: MountRecord) {
        guard Self.isVerifiedEngineProcess(pid: rec.pid, expectedEnginePath: rec.enginePath, expectedEngineName: rec.engine) else {
            return
        }
        kill(rec.pid, SIGTERM)
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            if kill(rec.pid, 0) != 0 {
                return
            }
            usleep(50_000)
        }
        if Self.isVerifiedEngineProcess(pid: rec.pid, expectedEnginePath: rec.enginePath, expectedEngineName: rec.engine) {
            kill(rec.pid, SIGKILL)
        }
    }

    /// Determines the active console user UID and GID for safe default volume ownership.
    public static func defaultConsoleOwner() -> (uid: UInt32, gid: UInt32) {
        #if canImport(Darwin)
        if geteuid() == 0 {
            var st = stat()
            if stat("/dev/console", &st) == 0 && st.st_uid != 0 {
                return (uid: st.st_uid, gid: st.st_gid)
            }
        }
        return (uid: getuid(), gid: getgid())
        #else
        return (uid: 501, gid: 20)
        #endif
    }

    // MARK: - Mount
    public func mount(_ request: MountRequest) throws -> MountRecord {
        guard EngineRegistry.isFuseTInstalled() else {
            throw MontserratError.fuseTNotInstalled
        }

        let targetPath = request.target
        let isBlockDevice = targetPath.hasPrefix("/dev/") || targetPath.hasPrefix("disk")

        // 1. Fail-closed safety validation for block devices
        var volInfo: VolumeInfo? = nil
        if isBlockDevice {
            let validated = try SafetyPolicy.validateBlockDevice(target: targetPath)
            volInfo = validated.volume
        }

        // Check if already mounted by Montserrat
        let cleanTargetBsd = DiskProbe.cleanBSDName(targetPath)
        let existingMounts = activeMounts()
        if let already = existingMounts.first(where: {
            $0.source == targetPath ||
            ($0.bsdName != nil && $0.bsdName == cleanTargetBsd) ||
            DiskProbe.cleanBSDName($0.source) == cleanTargetBsd
        }) {
            return already
        }

        // 2. Superblock probing and filesystem support check
        let probeResult = SuperblockProbe.probe(path: targetPath)
        let fsKind = probeResult?.fileSystem ?? volInfo?.fileSystem.kind ?? .unknown
        guard fsKind.isMountableByMontserrat else {
            throw MontserratError.unsupportedFileSystem(fsKind.displayName)
        }

        let effectiveReadOnly = request.readOnly || fsKind.isReadOnlySupported
        let fsState = probeResult?.state ?? volInfo?.fileSystem.state ?? .unknown
        let isUnclean = (fsState == .needsRecovery || fsState == .needsCheck || fsState == .backupSuperblockRecoverable)
        if !effectiveReadOnly && !request.allowUnclean && isUnclean {
            if request.autoRepair {
                let repairResult = try? DiskRepairTool.repair(
                    target: targetPath,
                    force: false,
                    autoFix: true,
                    superblockBlock: probeResult?.backupSuperblockBlock
                )
                if repairResult?.success != true {
                    var roReq = request
                    roReq.readOnly = true
                    return try mount(roReq)
                }
            } else {
                // Default safe behavior on unclean volumes: mount read-only without modifying disk
                var roReq = request
                roReq.readOnly = true
                return try mount(roReq)
            }
        }

        // 3. Resolve Engine (prefer upstream FUSE binary when available, then fall back to legacyfs-mount)
        var resolvedEngineName: String? = nil
        var resolvedEnginePath: String? = nil
        for candidate in fsKind.engineCandidates {
            if let found = EngineRegistry.findBinary(candidate) {
                resolvedEngineName = candidate
                resolvedEnginePath = found
                break
            }
        }
        guard let engineName = resolvedEngineName, let enginePath = resolvedEnginePath else {
            throw MontserratError.engineNotFound(fsKind.defaultEngineName ?? "unknown")
        }

        // 4. Determine Mount Point
        let rawLabel = probeResult?.label ?? volInfo?.fileSystem.label ??
                       (isBlockDevice ? URL(fileURLWithPath: targetPath).lastPathComponent : "MontserratDisk")
        let sanitizedLabel = rawLabel
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ",", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let volumeLabel = sanitizedLabel.isEmpty ? "MontserratDisk" : sanitizedLabel

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
        let resolvedMountPath = MountTable.canonicalPath(targetMountPoint.path)
        let resolvedMountURL = URL(fileURLWithPath: resolvedMountPath, isDirectory: true)

        // 5. Construct Options (least-privilege defaults: console user uid/gid, opt-in allow_other/fakeroot)
        var mountOptions: [String] = []
        if effectiveReadOnly {
            mountOptions.append("ro")
            if fsKind.isExt {
                mountOptions.append("norecovery")
            }
        } else {
            mountOptions.append("rw")
        }

        if request.allowOther {
            mountOptions.append("allow_other")
        }
        mountOptions.append("volname=\(volumeLabel)")

        if request.noAtime && !fsKind.isReadOnlySupported {
            mountOptions.append("noatime")
        }

        if fsKind.isExt {
            if request.fakeroot {
                mountOptions.append("fakeroot")
            }
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
            mountOptions.append("no_detach")
            mountOptions.append("big_writes")
            mountOptions.append("windows_names")
            mountOptions.append("auto_cache")
        }

        let resolvedOwner = request.owner ?? Self.defaultConsoleOwner()
        mountOptions.append("uid=\(resolvedOwner.uid)")
        mountOptions.append("gid=\(resolvedOwner.gid)")

        if request.allowUnclean && fsKind.isExt {
            mountOptions.append("fakerw")
        }

        let optionsString = mountOptions.joined(separator: ",")
        let logFileURL = stateDir.appendingPathComponent("\(resolvedMountURL.lastPathComponent).log")

        // 6. Execute Engine Process in foreground so process.processIdentifier tracks the live FUSE process
        let process = Process()
        process.executableURL = URL(fileURLWithPath: enginePath)
        var engineArgs: [String] = []
        let resolvedBinaryName = URL(fileURLWithPath: enginePath).lastPathComponent
        if fsKind.isExt || fsKind.isReadOnlySupported {
            engineArgs.append("-f")
        }
        if resolvedBinaryName == "legacyfs-mount", let fmtFlag = fsKind.legacyFSFormatFlag {
            engineArgs.append(contentsOf: ["-t", fmtFlag])
        }
        engineArgs.append(contentsOf: ["-o", optionsString, targetPath, resolvedMountPath])
        process.arguments = engineArgs
        process.standardInput = FileHandle.nullDevice

        FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        let logFileHandle = try? FileHandle(forWritingTo: logFileURL)
        if let fh = logFileHandle {
            process.standardOutput = fh
            process.standardError = fh
        }

        do {
            try process.run()
        } catch {
            try? logFileHandle?.close()
            if createdMountPoint {
                try? FileManager.default.removeItem(at: resolvedMountURL)
            }
            throw MontserratError.mountFailed(targetPath, details: error.localizedDescription)
        }
        try? logFileHandle?.close()

        let pid = process.processIdentifier

        // 7. Wait for mount to become active in system mount table
        var mounted = false
        var processExitedEarly = false
        let deadline = Date().addingTimeInterval(request.timeout)
        while Date() < deadline {
            if MountTable.isMountPoint(resolvedMountPath) {
                mounted = true
                break
            }
            if !process.isRunning {
                processExitedEarly = true
                break
            }
            Thread.sleep(forTimeInterval: 0.2)
        }

        guard mounted else {
            // Terminate the engine process and wait for exit before removing the mountpoint or retrying
            if process.isRunning {
                process.terminate()
                let termDeadline = Date().addingTimeInterval(2.0)
                while process.isRunning && Date() < termDeadline {
                    Thread.sleep(forTimeInterval: 0.1)
                }
                if process.isRunning && pid > 1 {
                    kill(pid, SIGKILL)
                }
                process.waitUntilExit()
            }

            if createdMountPoint {
                try? FileManager.default.removeItem(at: resolvedMountURL)
            }

            if !effectiveReadOnly {
                var roReq = request
                roReq.readOnly = true
                return try mount(roReq)
            }

            let failureReason = processExitedEarly ? "Mount process exited with status \(process.terminationStatus)" : "Mount timed out after \(request.timeout)s"
            let logContent = (try? String(contentsOf: logFileURL, encoding: .utf8)) ?? ""
            throw MontserratError.mountFailed(targetPath, details: "\(failureReason). Log: \(logContent)")
        }

        // 8. Post-Mount Optimizations
        SyncManager.shared.start()
        if request.suppressSpotlight && !effectiveReadOnly {
            suppressSpotlightIndexing(at: resolvedMountURL)
        }

        // 9. Record Mount
        let record = MountRecord(
            source: targetPath,
            bsdName: volInfo?.bsdName ?? (isBlockDevice ? cleanTargetBsd : nil),
            wholeDiskBSDName: volInfo?.wholeDiskBSDName ?? (isBlockDevice ? DiskProbe.extractWholeDiskBSDName(cleanTargetBsd) : nil),
            mountPoint: resolvedMountPath,
            fileSystem: fsKind,
            engine: engineName,
            enginePath: enginePath,
            pid: pid,
            readOnly: effectiveReadOnly,
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
        let cleanBsd = DiskProbe.cleanBSDName(target)
        let canonicalTarget = MountTable.canonicalPath(target)
        let matchingRecord = active.first {
            MountTable.canonicalPath($0.mountPoint) == canonicalTarget ||
            $0.mountPoint == target ||
            $0.source == target ||
            $0.bsdName == target ||
            $0.bsdName == cleanBsd ||
            $0.id == target
        }

        let mountPoint = matchingRecord?.mountPoint ?? canonicalTarget

        SyncManager.shared.flushBarrier(mountPoint: mountPoint)

        var unmountArgs = ["unmount"]
        if force { unmountArgs.append("force") }
        unmountArgs.append(mountPoint)

        let result = try CommandRunner.run("/usr/sbin/diskutil", arguments: unmountArgs)
        if !result.isSuccess {
            var umountArgs: [String] = []
            if force { umountArgs.append("-f") }
            umountArgs.append(mountPoint)
            let fallbackResult = try CommandRunner.run("/sbin/umount", arguments: umountArgs)
            guard fallbackResult.isSuccess else {
                let errText = fallbackResult.stderr.isEmpty ? fallbackResult.stdout : fallbackResult.stderr
                throw MontserratError.unmountFailed(mountPoint, details: errText)
            }
        }

        if let rec = matchingRecord, rec.pid > 1 {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if kill(rec.pid, 0) != 0 {
                    break
                }
                Thread.sleep(forTimeInterval: 0.2)
            }
            terminateEngineProcessIfVerified(rec)
        }

        if let rec = matchingRecord, rec.createdMountPoint {
            let url = URL(fileURLWithPath: rec.mountPoint)
            if !MountTable.isMountPoint(url.path) {
                let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
                if contents.isEmpty {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }

        if let rec = matchingRecord {
            removeMountRecord(id: rec.id)
        }
    }

    // MARK: - Eject
    public func eject(target: String) throws {
        let cleanBsd = DiskProbe.cleanBSDName(target)
        let wholeDiskBsd = DiskProbe.inspectDisk(bsdName: cleanBsd)?.bsdName ?? DiskProbe.extractWholeDiskBSDName(cleanBsd)

        for rec in activeMounts() where rec.wholeDiskBSDName == wholeDiskBsd || rec.bsdName == cleanBsd {
            try? unmount(target: rec.mountPoint)
        }

        let result = try CommandRunner.run("/usr/sbin/diskutil", arguments: ["eject", wholeDiskBsd])
        guard result.isSuccess else {
            throw MontserratError.commandFailed("diskutil eject", exitCode: result.exitCode, output: result.stderr)
        }
    }

    // MARK: - Device Disappearance / Abrupt Unplug Recovery
    public func handleDeviceDisappeared(bsdName: String) {
        let cleanBsd = DiskProbe.cleanBSDName(bsdName)
        let records = ownRecordedMounts()
        let affected = records.filter { rec in
            rec.bsdName == cleanBsd ||
            rec.wholeDiskBSDName == cleanBsd ||
            DiskProbe.cleanBSDName(rec.source) == cleanBsd
        }

        for rec in affected {
            // 1. Terminate orphaned engine process only after verifying executable identity
            terminateEngineProcessIfVerified(rec)

            // 2. Force system unmount to release VFS node
            _ = try? CommandRunner.run("/usr/sbin/diskutil", arguments: ["unmount", "force", rec.mountPoint])

            // 3. Remove mount point directory if empty and unmounted
            if rec.createdMountPoint && !MountTable.isMountPoint(rec.mountPoint) {
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

    // MARK: - Registry Persistence (Thread-Safe)
    private func decodeRecords(at fileURL: URL) -> [MountRecord] {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([MountRecord].self, from: data) else {
            return []
        }
        return list
    }

    private func ownRecordedMounts() -> [MountRecord] {
        registryLock.lock()
        defer { registryLock.unlock() }
        return decodeRecords(at: registryFileURL)
    }

    public func allRecordedMounts() -> [MountRecord] {
        registryLock.lock()
        defer { registryLock.unlock() }
        var combined = decodeRecords(at: registryFileURL)
        if additionalReadOnlyStateDirs.isEmpty {
            return combined
        }

        var seenMountPoints = Set(combined.map { MountTable.canonicalPath($0.mountPoint) })
        var seenIDs = Set(combined.map { $0.id })
        for dir in additionalReadOnlyStateDirs {
            let fileURL = dir.appendingPathComponent("mounts.json")
            for rec in decodeRecords(at: fileURL) {
                let canonMount = MountTable.canonicalPath(rec.mountPoint)
                if !seenIDs.contains(rec.id) && !seenMountPoints.contains(canonMount) {
                    combined.append(rec)
                    seenIDs.insert(rec.id)
                    seenMountPoints.insert(canonMount)
                }
            }
        }
        return combined
    }

    public func activeMounts() -> [MountRecord] {
        reconcileActiveMounts()
        let sysMounts = Set(MountTable.entries().map { MountTable.canonicalPath($0.on) })
        return allRecordedMounts().filter { sysMounts.contains(MountTable.canonicalPath($0.mountPoint)) }
    }

    /// Checks whether a target device or path currently has an active Montserrat mount.
    public func isTargetMounted(_ target: String) -> Bool {
        let cleanBsd = DiskProbe.cleanBSDName(target)
        let stdPath = MountTable.canonicalPath(target)
        for rec in activeMounts() {
            if rec.source == target ||
               MountTable.canonicalPath(rec.mountPoint) == stdPath ||
               rec.bsdName == cleanBsd ||
               DiskProbe.cleanBSDName(rec.source) == cleanBsd {
                return true
            }
        }
        return false
    }

    private func writeRegistryRecords(_ records: [MountRecord]) {
        try? JSONEncoder().encode(records).write(to: registryFileURL, options: .atomic)
        #if canImport(Darwin)
        if PrivilegeManager.isRoot {
            Darwin.chmod(registryFileURL.path, 0o644)
        }
        #endif
    }

    private func saveMountRecord(_ record: MountRecord) {
        registryLock.lock()
        defer { registryLock.unlock() }
        var records = decodeRecords(at: registryFileURL)
        records.removeAll { $0.id == record.id }
        records.append(record)
        writeRegistryRecords(records)
    }

    private func removeMountRecord(id: String) {
        registryLock.lock()
        defer { registryLock.unlock() }
        var records = decodeRecords(at: registryFileURL)
        records.removeAll { $0.id == id }
        writeRegistryRecords(records)
    }

    // MARK: - Reconcile External Ejects
    public func reconcileActiveMounts() {
        let records = ownRecordedMounts()
        let sysMounts = Set(MountTable.entries().map { MountTable.canonicalPath($0.on) })

        for rec in records {
            let stdRecMount = MountTable.canonicalPath(rec.mountPoint)
            if !sysMounts.contains(stdRecMount) {
                terminateEngineProcessIfVerified(rec)

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
