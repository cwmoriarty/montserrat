import Foundation
import MontserratCore
#if canImport(Darwin)
import Darwin
#endif

struct MontserratCLI {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard !args.isEmpty else {
            printUsage()
            exit(0)
        }

        let command = args[0]
        let subArgs = Array(args.dropFirst())

        do {
            switch command {
            case "list":
                try handleList(args: subArgs)
            case "probe":
                try handleProbe(args: subArgs)
            case "mount":
                try handleMount(args: subArgs)
            case "unmount", "umount":
                try handleUnmount(args: subArgs)
            case "eject":
                try handleEject(args: subArgs)
            case "status":
                try handleStatus(args: subArgs)
            case "check", "fsck":
                try handleCheck(args: subArgs)
            case "repair":
                try handleRepair(args: subArgs)
            case "format", "mkfs":
                try handleFormat(args: subArgs)
            case "daemon":
                try handleDaemon(args: subArgs)
            case "share-nfs":
                try handleShareNFS(args: subArgs)
            case "unshare-nfs":
                try handleUnshareNFS(args: subArgs)
            case "list-nfs":
                handleListNFS()
            case "engines":
                handleEngines()
            case "install-fuse-t":
                try handleInstallFuseT()
            case "-h", "--help", "help":
                printUsage()
            case "-v", "--version", "version":
                let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.2"
                print("montserrat version \(version) (macOS 13+)")
            default:
                print("Unknown command: \(command)\n")
                printUsage()
                exit(1)
            }
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    static func printUsage() {
        print("""
        montserrat - Native Linux and NTFS filesystem tool for macOS 13+

        Usage: montserrat <command> [options]

        Commands:
          list [--all] [--json]            List external disks and partitions (--all: include internal)
          probe <disk|file> [--json]       Inspect superblock across 40+ filesystems and containers
          mount <disk|file> [options]      Mount ext2/3/4 or NTFS read-write, or archival formats read-only
          unmount <disk|mountpoint>        Unmount cleanly and flush cache buffers
          eject <disk>                     Unmount all partitions and eject the disk safely
          status [--json]                  Show volumes currently mounted by Montserrat
          check <disk|file> [--force]      Read-only filesystem consistency check (e2fsck -n / ntfsfix -n)
          repair <disk|file> [--force]     Repair filesystem errors (e2fsck -p / ntfsfix -d)
          format <disk|file> [options]     Format partition (ext4, ext3, ext2, ntfs)
          share-nfs <mountpoint> [options] Export mounted volume over NFS via nfsd
          unshare-nfs <mountpoint>         Remove volume from NFS exports
          list-nfs                         List configured NFS exports
          daemon [start|install|uninstall|status] Manage auto-mount background daemon
          engines                          Check status and paths of filesystem engines
          install-fuse-t                   Install bundled FUSE-T runtime package

        Mount Options:
          --read-only, -r                  Mount in read-only mode
          --at <path>                      Custom mount point directory
          --auto-repair                    Run automatic repair before mounting if volume is unclean
          --allow-unclean                  Mount even if journal replay or fsck is needed
          --allow-other                    Allow other local macOS user accounts to access the mount
          --fakeroot                       Enable ext4 fakeroot ownership mapping
          --timeout <seconds>              Mount timeout in seconds (default: 30)

        Format Options:
          --type <ext4|ext3|ext2|ntfs>     Filesystem type (default: ext4)
          --label <Name>                   Volume label (default: Montserrat)
          --block-size <1024|2048|4096>    Block size in bytes (default: 4096)
          --flash                          Align ext4 stride (4MB) for SD cards and USB flash media
          --force                          Pass force flag to underlying mkfs utility
          --yes, -y                        Confirm destructive format without interactive prompt

        Examples:
          montserrat list
          montserrat probe /dev/disk4s1
          montserrat mount /dev/disk4s1
          montserrat check /dev/disk4s1
          montserrat repair /dev/disk4s1
          montserrat format /dev/disk4s1 --type ext4 --label "LinuxBackup" --yes
          montserrat daemon status
        """)
    }

    // MARK: - Handlers
    static func handleList(args: [String]) throws {
        let includeAll = args.contains("--all")
        let asJson = args.contains("--json")

        let disks = DiskProbe.listDisks(includeInternal: includeAll)

        if asJson {
            let data = try JSONEncoder().encode(disks)
            if let str = String(data: data, encoding: .utf8) {
                print(str)
            }
            return
        }

        if disks.isEmpty {
            print("No external disks found.")
            return
        }

        for disk in disks {
            let sizeGb = String(format: "%.1f GB", Double(disk.size) / 1_000_000_000.0)
            let conn = disk.connection ?? "Unknown"
            print("Disk /dev/\(disk.bsdName) [\(disk.name), \(sizeGb), \(conn)]:")

            if disk.volumes.isEmpty {
                print("  (no partitions)")
                continue
            }

            for vol in disk.volumes {
                let partSizeMb = String(format: "%.1f MB", Double(vol.size) / 1_000_000.0)
                let fs = vol.fileSystem.kind.displayName
                let label = vol.fileSystem.label ?? "Untitled"
                let state = vol.fileSystem.state == .clean ? "" : " [\(vol.fileSystem.state.description)]"
                let mount: String
                if let effective = vol.effectiveMountPoint {
                    mount = " -> \(effective)"
                } else {
                    mount = ""
                }

                print("  - /dev/\(vol.bsdName): \(fs) \"\(label)\" (\(partSizeMb))\(state)\(mount)")
            }
        }
    }

    static func handleProbe(args: [String]) throws {
        guard let target = args.first(where: { !$0.hasPrefix("-") }) else {
            print("Usage: montserrat probe <disk|file> [--json]")
            exit(1)
        }
        let asJson = args.contains("--json")

        if let probe = SuperblockProbe.probe(path: target) {
            if asJson {
                var dict: [String: Any] = [
                    "target": target,
                    "fileSystem": probe.fileSystem.rawValue,
                    "displayName": probe.fileSystem.displayName,
                    "state": probe.state.rawValue,
                    "supported": probe.fileSystem.isSupportedByMontserrat,
                    "readOnlySupported": probe.fileSystem.isReadOnlySupported,
                    "container": probe.fileSystem.isContainer,
                    "detectionOnly": probe.fileSystem.isDetectionOnly
                ]
                if let label = probe.label { dict["label"] = label }
                if let uuid = probe.uuid { dict["uuid"] = uuid }
                let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
                print(String(data: data, encoding: .utf8) ?? "")
            } else {
                print("Probe results for \(target):")
                print("  File System: \(probe.fileSystem.displayName)")
                print("  State:       \(probe.state.description)")
                if let label = probe.label {
                    print("  Label:       \(label)")
                }
                if let uuid = probe.uuid {
                    print("  UUID:        \(uuid)")
                }
                if probe.fileSystem.isSupportedByMontserrat {
                    print("  Supported:   Yes (read-write)")
                } else if probe.fileSystem.isReadOnlySupported {
                    print("  Supported:   Yes (read-only)")
                } else if probe.fileSystem.isContainer {
                    print("  Supported:   No (storage container — inspect with TestDisk-NG: https://github.com/cwmoriarty/TestDisk-NG)")
                } else if probe.fileSystem.isDetectionOnly {
                    print("  Supported:   No (superblock detection only)")
                } else {
                    print("  Supported:   No")
                }
            }
        } else {
            print("No recognized superblock found on \(target).")
            exit(1)
        }
    }

    static func handleMount(args: [String]) throws {
        guard let target = args.first(where: { !$0.hasPrefix("-") }) else {
            print("Usage: montserrat mount <disk|file> [--read-only] [--at <path>] [--auto-repair] [--allow-unclean] [--allow-other] [--fakeroot]")
            exit(1)
        }

        let readOnly = args.contains("--read-only") || args.contains("-r")
        let allowUnclean = args.contains("--allow-unclean")
        let autoRepair = args.contains("--auto-repair")
        let allowOther = args.contains("--allow-other")
        let fakeroot = args.contains("--fakeroot")

        var customMountURL: URL? = nil
        if let atIdx = args.firstIndex(of: "--at"), atIdx + 1 < args.count {
            customMountURL = URL(fileURLWithPath: args[atIdx + 1])
        }

        var timeout: Double = 30.0
        if let tIdx = args.firstIndex(of: "--timeout"), tIdx + 1 < args.count,
           let parsedTimeout = Double(args[tIdx + 1]), parsedTimeout > 0 {
            timeout = parsedTimeout
        }

        let req = MountRequest(
            target: target,
            readOnly: readOnly,
            mountPoint: customMountURL,
            allowUnclean: allowUnclean,
            autoRepair: autoRepair,
            allowOther: allowOther,
            fakeroot: fakeroot,
            timeout: timeout
        )

        print("Mounting \(target)...")
        let record = try MountManager.shared.mount(req)
        print("Successfully mounted at: \(record.mountPoint)")
        print("  Engine:      \(record.engine)")
        print("  Mode:        \(record.readOnly ? "Read-Only" : "Read-Write")")
        if record.fileSystem.isReadOnlySupported {
            print("  Notice:      \(record.fileSystem.displayName) is mounted in read-only archival mode.")
        } else if !readOnly && record.readOnly {
            print("  Notice:      Volume was mounted read-only because the filesystem requires check/repair.")
            print("               Run 'montserrat repair \(target)' to repair, or pass '--auto-repair'.")
        }
    }

    static func handleUnmount(args: [String]) throws {
        guard let target = args.first(where: { !$0.hasPrefix("-") }) else {
            print("Usage: montserrat unmount <disk|mountpoint> [--force]")
            exit(1)
        }
        let force = args.contains("--force") || args.contains("-f")

        print("Unmounting \(target)...")
        try MountManager.shared.unmount(target: target, force: force)
        print("Successfully unmounted \(target). Cache flushed to disk.")
    }

    static func handleEject(args: [String]) throws {
        guard let target = args.first(where: { !$0.hasPrefix("-") }) else {
            print("Usage: montserrat eject <disk>")
            exit(1)
        }

        print("Ejecting \(target)...")
        try MountManager.shared.eject(target: target)
        print("Disk \(target) successfully unmounted and ejected. Safe to unplug.")
    }

    static func handleStatus(args: [String]) throws {
        let asJson = args.contains("--json")
        let mounts = MountManager.shared.activeMounts()

        if asJson {
            let data = try JSONEncoder().encode(mounts)
            print(String(data: data, encoding: .utf8) ?? "[]")
            return
        }

        if mounts.isEmpty {
            print("No volumes currently mounted by Montserrat.")
            return
        }

        print("Active Montserrat Mounts:")
        for m in mounts {
            let mode = m.readOnly ? "RO" : "RW"
            print("  - \(m.source) mounted on \(m.mountPoint) (\(m.fileSystem.displayName), \(mode), pid: \(m.pid))")
        }
    }

    static func handleCheck(args: [String]) throws {
        guard let target = args.first(where: { !$0.hasPrefix("-") }) else {
            print("Usage: montserrat check <disk|file> [--force]")
            exit(1)
        }
        let force = args.contains("--force")

        print("Checking filesystem on \(target) (read-only mode)...")
        let res = try DiskRepairTool.repair(target: target, force: force, autoFix: false)
        if res.wasClean {
            print("Filesystem is clean.")
        } else {
            print("Filesystem has errors or requires attention (Exit code: \(res.exitCode)).")
            print(res.details)
        }
    }

    static func handleRepair(args: [String]) throws {
        guard let target = args.first(where: { !$0.hasPrefix("-") }) else {
            print("Usage: montserrat repair <disk|file> [--force]")
            exit(1)
        }
        let force = args.contains("--force")

        print("Repairing filesystem on \(target)...")
        let res = try DiskRepairTool.repair(target: target, force: force, autoFix: true)
        if res.success {
            if res.errorsCorrected {
                print("Errors were successfully corrected.")
            } else if res.wasClean {
                print("Filesystem was already clean. No repairs needed.")
            }
        } else {
            print("Repair completed with warnings or uncorrected errors (Exit code: \(res.exitCode)).")
            print(res.details)
        }
    }

    static func handleFormat(args: [String]) throws {
        guard let target = args.first(where: { !$0.hasPrefix("-") }) else {
            print("Usage: montserrat format <disk|file> [--type ext4|ext3|ext2|ntfs] [--label <Name>] [--block-size <size>] [--flash] [--force] [--yes]")
            exit(1)
        }

        var type: FileSystemKind = .ext4
        if let tIdx = args.firstIndex(of: "--type"), tIdx + 1 < args.count {
            let tStr = args[tIdx + 1].lowercased()
            if tStr == "ext2" { type = .ext2 }
            else if tStr == "ext3" { type = .ext3 }
            else if tStr == "ntfs" { type = .ntfs }
            else if tStr == "ext4" { type = .ext4 }
            else {
                throw MontserratError.unsupportedFileSystem("Formatting as '\(tStr)' is not supported.")
            }
        }

        var label = "Montserrat"
        if let lIdx = args.firstIndex(of: "--label"), lIdx + 1 < args.count {
            label = args[lIdx + 1]
        }

        var blockSize: Int? = 4096
        if let bIdx = args.firstIndex(of: "--block-size"), bIdx + 1 < args.count,
           let parsedBs = Int(args[bIdx + 1]) {
            blockSize = parsedBs
        }

        let force = args.contains("--force")
        let confirmed = args.contains("--yes") || args.contains("-y") || force
        let isFlash = args.contains("--flash") || args.contains("--sd-card")

        // Fail-closed safety validation before prompting so internal disks are rejected immediately
        let isBlockDevice = target.hasPrefix("/dev/") || target.hasPrefix("disk")
        if isBlockDevice {
            let validated = try SafetyPolicy.validateBlockDevice(target: target)
            if let vol = validated.volume, vol.isMounted {
                throw MontserratError.mountFailed(target, details: "Volume is currently mounted. Unmount \(target) before formatting.")
            }
        }

        if !confirmed {
            if isatty(STDIN_FILENO) != 0 {
                print("WARNING: All data on \(target) will be permanently erased.")
                print("Type 'YES' to confirm formatting \(target) as \(type.displayName): ", terminator: "")
                fflush(stdout)
                let answer = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if answer != "YES" {
                    print("Format cancelled.")
                    exit(1)
                }
            } else {
                fputs("Error: Formatting \(target) requires interactive confirmation or the --yes flag.\n", stderr)
                exit(1)
            }
        }

        print("Formatting \(target) as \(type.displayName) [Label: \"\(label)\"]...")
        let opts = FormatOptions(type: type, label: label, blockSize: blockSize, force: force || confirmed, isFlashOptimized: isFlash)
        let res = try DiskFormatTool.format(target: target, options: opts)
        if res.isSuccess {
            print("Successfully formatted \(target).")
        }
    }

    static func handleShareNFS(args: [String]) throws {
        guard let mountPoint = args.first(where: { !$0.hasPrefix("-") }) else {
            print("Usage: montserrat share-nfs <mountpoint> [--network <client_or_subnet>] [--alldirs] [--rw]")
            exit(1)
        }
        var network = "127.0.0.1"
        if let nIdx = args.firstIndex(of: "--network"), nIdx + 1 < args.count {
            network = args[nIdx + 1]
        }
        let allDirs = args.contains("--alldirs")
        let readOnly = !args.contains("--rw")
        print("Exporting \(mountPoint) via macOS nfsd [Network: \(network), Mode: \(readOnly ? "RO" : "RW")]...")
        try NFSShareTool.exportShare(mountPoint: mountPoint, allowedNetwork: network, allDirs: allDirs, readOnly: readOnly)
        print("Successfully exported \(mountPoint) over NFS.")
    }

    static func handleUnshareNFS(args: [String]) throws {
        guard let mountPoint = args.first(where: { !$0.hasPrefix("-") }) else {
            print("Usage: montserrat unshare-nfs <mountpoint>")
            exit(1)
        }
        print("Removing \(mountPoint) from NFS exports...")
        try NFSShareTool.unexportShare(mountPoint: mountPoint)
        print("Successfully unexported \(mountPoint).")
    }

    static func handleListNFS() {
        let exports = NFSShareTool.listExports()
        if exports.isEmpty {
            print("No active NFS exports configured in /etc/exports.")
            return
        }
        print("Configured NFS Exports:")
        for line in exports {
            print("  \(line)")
        }
    }

    static func handleDaemon(args: [String]) throws {
        let action = args.first ?? "status"
        switch action {
        case "start":
            if PrivilegeManager.isDaemonLoaded() {
                print("montserratd is already loaded via launchd.")
                return
            }
            print("Starting montserratd auto-mount daemon in background...")
            if let daemonPath = EngineRegistry.findBinary("montserratd", requireRootOwned: false) {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: daemonPath)
                proc.arguments = []
                proc.standardOutput = FileHandle.nullDevice
                proc.standardError = FileHandle.nullDevice
                try proc.run()
                print("Started montserratd (pid: \(proc.processIdentifier)).")
            } else {
                print("montserratd binary not found. Build it with ./scripts/build.sh")
                exit(1)
            }
        case "install":
            if let daemonPath = EngineRegistry.findBinary("montserratd", requireRootOwned: false) {
                try PrivilegeManager.installDaemon(daemonExecutablePath: daemonPath)
                print("Installed and loaded com.cwmoriarty.montserratd in \(EngineRegistry.privilegedSupportDir)")
            } else {
                print("montserratd binary not found.")
                exit(1)
            }
        case "uninstall":
            try PrivilegeManager.uninstallDaemon()
            print("Uninstalled com.cwmoriarty.montserratd")
        case "status":
            let loaded = PrivilegeManager.isDaemonLoaded()
            print("montserratd daemon status: \(loaded ? "RUNNING (Loaded via launchd)" : "STOPPED")")
        default:
            print("Usage: montserrat daemon [start|install|uninstall|status]")
        }
    }

    static func handleEngines() {
        print("Montserrat Engine and Dependency Status:")
        print("  FUSE-T Installed: \(EngineRegistry.isFuseTInstalled() ? "YES" : "NO")")

        let paths = EngineRegistry.discover()
        print("  fuse2fs (ext4):   \(paths.fuse2fs ?? "Not found")")
        print("  ntfs-3g (ntfs):   \(paths.ntfs3g ?? "Not found")")
        print("  ntfsfix (ntfs):   \(paths.ntfsfix ?? "Not found")")
        print("  legacyfs:         \(paths.legacyfs ?? "Not found")")
        print("  legacyfs-mount:   \(paths.legacyfsMount ?? "Not found")")
        print("  mke2fs:           \(paths.mke2fs ?? "Not found")")
        print("  e2fsck:           \(paths.e2fsck ?? "Not found")")
        print("  mkntfs:           \(paths.mkntfs ?? "Not found")")
        let tdPath = EngineRegistry.findBinary("testdisk-ng", requireRootOwned: false)
        print("  testdisk-ng:      \(tdPath ?? "Optional (https://github.com/cwmoriarty/TestDisk-NG)")")
    }

    static func handleInstallFuseT() throws {
        let currentDir = FileManager.default.currentDirectoryPath
        let pkgCandidates = [
            "/usr/local/share/montserrat/packages/fuse-t.pkg",
            "/opt/homebrew/share/montserrat/packages/fuse-t.pkg",
            "\(currentDir)/engines/packages/fuse-t.pkg"
        ]
        let bundledPkg = pkgCandidates.first(where: { FileManager.default.fileExists(atPath: $0) })

        if let pkg = bundledPkg {
            print("Opening installer for FUSE-T package: \(pkg)...")
            let result = try CommandRunner.run("/usr/bin/open", arguments: [pkg])
            if result.isSuccess {
                print("Follow the macOS installer prompt to complete FUSE-T setup.")
            } else {
                print("Could not launch installer: \(result.stderr)")
            }
        } else {
            print("Bundled fuse-t.pkg not found. Please install via Homebrew:")
            print("  brew install --cask macos-fuse-t/homebrew-cask/fuse-t")
        }
    }
}

MontserratCLI.main()
