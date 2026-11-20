import Foundation

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
    /// Formats a target partition or disk image with specified filesystem options
    public static func format(target: String, options: FormatOptions) throws -> CommandResult {
        let isBlockDevice = target.hasPrefix("/dev/")
        if isBlockDevice {
            // Strict safety check: Never format internal disks
            if let vol = DiskProbe.inspectVolume(bsdName: target),
               let disk = DiskProbe.inspectDisk(bsdName: vol.wholeDiskBSDName) {
                try SafetyPolicy.validate(disk: disk, volume: vol)
            } else if SafetyPolicy.isInternal(devicePath: target) {
                throw MontserratError.internalDiskProtected(target)
            }

            // Unmount first if mounted
            _ = try? CommandRunner.run("/usr/sbin/diskutil", arguments: ["unmount", target])
        }

        switch options.type {
        case .ext2, .ext3, .ext4:
            return try formatExt(target: target, options: options)
        case .ntfs:
            return try formatNtfs(target: target, options: options)
        default:
            throw MontserratError.unsupportedFileSystem("Formatting as \(options.type.displayName) is not supported.")
        }
    }

    private static func formatExt(target: String, options: FormatOptions) throws -> CommandResult {
        guard let mke2fs = EngineRegistry.findBinary("mke2fs") else {
            throw MontserratError.engineNotFound("mke2fs")
        }

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
            // Flash erase block alignment: 4MB stride for SD cards and USB flash drives
            // Reduces write amplification, prevents random write stall, and prolongs flash life
            args.append("-E")
            args.append("stride=1024,stripe_width=1024")
            args.append("-O")
            args.append("dir_index,extent")
        }

        args.append(target)

        // Point to custom mke2fs.conf if available
        var env: [String: String]? = nil
        let currentDir = FileManager.default.currentDirectoryPath
        let confCandidates = [
            "/usr/local/share/montserrat/conf/mke2fs.conf",
            "/opt/homebrew/share/montserrat/conf/mke2fs.conf",
            "\(currentDir)/dist/conf/mke2fs.conf",
            "\(currentDir)/engines/conf/mke2fs.conf",
            "/etc/mke2fs.conf"
        ]
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
}
