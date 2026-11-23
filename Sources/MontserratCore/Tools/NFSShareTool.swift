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

    /// Filters /etc/exports content in pure Swift, removing any line exporting the target mountPoint.
    /// Avoids shell grep exit-code 1 failure when removing the last remaining export line.
    public static func filterExports(content: String, removingMountPoint mountPoint: String) -> String {
        let cleanPath = URL(fileURLWithPath: mountPoint).standardized.path
        let quotedTarget = "\"\(cleanPath)\""
        let lines = content.components(separatedBy: .newlines)
        let kept = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return false }
            if trimmed.hasPrefix(quotedTarget + " ") || trimmed == quotedTarget {
                return false
            }
            if trimmed.hasPrefix(cleanPath + " ") || trimmed == cleanPath {
                return false
            }
            return true
        }
        return kept.isEmpty ? "" : (kept.joined(separator: "\n") + "\n")
    }

    /// Re-exports a mounted Montserrat volume via macOS nfsd.
    /// Defaults to localhost (127.0.0.1) without -alldirs unless explicitly specified.
    public static func exportShare(
        mountPoint: String,
        allowedNetwork: String = "127.0.0.1",
        allDirs: Bool = false,
        readOnly: Bool = true
    ) throws {
        let cleanPath = URL(fileURLWithPath: mountPoint).standardized.path
        guard !cleanPath.contains("\n") && !cleanPath.contains("\"") && !allowedNetwork.contains("\n") else {
            throw MontserratError.mountFailed(cleanPath, details: "Invalid characters in NFS export parameters.")
        }
        guard MountTable.isMountPoint(cleanPath) else {
            throw MontserratError.mountFailed(cleanPath, details: "Target is not currently mounted.")
        }

        var flags: [String] = ["-maproot=nobody"]
        if readOnly {
            flags.append("-ro")
        }
        if allDirs {
            flags.append("-alldirs")
        }
        let flagStr = flags.joined(separator: " ")
        let exportLine = "\"\(cleanPath)\" \(flagStr) \(allowedNetwork)"

        let existing = (try? String(contentsOfFile: exportsFilePath, encoding: .utf8)) ?? ""
        var updated = filterExports(content: existing, removingMountPoint: cleanPath)
        updated += exportLine + "\n"

        try writeExportsAndReload(content: updated, enableNfsd: true)
    }

    /// Unexports a mounted volume from /etc/exports in pure Swift.
    public static func unexportShare(mountPoint: String) throws {
        let cleanPath = URL(fileURLWithPath: mountPoint).standardized.path
        let existing = (try? String(contentsOfFile: exportsFilePath, encoding: .utf8)) ?? ""
        let updated = filterExports(content: existing, removingMountPoint: cleanPath)

        try writeExportsAndReload(content: updated, enableNfsd: false)
    }

    private static func writeExportsAndReload(content: String, enableNfsd: Bool) throws {
        if PrivilegeManager.isRoot {
            try content.write(toFile: exportsFilePath, atomically: true, encoding: .utf8)
            if enableNfsd {
                _ = try? CommandRunner.run("/sbin/nfsd", arguments: ["enable"])
            }
            let res = try CommandRunner.run("/sbin/nfsd", arguments: ["update"])
            guard res.isSuccess else {
                throw MontserratError.commandFailed("nfsd update", exitCode: res.exitCode, output: res.stderr)
            }
        } else {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("montserrat_exports_\(UUID().uuidString).tmp")
            defer { try? FileManager.default.removeItem(at: tempURL) }
            try content.write(to: tempURL, atomically: true, encoding: .utf8)

            let nfsCmd = enableNfsd ? "/sbin/nfsd enable && /sbin/nfsd update" : "/sbin/nfsd update"
            let cmd = "/usr/bin/install -m 644 -o root -g wheel \(PrivilegeManager.escapeShellArgument(tempURL.path)) \(exportsFilePath) && \(nfsCmd)"
            let res = try PrivilegeManager.runPrivileged(command: cmd)
            guard res.isSuccess else {
                throw MontserratError.commandFailed("nfsd export update", exitCode: res.exitCode, output: res.stderr)
            }
        }
    }

    /// Lists currently configured NFS export lines
    public static func listExports() -> [String] {
        guard let content = try? String(contentsOfFile: exportsFilePath, encoding: .utf8) else {
            return []
        }
        return content
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}
