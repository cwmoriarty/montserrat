import Foundation

public struct RepairResult: Sendable {
    public let success: Bool
    public let exitCode: Int32
    public let wasClean: Bool
    public let errorsCorrected: Bool
    public let errorsUncorrected: Bool
    public let details: String

    public init(
        success: Bool,
        exitCode: Int32,
        wasClean: Bool,
        errorsCorrected: Bool,
        errorsUncorrected: Bool,
        details: String
    ) {
        self.success = success
        self.exitCode = exitCode
        self.wasClean = wasClean
        self.errorsCorrected = errorsCorrected
        self.errorsUncorrected = errorsUncorrected
        self.details = details
    }
}

public enum DiskRepairTool {
    /// Runs filesystem check or repair (e2fsck for ext2/3/4, ntfsfix for ntfs).
    /// When autoFix is false, operates strictly in read-only inspection mode (-n).
    public static func repair(target: String, force: Bool = false, autoFix: Bool = true, superblockBlock: UInt64? = nil) throws -> RepairResult {
        if MountManager.shared.isTargetMounted(target) {
            throw MontserratError.mountFailed(target, details: "Volume is currently mounted. Unmount \(target) before checking or repairing.")
        }

        let isBlockDevice = target.hasPrefix("/dev/") || target.hasPrefix("disk")
        if isBlockDevice {
            let validated = try SafetyPolicy.validateBlockDevice(target: target)
            if let vol = validated.volume, vol.isMounted {
                throw MontserratError.mountFailed(target, details: "Volume is currently mounted. Unmount \(target) before checking or repairing.")
            }
        }

        let probe = SuperblockProbe.probe(path: target)
        let kind = probe?.fileSystem ?? .unknown
        let resolvedSb = superblockBlock ?? probe?.backupSuperblockBlock

        switch kind {
        case .ext2, .ext3, .ext4:
            return try repairExt(target: target, force: force, autoFix: autoFix, superblockBlock: resolvedSb)
        case .ntfs:
            return try repairNtfs(target: target, autoFix: autoFix)
        default:
            throw MontserratError.unsupportedFileSystem("Check and repair is not supported for \(kind.displayName).")
        }
    }

    private static func repairExt(target: String, force: Bool, autoFix: Bool, superblockBlock: UInt64?) throws -> RepairResult {
        guard let e2fsck = EngineRegistry.findBinary("e2fsck") else {
            throw MontserratError.engineNotFound("e2fsck")
        }

        var args: [String] = []
        if let sb = superblockBlock {
            args.append("-b")
            args.append("\(sb)")
        }
        if autoFix {
            args.append("-p") // Preen (automatic safe repair)
        } else {
            args.append("-n") // Non-interactive read-only check
        }
        if force {
            args.append("-f") // Force checking even if marked clean
        }
        args.append(target)

        let result = try CommandRunner.run(e2fsck, arguments: args)
        let code = result.exitCode

        let wasClean = (code == 0)
        let errorsCorrected = autoFix && ((code & 1) != 0 || (code & 2) != 0)
        let errorsUncorrected = (code & 4) != 0

        let output = result.stdout.isEmpty ? result.stderr : result.stdout

        return RepairResult(
            success: code == 0 || (autoFix && (code == 1 || code == 2)),
            exitCode: code,
            wasClean: wasClean,
            errorsCorrected: errorsCorrected,
            errorsUncorrected: errorsUncorrected,
            details: output
        )
    }

    private static func repairNtfs(target: String, autoFix: Bool) throws -> RepairResult {
        guard let ntfsfix = EngineRegistry.findBinary("ntfsfix") else {
            throw MontserratError.engineNotFound("ntfsfix")
        }

        // Use -n (no-action / read-only check) when autoFix is false; use -d only when explicitly repairing
        let flag = autoFix ? "-d" : "-n"
        let result = try CommandRunner.run(ntfsfix, arguments: [flag, target])
        let code = result.exitCode
        let output = result.stdout.isEmpty ? result.stderr : result.stdout

        return RepairResult(
            success: code == 0,
            exitCode: code,
            wasClean: code == 0,
            errorsCorrected: autoFix && (code == 0),
            errorsUncorrected: code != 0,
            details: output
        )
    }
}
