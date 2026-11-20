import Foundation

public struct NFSExportEntry: Sendable {
    public let path: String
    public let options: String
    public let clients: String

    public init(path: String, options: String, clients: String) {
        self.path = path
        self.options = options
        self.clients = clients
    }
}

public enum NFSShareTool {
    public static let exportsFilePath = "/etc/exports"

    /// Re-exports a mounted Montserrat volume over the local network via macOS nfsd
    public static func exportShare(mountPoint: String, allowedNetwork: String = "-network 192.168.0.0 -mask 255.255.0.0") throws {
        let cleanPath = URL(fileURLWithPath: mountPoint).standardized.path
        guard MountTable.isMountPoint(cleanPath) else {
            throw MontserratError.mountFailed(cleanPath, details: "Target is not currently mounted.")
        }

        let exportLine = "\"\(cleanPath)\" -alldirs -maproot=nobody \(allowedNetwork)\n"

        // Append line to /etc/exports with root privileges
        let cmd = "printf '%s' \(escapeShell(exportLine)) >> \(exportsFilePath) && nfsd enable && nfsd update"
        let res = try PrivilegeManager.runPrivileged(command: cmd)
        guard res.isSuccess else {
            throw MontserratError.commandFailed("nfsd export", exitCode: res.exitCode, output: res.stderr)
        }
    }

    /// Unexports a mounted volume from /etc/exports
    public static func unexportShare(mountPoint: String) throws {
        let cleanPath = URL(fileURLWithPath: mountPoint).standardized.path
        let filterCmd = "grep -v \"\(cleanPath)\" \(exportsFilePath) > /tmp/exports.tmp && mv /tmp/exports.tmp \(exportsFilePath) && nfsd update"
        let res = try PrivilegeManager.runPrivileged(command: filterCmd)
        guard res.isSuccess else {
            throw MontserratError.commandFailed("nfsd unexport", exitCode: res.exitCode, output: res.stderr)
        }
    }

    /// Lists currently configured NFS export lines
    public static func listExports() -> [String] {
        guard let content = try? String(contentsOfFile: exportsFilePath, encoding: .utf8) else {
            return []
        }
        return content.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
    }

    private static func escapeShell(_ str: String) -> String {
        return "'" + str.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
