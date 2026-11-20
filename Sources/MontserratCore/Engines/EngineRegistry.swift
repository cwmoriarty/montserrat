import Foundation

public struct EnginePaths: Sendable {
    public let fuse2fs: String?
    public let ntfs3g: String?
    public let mke2fs: String?
    public let e2fsck: String?
    public let mkntfs: String?
    public let btrfsFuse: String?
    public let xfsFuse: String?
    public let f2fsFuse: String?

    public init(
        fuse2fs: String? = nil,
        ntfs3g: String? = nil,
        mke2fs: String? = nil,
        e2fsck: String? = nil,
        mkntfs: String? = nil,
        btrfsFuse: String? = nil,
        xfsFuse: String? = nil,
        f2fsFuse: String? = nil
    ) {
        self.fuse2fs = fuse2fs
        self.ntfs3g = ntfs3g
        self.mke2fs = mke2fs
        self.e2fsck = e2fsck
        self.mkntfs = mkntfs
        self.btrfsFuse = btrfsFuse
        self.xfsFuse = xfsFuse
        self.f2fsFuse = f2fsFuse
    }
}

public enum EngineRegistry {
    /// Discovers paths for all available filesystem engines
    public static func discover(customSearchPaths: [String] = []) -> EnginePaths {
        let fuse2fs = findBinary("fuse2fs", in: customSearchPaths)
        let ntfs3g = findBinary("ntfs-3g", in: customSearchPaths)
        let mke2fs = findBinary("mke2fs", in: customSearchPaths)
        let e2fsck = findBinary("e2fsck", in: customSearchPaths)
        let mkntfs = findBinary("mkntfs", in: customSearchPaths)
        let btrfsFuse = findBinary("btrfs-fuse", in: customSearchPaths)
        let xfsFuse = findBinary("xfs-fuse", in: customSearchPaths)
        let f2fsFuse = findBinary("f2fs-fuse", in: customSearchPaths)

        return EnginePaths(
            fuse2fs: fuse2fs,
            ntfs3g: ntfs3g,
            mke2fs: mke2fs,
            e2fsck: e2fsck,
            mkntfs: mkntfs,
            btrfsFuse: btrfsFuse,
            xfsFuse: xfsFuse,
            f2fsFuse: f2fsFuse
        )
    }

    public static func findBinary(_ name: String, in customPaths: [String] = []) -> String? {
        var searchDirs: [String] = customPaths

        // Add executable directory relative paths
        if let execURL = Bundle.main.executableURL {
            let execDir = execURL.deletingLastPathComponent().path
            searchDirs.append("\(execDir)/engines/bin")
            searchDirs.append("\(execDir)/engines/sbin")
            searchDirs.append("\(execDir)/../Helpers/engines/bin")
            searchDirs.append("\(execDir)/../Helpers/engines/sbin")
            searchDirs.append("\(execDir)/../engines/out/bin")
            searchDirs.append("\(execDir)/../engines/out/sbin")
        }

        // Add standard and Homebrew prefixes
        searchDirs.append("/usr/local/bin")
        searchDirs.append("/usr/local/sbin")
        searchDirs.append("/usr/local/share/montserrat/engines/bin")
        searchDirs.append("/usr/local/share/montserrat/engines/sbin")
        searchDirs.append("/opt/homebrew/bin")
        searchDirs.append("/opt/homebrew/sbin")
        searchDirs.append("/opt/homebrew/share/montserrat/engines/bin")
        searchDirs.append("/opt/homebrew/share/montserrat/engines/sbin")
        searchDirs.append("/usr/bin")
        searchDirs.append("/bin")

        // Also check working directory build output during development
        let currentDir = FileManager.default.currentDirectoryPath
        searchDirs.append("\(currentDir)/dist/engines/bin")
        searchDirs.append("\(currentDir)/dist/engines/sbin")
        searchDirs.append("\(currentDir)/engines/out/bin")
        searchDirs.append("\(currentDir)/engines/out/sbin")

        let fm = FileManager.default
        for dir in searchDirs {
            let path = "\(dir)/\(name)"
            if fm.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
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
