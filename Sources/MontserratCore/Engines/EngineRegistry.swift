import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct EnginePaths: Sendable {
    public let fuse2fs: String?
    public let ntfs3g: String?
    public let ntfsfix: String?
    public let legacyfs: String?
    public let legacyfsMount: String?
    public let mke2fs: String?
    public let e2fsck: String?
    public let mkntfs: String?

    public init(
        fuse2fs: String? = nil,
        ntfs3g: String? = nil,
        ntfsfix: String? = nil,
        legacyfs: String? = nil,
        legacyfsMount: String? = nil,
        mke2fs: String? = nil,
        e2fsck: String? = nil,
        mkntfs: String? = nil
    ) {
        self.fuse2fs = fuse2fs
        self.ntfs3g = ntfs3g
        self.ntfsfix = ntfsfix
        self.legacyfs = legacyfs
        self.legacyfsMount = legacyfsMount
        self.mke2fs = mke2fs
        self.e2fsck = e2fsck
        self.mkntfs = mkntfs
    }
}

public enum EngineRegistry {
    /// Privileged root-owned directory where the daemon and helper engines are staged.
    public static let privilegedSupportDir = "/Library/Application Support/Montserrat"

    /// Read-only FUSE driver aliases backed by `legacyfs-mount`.
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
        "fuse-sysv"
    ]

    /// Discovers paths for all available filesystem engines
    public static func discover(customSearchPaths: [String] = []) -> EnginePaths {
        let fuse2fs = findBinary("fuse2fs", in: customSearchPaths)
        let ntfs3g = findBinary("ntfs-3g", in: customSearchPaths)
        let ntfsfix = findBinary("ntfsfix", in: customSearchPaths)
        let legacyfs = findBinary("legacyfs", in: customSearchPaths)
        let legacyfsMount = findBinary("legacyfs-mount", in: customSearchPaths)
        let mke2fs = findBinary("mke2fs", in: customSearchPaths)
        let e2fsck = findBinary("e2fsck", in: customSearchPaths)
        let mkntfs = findBinary("mkntfs", in: customSearchPaths)

        return EnginePaths(
            fuse2fs: fuse2fs,
            ntfs3g: ntfs3g,
            ntfsfix: ntfsfix,
            legacyfs: legacyfs,
            legacyfsMount: legacyfsMount,
            mke2fs: mke2fs,
            e2fsck: e2fsck,
            mkntfs: mkntfs
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
}
