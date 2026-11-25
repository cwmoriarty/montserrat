import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct EnginePaths: Sendable {
    public let fuse2fs: String?
    public let ntfs3g: String?
    public let ntfsfix: String?
    public let xfsfuse: String?
    public let btrfsfuse: String?
    public let montserratMapper: String?
    public let legacyfs: String?
    public let legacyfsMount: String?
    public let appleExplorer: String?
    public let appleExplorerMount: String?
    public let mke2fs: String?
    public let e2fsck: String?
    public let mkntfs: String?
    public let mkxfs: String?
    public let xfsck: String?
    public let mkbtrfs: String?
    public let btrfsck: String?

    public init(
        fuse2fs: String? = nil,
        ntfs3g: String? = nil,
        ntfsfix: String? = nil,
        xfsfuse: String? = nil,
        btrfsfuse: String? = nil,
        montserratMapper: String? = nil,
        legacyfs: String? = nil,
        legacyfsMount: String? = nil,
        appleExplorer: String? = nil,
        appleExplorerMount: String? = nil,
        mke2fs: String? = nil,
        e2fsck: String? = nil,
        mkntfs: String? = nil,
        mkxfs: String? = nil,
        xfsck: String? = nil,
        mkbtrfs: String? = nil,
        btrfsck: String? = nil
    ) {
        self.fuse2fs = fuse2fs
        self.ntfs3g = ntfs3g
        self.ntfsfix = ntfsfix
        self.xfsfuse = xfsfuse
        self.btrfsfuse = btrfsfuse
        self.montserratMapper = montserratMapper
        self.legacyfs = legacyfs
        self.legacyfsMount = legacyfsMount
        self.appleExplorer = appleExplorer
        self.appleExplorerMount = appleExplorerMount
        self.mke2fs = mke2fs
        self.e2fsck = e2fsck
        self.mkntfs = mkntfs
        self.mkxfs = mkxfs
        self.xfsck = xfsck
        self.mkbtrfs = mkbtrfs
        self.btrfsck = btrfsck
    }
}

public enum EngineRegistry {
    /// Privileged root-owned directory where the daemon and helper engines are staged.
    public static let privilegedSupportDir = "/Library/Application Support/Montserrat"

    /// Read-only FUSE driver aliases backed by `legacyfs-mount` (legacyfs v0.2.0).
    public static let legacyFSDriverAliases: [String] = [
        "fuse-reiserfs",
        "fuse-minix",
        "fuse-cramfs",
        "fuse-romfs",
        "fuse-iso9660",
        "fuse-squashfs",
        "fuse-erofs",
        "fuse-ufs",
        "fuse-jfs",
        "fuse-sysv",
        "fuse-btrfs",
        "fuse-xfs",
        "fuse-udf"
    ]

    /// Discovers paths for all available filesystem engines
    public static func discover(customSearchPaths: [String] = []) -> EnginePaths {
        let fuse2fs = findBinary("fuse2fs", in: customSearchPaths)
        let ntfs3g = findBinary("ntfs-3g", in: customSearchPaths)
        let ntfsfix = findBinary("ntfsfix", in: customSearchPaths)
        let xfsfuse = findBinary("xfsfuse", in: customSearchPaths)
        let btrfsfuse = findBinary("btrfsfuse", in: customSearchPaths)
        let montserratMapper = findBinary("montserrat-mapper", in: customSearchPaths)
        let legacyfs = findBinary("legacyfs", in: customSearchPaths)
        let legacyfsMount = findBinary("legacyfs-mount", in: customSearchPaths)
        let appleExplorer = findBinary("apple-explorer", in: customSearchPaths)
        let appleExplorerMount = findBinary("apple-explorer-mount", in: customSearchPaths)
        let mke2fs = findBinary("mke2fs", in: customSearchPaths)
        let e2fsck = findBinary("e2fsck", in: customSearchPaths)
        let mkntfs = findBinary("mkntfs", in: customSearchPaths)
        let mkxfs = findBinary("mkxfs", in: customSearchPaths)
        let xfsck = findBinary("xfsck", in: customSearchPaths)
        let mkbtrfs = findBinary("mkbtrfs", in: customSearchPaths)
        let btrfsck = findBinary("btrfsck", in: customSearchPaths)

        return EnginePaths(
            fuse2fs: fuse2fs,
            ntfs3g: ntfs3g,
            ntfsfix: ntfsfix,
            xfsfuse: xfsfuse,
            btrfsfuse: btrfsfuse,
            montserratMapper: montserratMapper,
            legacyfs: legacyfs,
            legacyfsMount: legacyfsMount,
            appleExplorer: appleExplorer,
            appleExplorerMount: appleExplorerMount,
            mke2fs: mke2fs,
            e2fsck: e2fsck,
            mkntfs: mkntfs,
            mkxfs: mkxfs,
            xfsck: xfsck,
            mkbtrfs: mkbtrfs,
            btrfsck: btrfsck
        )
    }

    public static func findBinary(_ name: String, in customPaths: [String] = [], requireRootOwned: Bool? = nil) -> String? {
        let isRunningAsRoot = (geteuid() == 0)
        let isDaemonProcess = (ProcessInfo.processInfo.processName == "montserratd")
        let mustBeRootOwned = requireRootOwned ?? (isRunningAsRoot && isDaemonProcess)

        var searchDirs: [String] = []
        if !mustBeRootOwned {
            searchDirs.append(contentsOf: customPaths)
        }

        // 1. Privileged root-owned installation paths (always searched first)
        searchDirs.append("\(privilegedSupportDir)/bin")
        searchDirs.append("\(privilegedSupportDir)/engines/bin")
        searchDirs.append("\(privilegedSupportDir)/engines/sbin")
        searchDirs.append("/Library/PrivilegedHelperTools")

        // 2. Application Bundle resource paths (Montserrat.app/Contents/Resources)
        if let resURL = Bundle.main.resourceURL {
            let resDir = resURL.path
            searchDirs.append("\(resDir)/bin")
            searchDirs.append("\(resDir)/engines/bin")
            searchDirs.append("\(resDir)/engines/sbin")
        }

        // 3. Executable-relative paths (Homebrew formula prefix, app bundle, install.sh prefix)
        if let execURL = Bundle.main.executableURL {
            let execDir = execURL.deletingLastPathComponent().path
            searchDirs.append(execDir)
            searchDirs.append("\(execDir)/engines/bin")
            searchDirs.append("\(execDir)/engines/sbin")
            searchDirs.append("\(execDir)/../engines/bin")
            searchDirs.append("\(execDir)/../engines/sbin")
            searchDirs.append("\(execDir)/../Resources/bin")
            searchDirs.append("\(execDir)/../Resources/engines/bin")
            searchDirs.append("\(execDir)/../Resources/engines/sbin")
            searchDirs.append("\(execDir)/../Helpers/engines/bin")
            searchDirs.append("\(execDir)/../Helpers/engines/sbin")
            searchDirs.append("\(execDir)/../bin")
            searchDirs.append("\(execDir)/../share/montserrat/engines/bin")
            searchDirs.append("\(execDir)/../share/montserrat/engines/sbin")
            searchDirs.append("\(execDir)/../engines/out/bin")
            searchDirs.append("\(execDir)/../engines/out/sbin")
        }

        // 4. Standard system and Homebrew prefixes
        searchDirs.append("/usr/local/share/montserrat/engines/bin")
        searchDirs.append("/usr/local/share/montserrat/engines/sbin")
        searchDirs.append("/opt/homebrew/opt/montserrat/bin")
        searchDirs.append("/opt/homebrew/opt/montserrat/engines/bin")
        searchDirs.append("/opt/homebrew/opt/montserrat/engines/sbin")
        searchDirs.append("/opt/homebrew/share/montserrat/engines/bin")
        searchDirs.append("/opt/homebrew/share/montserrat/engines/sbin")
        searchDirs.append("/opt/homebrew/opt/testdisk-ng/bin")
        searchDirs.append("/usr/local/opt/testdisk-ng/bin")
        searchDirs.append("/usr/local/bin")
        searchDirs.append("/usr/local/sbin")
        searchDirs.append("/opt/homebrew/bin")
        searchDirs.append("/opt/homebrew/sbin")
        searchDirs.append("/usr/bin")
        searchDirs.append("/bin")

        // 5. Working directory build output (only for non-root development builds)
        if !isRunningAsRoot {
            let currentDir = FileManager.default.currentDirectoryPath
            searchDirs.append("\(currentDir)/dist/bin")
            searchDirs.append("\(currentDir)/dist/engines/bin")
            searchDirs.append("\(currentDir)/dist/engines/sbin")
            searchDirs.append("\(currentDir)/engines/out/bin")
            searchDirs.append("\(currentDir)/engines/out/sbin")
        }

        let fm = FileManager.default
        for dir in searchDirs {
            let candidate = "\(dir)/\(name)"
            guard fm.isExecutableFile(atPath: candidate) else { continue }
            let resolved = URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
            if isBinarySafeToExecute(atPath: resolved, requireRootOwned: mustBeRootOwned) {
                return resolved
            }
        }
        return nil
    }

    /// Validates that an executable file is a regular file, not world-writable,
    /// and (when required by root daemon execution) owned by root:wheel in a root-owned directory.
    public static func isBinarySafeToExecute(atPath path: String, requireRootOwned: Bool) -> Bool {
        var st = stat()
        guard stat(path, &st) == 0 else { return false }

        // Must be a regular file
        guard (st.st_mode & S_IFMT) == S_IFREG else { return false }

        // Must never be world-writable
        guard (st.st_mode & S_IWOTH) == 0 else { return false }

        if requireRootOwned {
            // Binary must be owned by root and not group- or world-writable
            guard st.st_uid == 0 else { return false }
            guard (st.st_mode & (S_IWGRP | S_IWOTH)) == 0 else { return false }

            // Parent directory must also be owned by root and not group- or world-writable
            let parentDir = URL(fileURLWithPath: path).deletingLastPathComponent().path
            var dirSt = stat()
            guard stat(parentDir, &dirSt) == 0 else { return false }
            guard dirSt.st_uid == 0 else { return false }
            guard (dirSt.st_mode & (S_IWGRP | S_IWOTH)) == 0 else { return false }
        }

        return true
    }

    public static func isFuseTInstalled() -> Bool {
        let fm = FileManager.default
        let hasHeader = fm.fileExists(atPath: "/usr/local/include/fuse3/fuse.h") ||
                        fm.fileExists(atPath: "/usr/local/include/fuse/fuse.h")
        let hasLib = fm.fileExists(atPath: "/usr/local/lib/libfuse3.dylib") ||
                     fm.fileExists(atPath: "/usr/local/lib/libfuse-t.dylib")
        return hasHeader || hasLib
    }

    public static func isNativeFSKitRuntimeAvailable() -> Bool {
        if #available(macOS 15.4, *) {
            return true
        }
        return false
    }

    /// Discovers the packaged `MontserratFSKit.appex` extension bundle for registration with `pluginkit`.
    public static func findFSKitExtensionBundle() -> String? {
        var candidates: [String] = [
            "/Applications/Montserrat.app/Contents/PlugIns/MontserratFSKit.appex",
            "\(privilegedSupportDir)/FSKit/MontserratFSKit.appex",
            "/opt/homebrew/opt/montserrat/share/montserrat/FSKit/MontserratFSKit.appex",
            "/opt/homebrew/share/montserrat/FSKit/MontserratFSKit.appex",
            "/usr/local/share/montserrat/FSKit/MontserratFSKit.appex"
        ]
        if let bundlePlugIns = Bundle.main.builtInPlugInsPath {
            candidates.insert("\(bundlePlugIns)/MontserratFSKit.appex", at: 0)
        }
        if let execDir = Bundle.main.executableURL?.deletingLastPathComponent().path {
            candidates.append("\(execDir)/../PlugIns/MontserratFSKit.appex")
            candidates.append("\(execDir)/../FSKit/MontserratFSKit.appex")
            candidates.append("\(execDir)/../share/montserrat/FSKit/MontserratFSKit.appex")
        }
        if geteuid() != 0 {
            let cwd = FileManager.default.currentDirectoryPath
            candidates.append("\(cwd)/dist/FSKit/MontserratFSKit.appex")
        }
        let fm = FileManager.default
        return candidates.first { fm.fileExists(atPath: "\($0)/Contents/MacOS/MontserratFSKit") }
    }
}
