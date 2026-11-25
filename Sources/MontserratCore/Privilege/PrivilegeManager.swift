import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum PrivilegeManager {
    public static var isRoot: Bool {
        return geteuid() == 0
    }

    public static let daemonPlistLabel = "com.cwmoriarty.montserratd"
    public static let daemonPlistPath = "/Library/LaunchDaemons/\(daemonPlistLabel).plist"
    public static let newsyslogConfPath = "/etc/newsyslog.d/montserrat.conf"
    public static let newsyslogConfContent = "/var/log/montserratd*.log 644 5 10240 * J\n"
    public static let installedDaemonPath = "\(EngineRegistry.privilegedSupportDir)/bin/montserratd"

    /// Escapes a single argument safely for POSIX shell execution.
    public static func escapeShellArgument(_ arg: String) -> String {
        "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Executes a shell command with root privileges, prompting GUI dialog if necessary
    public static func runPrivileged(command: String) throws -> CommandResult {
        if isRoot {
            return try CommandRunner.runShell(command)
        }

        let escapedCmd = command.replacingOccurrences(of: "\\", with: "\\\\")
                                .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escapedCmd)\" with administrator privileges"
        return try CommandRunner.run("/usr/bin/osascript", arguments: ["-e", script])
    }

    /// Generates launchd plist XML content for auto-mount background daemon.
    /// Points strictly to the root-owned privileged daemon path.
    public static func generateLaunchdPlist(daemonExecutablePath: String = installedDaemonPath) -> String {
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(daemonPlistLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(daemonExecutablePath)</string>
                <string>--foreground</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>StandardOutPath</key>
            <string>/var/log/montserratd.log</string>
            <key>StandardErrorPath</key>
            <string>/var/log/montserratd.err.log</string>
        </dict>
        </plist>
        """
    }

    /// Stages the daemon and all discovered engine binaries into a root-owned directory
    /// (/Library/Application Support/Montserrat) with 0755 root:wheel permissions,
    /// then installs and loads the LaunchDaemon plist.
    public static func installDaemon(daemonExecutablePath: String) throws {
        let supportDir = EngineRegistry.privilegedSupportDir
        let paths = EngineRegistry.discover()

        var copyCommands: [String] = [
            "/usr/bin/install -d -m 755 -o root -g wheel \(escapeShellArgument("\(supportDir)/bin"))",
            "/usr/bin/install -d -m 755 -o root -g wheel \(escapeShellArgument("\(supportDir)/run"))",
            "/usr/bin/install -d -m 755 -o root -g wheel \(escapeShellArgument("\(supportDir)/engines/bin"))",
            "/usr/bin/install -d -m 755 -o root -g wheel \(escapeShellArgument("\(supportDir)/engines/sbin"))",
            "/usr/bin/install -m 755 -o root -g wheel \(escapeShellArgument(daemonExecutablePath)) \(escapeShellArgument(installedDaemonPath))"
        ]

        let binEngines = [
            paths.fuse2fs,
            paths.ntfs3g,
            paths.ntfsfix,
            paths.xfsfuse,
            paths.btrfsfuse,
            paths.montserratMapper,
            paths.legacyfs,
            paths.legacyfsMount,
            paths.appleExplorer,
            paths.appleExplorerMount
        ].compactMap { $0 }
        for bin in binEngines {
            let name = URL(fileURLWithPath: bin).lastPathComponent
            copyCommands.append("/usr/bin/install -m 755 -o root -g wheel \(escapeShellArgument(bin)) \(escapeShellArgument("\(supportDir)/engines/bin/\(name)"))")
        }
        if paths.legacyfsMount != nil {
            for alias in EngineRegistry.legacyFSDriverAliases {
                copyCommands.append("/bin/ln -sf legacyfs-mount \(escapeShellArgument("\(supportDir)/engines/bin/\(alias)"))")
            }
        }

        let sbinEngines = [
            paths.mke2fs,
            paths.e2fsck,
            paths.mkntfs,
            paths.mkxfs,
            paths.xfsck,
            paths.mkbtrfs,
            paths.btrfsck
        ].compactMap { $0 }
        for sbin in sbinEngines {
            let name = URL(fileURLWithPath: sbin).lastPathComponent
            copyCommands.append("/usr/bin/install -m 755 -o root -g wheel \(escapeShellArgument(sbin)) \(escapeShellArgument("\(supportDir)/engines/sbin/\(name)"))")
        }

        let plistContent = generateLaunchdPlist(daemonExecutablePath: installedDaemonPath)

        if isRoot {
            let setupScript = copyCommands.joined(separator: " && ")
            let stageRes = try CommandRunner.runShell(setupScript)
            guard stageRes.isSuccess else {
                throw MontserratError.commandFailed("installDaemon stage", exitCode: stageRes.exitCode, output: stageRes.stderr)
            }

            try plistContent.write(toFile: daemonPlistPath, atomically: true, encoding: .utf8)
            Darwin.chown(daemonPlistPath, 0, 0)
            Darwin.chmod(daemonPlistPath, 0o644)

            if FileManager.default.fileExists(atPath: "/etc/newsyslog.d") {
                try? newsyslogConfContent.write(toFile: newsyslogConfPath, atomically: true, encoding: .utf8)
                Darwin.chown(newsyslogConfPath, 0, 0)
                Darwin.chmod(newsyslogConfPath, 0o644)
            }

            _ = try? CommandRunner.run("/bin/launchctl", arguments: ["unload", daemonPlistPath])
            let loadRes = try CommandRunner.run("/bin/launchctl", arguments: ["load", "-w", daemonPlistPath])
            guard loadRes.isSuccess else {
                throw MontserratError.commandFailed("launchctl load", exitCode: loadRes.exitCode, output: loadRes.stderr)
            }
        } else {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(daemonPlistLabel)_\(UUID().uuidString).plist")
            defer { try? FileManager.default.removeItem(at: tempURL) }
            try plistContent.write(to: tempURL, atomically: true, encoding: .utf8)

            copyCommands.append("/usr/bin/install -m 644 -o root -g wheel '\(tempURL.path)' '\(daemonPlistPath)'")
            copyCommands.append("/bin/launchctl unload '\(daemonPlistPath)' 2>/dev/null || true")
            copyCommands.append("/bin/launchctl load -w '\(daemonPlistPath)'")

            let fullCmd = copyCommands.joined(separator: " && ")
            let result = try runPrivileged(command: fullCmd)
            guard result.isSuccess else {
                throw MontserratError.commandFailed("installDaemon", exitCode: result.exitCode, output: result.stderr)
            }
        }
    }

    /// Unloads and uninstalls the launchd daemon and removes staged privileged helper binaries
    public static func uninstallDaemon() throws {
        let supportDir = EngineRegistry.privilegedSupportDir
        let uninstallCmd = "/bin/launchctl unload -w '\(daemonPlistPath)' 2>/dev/null; rm -f '\(daemonPlistPath)' '\(newsyslogConfPath)'; rm -rf '\(supportDir)'"
        let result = try runPrivileged(command: uninstallCmd)
        guard result.isSuccess else {
            throw MontserratError.commandFailed("uninstallDaemon", exitCode: result.exitCode, output: result.stderr)
        }
    }

    /// Checks if the daemon is currently running via launchctl
    public static func isDaemonLoaded() -> Bool {
        guard let result = try? CommandRunner.run("/bin/launchctl", arguments: ["list", daemonPlistLabel]) else {
            return false
        }
        return result.isSuccess
    }
}
