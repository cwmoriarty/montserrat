import Foundation
import MontserratCore

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
                print("montserrat version 1.0.0 (Darwin/macOS 15-27)")
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
        montserrat - Native Linux and NTFS filesystem tool for modern macOS (15-27)

        Usage: montserrat <command> [options]

        Commands:
          list [--all] [--json]            List external disks and partitions (--all: include internal)
          probe <disk|file> [--json]       Inspect filesystem superblock (ext2/3/4, btrfs, xfs, f2fs, ntfs)
          mount <disk|file> [options]      Mount volume in read-write (or read-only)
          unmount <disk|mountpoint>        Unmount cleanly and flush cache buffers
          eject <disk>                     Unmount all partitions and eject the disk safely
          status [--json]                  Show volumes currently mounted by Montserrat
          check <disk|file> [--force]      Check filesystem consistency
          repair <disk|file> [--force]     Repair filesystem errors (e2fsck / ntfsfix)
          format <disk|file> [options]     Format partition (ext4, ext3, ext2, ntfs)
          share-nfs <mountpoint> [options] Export mounted volume over NFS via nfsd
          unshare-nfs <mountpoint>         Remove volume from NFS exports
          list-nfs                         List configured NFS exports
          daemon [start|stop|install|status] Manage auto-mount background daemon
          engines                          Check status and paths of filesystem engines
          install-fuse-t                   Install bundled FUSE-T runtime package

        Mount Options:
          --read-only, -r                  Mount in read-only mode
          --at <path>                      Custom mount point directory
          --allow-unclean                  Mount even if journal replay or fsck is needed
          --timeout <seconds>              Mount timeout in seconds (default: 30)

        Format Options:
          --type <ext4|ext3|ext2|ntfs>     Filesystem type (default: ext4)
          --label <Name>                   Volume label (default: Montserrat)
          --block-size <1024|2048|4096>    Block size in bytes (default: 4096)
          --force                          Overwrite existing filesystem

        Examples:
          montserrat list
          montserrat probe /dev/disk4s1
          montserrat mount /dev/disk4s1
          montserrat check /dev/disk4s1
          montserrat repair /dev/disk4s1
          montserrat format /dev/disk4s1 --type ext4 --label "LinuxBackup"
          montserrat daemon start
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
                let mount = vol.effectiveMountPoint != nil ? " -> \(vol.effectiveMountPoint!)" : ""

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
                let dict: [String: Any] = [
                    "target": target,
                    "fileSystem": probe.fileSystem.rawValue,
                    "state": probe.state.rawValue,
                    "label": probe.label as Any,
                    "uuid": probe.uuid as Any
                ]
                let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted])
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
                print("  Supported:   \(probe.fileSystem.isSupportedByMontserrat ? "Yes" : "No")")
            }
        } else {
            print("No recognized superblock found on \(target).")
            exit(1)
        }
    }

    static func handleMount(args: [String]) throws {
        guard let target = args.first(where: { !$0.hasPrefix("-") }) else {
            print("Usage: montserrat mount <disk|file> [--read-only] [--at <path>] [--allow-unclean]")
            exit(1)
        }

        let readOnly = args.contains("--read-only") || args.contains("-r")
        let allowUnclean = args.contains("--allow-unclean")

        var customMountURL: URL? = nil
        if let atIdx = args.firstIndex(of: "--at"), atIdx + 1 < args.count {
            customMountURL = URL(fileURLWithPath: args[atIdx + 1])
        }

        let req = MountRequest(
            target: target,
            readOnly: readOnly,
            mountPoint: customMountURL,
            allowUnclean: allowUnclean
        )

        print("Mounting \(target)...")
        let record = try MountManager.shared.mount(req)
        print("Successfully mounted at: \(record.mountPoint)")
        print("  Engine:      \(record.engine)")
        print("  Mode:        \(record.readOnly ? "Read-Only" : "Read-Write")")
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

        print("Checking filesystem on \(target)...")
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
            print("Usage: montserrat format <disk|file> [--type ext4|ext3|ext2|ntfs] [--label <Name>] [--force]")
            exit(1)
        }

        var type: FileSystemKind = .ext4
        if let tIdx = args.firstIndex(of: "--type"), tIdx + 1 < args.count {
            let tStr = args[tIdx + 1].lowercased()
            if tStr == "ext2" { type = .ext2 }
            else if tStr == "ext3" { type = .ext3 }
            else if tStr == "ntfs" { type = .ntfs }
            else { type = .ext4 }
        }

        var label = "Montserrat"
        if let lIdx = args.firstIndex(of: "--label"), lIdx + 1 < args.count {
            label = args[lIdx + 1]
        }

        let force = args.contains("--force")
        let isFlash = args.contains("--flash") || args.contains("--sd-card")

        print("Formatting \(target) as \(type.displayName) [Label: \"\(label)\"]...")
        let opts = FormatOptions(type: type, label: label, force: force, isFlashOptimized: isFlash)
        let res = try DiskFormatTool.format(target: target, options: opts)
        if res.isSuccess {
            print("Successfully formatted \(target).")
        }
    }

    static func handleShareNFS(args: [String]) throws {
        guard let mountPoint = args.first(where: { !$0.hasPrefix("-") }) else {
            print("Usage: montserrat share-nfs <mountpoint> [--network <options>]")
            exit(1)
        }
        var network = "-network 192.168.0.0 -mask 255.255.0.0"
        if let nIdx = args.firstIndex(of: "--network"), nIdx + 1 < args.count {
            network = args[nIdx + 1]
        }
        print("Exporting \(mountPoint) via macOS nfsd [Network: \(network)]...")
        try NFSShareTool.exportShare(mountPoint: mountPoint, allowedNetwork: network)
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
            print("Starting montserratd auto-mount daemon...")
            if let daemonPath = EngineRegistry.findBinary("montserratd") {
                _ = try CommandRunner.run(daemonPath, arguments: [])
            } else {
                print("montserratd binary not found. Build it with ./scripts/build.sh")
            }
        case "install":
            if let daemonPath = EngineRegistry.findBinary("montserratd") {
                try PrivilegeManager.installDaemon(daemonExecutablePath: daemonPath)
                print("Installed and loaded com.cwmoriarty.montserratd")
            } else {
                print("montserratd binary not found.")
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
        print("  btrfs-fuse:       \(paths.btrfsFuse ?? "Not found")")
        print("  xfs-fuse:         \(paths.xfsFuse ?? "Not found")")
        print("  f2fs-fuse:        \(paths.f2fsFuse ?? "Not found")")
        print("  mke2fs:           \(paths.mke2fs ?? "Not found")")
        print("  e2fsck:           \(paths.e2fsck ?? "Not found")")
        print("  mkntfs:           \(paths.mkntfs ?? "Not found")")
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
