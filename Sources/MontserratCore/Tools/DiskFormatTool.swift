import Foundation
import CCowFS
#if canImport(Darwin)
import Darwin
#endif

public struct FormatOptions: Sendable {
    public let type: FileSystemKind
    public let label: String
    public let blockSize: Int?
    public let force: Bool
    public let isFlashOptimized: Bool

    public init(
        type: FileSystemKind = .ext4,
        label: String = "Montserrat",
        blockSize: Int? = 4096,
        force: Bool = false,
        isFlashOptimized: Bool = false
    ) {
        self.type = type
        self.label = label
        self.blockSize = blockSize
        self.force = force
        self.isFlashOptimized = isFlashOptimized
    }
}

public enum DiskFormatTool {
    /// Formats a target partition or disk image with specified filesystem options.
    /// Refuses to format internal/protected disks or currently mounted volumes.
    public static func format(target: String, options: FormatOptions) throws -> CommandResult {
        if MountManager.shared.isTargetMounted(target) {
            throw MontserratError.mountFailed(target, details: "Volume is currently mounted. Unmount \(target) before formatting.")
        }

        let isBlockDevice = target.hasPrefix("/dev/") || target.hasPrefix("disk")
        if isBlockDevice {
            let validated = try SafetyPolicy.validateBlockDevice(target: target)
            if let vol = validated.volume, vol.isMounted {
                throw MontserratError.mountFailed(target, details: "Volume is currently mounted. Unmount \(target) before formatting.")
            }
        }

        switch options.type {
        case .ext2, .ext3, .ext4:
            return try formatExt(target: target, options: options)
        case .ntfs:
            return try formatNtfs(target: target, options: options)
        case .xfs:
            return try formatCowFS(target: target, kind: COWFS_KIND_XFS, binaryName: "mkxfs", defaultUnit: 4096, options: options)
        case .btrfs:
            return try formatCowFS(target: target, kind: COWFS_KIND_BTRFS, binaryName: "mkbtrfs", defaultUnit: 16384, options: options)
        default:
            throw MontserratError.unsupportedFileSystem("Formatting as \(options.type.displayName) is not supported.")
        }
    }

    /// Clears leading boot-sector and primary superblock signatures (first 128 KiB)
    /// so stale signatures from a previous filesystem (e.g., NTFS VBR at offset 0)
    /// do not shadow a newly formatted filesystem.
    private static func wipeLeadingSignatures(at target: String) {
        #if canImport(Darwin)
        let fd = Darwin.open(target, O_WRONLY)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }

        let chunkSize = 4096
        let totalBytes = 131_072
        let zeros = [UInt8](repeating: 0, count: chunkSize)
        var offset: off_t = 0

        zeros.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            while offset < totalBytes {
                let written = Darwin.pwrite(fd, base, chunkSize, offset)
                if written <= 0 {
                    break
                }
                offset += off_t(written)
            }
        }
        _ = Darwin.fsync(fd)
        #endif
    }

    private static func formatExt(target: String, options: FormatOptions) throws -> CommandResult {
        guard let mke2fs = EngineRegistry.findBinary("mke2fs") else {
            throw MontserratError.engineNotFound("mke2fs")
        }

        wipeLeadingSignatures(at: target)

        var args: [String] = []
        let typeStr: String
        switch options.type {
        case .ext2: typeStr = "ext2"
        case .ext3: typeStr = "ext3"
        default:    typeStr = "ext4"
        }

        args.append("-t")
        args.append(typeStr)

        if options.force {
            args.append("-F")
        }

        args.append("-L")
        args.append(options.label)

        if let bs = options.blockSize {
            args.append("-b")
            args.append("\(bs)")
        }

        if options.isFlashOptimized {
            args.append("-E")
            args.append("stride=1024,stripe_width=1024")
            args.append("-O")
            args.append("dir_index,extent")
        }

        args.append(target)

        var env: [String: String]? = nil
        let currentDir = FileManager.default.currentDirectoryPath
        var confCandidates = [
            "\(EngineRegistry.privilegedSupportDir)/conf/mke2fs.conf",
            "/usr/local/share/montserrat/conf/mke2fs.conf",
            "/opt/homebrew/opt/montserrat/conf/mke2fs.conf",
            "/opt/homebrew/share/montserrat/conf/mke2fs.conf"
        ]
        if let resDir = Bundle.main.resourceURL?.path {
            confCandidates.append("\(resDir)/conf/mke2fs.conf")
        }
        if let execDir = Bundle.main.executableURL?.deletingLastPathComponent().path {
            confCandidates.append("\(execDir)/../conf/mke2fs.conf")
            confCandidates.append("\(execDir)/../Resources/conf/mke2fs.conf")
        }
        confCandidates.append(contentsOf: [
            "\(currentDir)/dist/conf/mke2fs.conf",
            "\(currentDir)/engines/conf/mke2fs.conf",
            "/etc/mke2fs.conf"
        ])

        if let confPath = confCandidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            env = ["MKE2FS_CONFIG": confPath]
        }

        let result = try CommandRunner.run(mke2fs, arguments: args, environment: env)
        guard result.isSuccess else {
            throw MontserratError.commandFailed("mke2fs", exitCode: result.exitCode, output: result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        return result
    }

    private static func formatNtfs(target: String, options: FormatOptions) throws -> CommandResult {
        guard let mkntfs = EngineRegistry.findBinary("mkntfs") else {
            throw MontserratError.engineNotFound("mkntfs")
        }

        wipeLeadingSignatures(at: target)

        var args: [String] = []
        if options.force {
            args.append("-F")
        }
        args.append("-f") // Quick format
        args.append("-L")
        args.append(options.label)
        args.append(target)

        let result = try CommandRunner.run(mkntfs, arguments: args)
        guard result.isSuccess else {
            throw MontserratError.commandFailed("mkntfs", exitCode: result.exitCode, output: result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        return result
    }

    private static func formatCowFS(
        target: String,
        kind: cowfs_kind_t,
        binaryName: String,
        defaultUnit: Int,
        options: FormatOptions
    ) throws -> CommandResult {
        wipeLeadingSignatures(at: target)
        let unitSize: Int
        if kind == COWFS_KIND_BTRFS {
            let candidate = options.blockSize ?? defaultUnit
            unitSize = candidate >= 4096 ? max(candidate, 16384) : defaultUnit
        } else {
            unitSize = options.blockSize ?? defaultUnit
        }

        if let bin = EngineRegistry.findBinary(binaryName) {
            var args: [String] = []
            if options.force {
                args.append("-f")
            }
            args.append(contentsOf: ["-L", options.label, "-b", "\(unitSize)", target])
            let result = try CommandRunner.run(bin, arguments: args)
            guard result.isSuccess else {
                throw MontserratError.commandFailed(binaryName, exitCode: result.exitCode, output: result.stderr.isEmpty ? result.stdout : result.stderr)
            }
            return result
        }

        let rc = target.withCString { cTarget in
            options.label.withCString { cLabel in
                cowfs_mkfs(kind, cTarget, cLabel, UInt32(unitSize))
            }
        }
        guard rc == 0 else {
            let msg = String(cString: strerror(-rc))
            throw MontserratError.commandFailed(binaryName, exitCode: 1, output: msg)
        }
        return CommandResult(exitCode: 0, stdout: "Formatted \(target) as \(options.type.displayName)", stderr: "")
    }
}
