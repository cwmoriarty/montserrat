import Foundation

public enum PrivilegeManager {
    public static var isRoot: Bool {
        return getuid() == 0
    }

    public static let daemonPlistLabel = "com.cwmoriarty.montserratd"
    public static let daemonPlistPath = "/Library/LaunchDaemons/\(daemonPlistLabel).plist"
    public static let newsyslogConfPath = "/etc/newsyslog.d/montserrat.conf"
    public static let newsyslogConfContent = "/var/log/montserratd*.log 644 5 10240 * J\n"

    /// Executes a shell command with root privileges, prompting GUI dialog if necessary
    public static func runPrivileged(command: String) throws -> CommandResult {
        if isRoot {
            return try CommandRunner.runShell(command)
        }

        // Use AppleScript administrator prompt when running in non-root user context
        let escapedCmd = command.replacingOccurrences(of: "\\", with: "\\\\")
                                .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escapedCmd)\" with administrator privileges"
        return try CommandRunner.run("/usr/bin/osascript", arguments: ["-e", script])
    }

    /// Generates launchd plist XML content for auto-mount background daemon
    public static func generateLaunchdPlist(daemonExecutablePath: String) -> String {
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

    /// Installs and loads the launchd daemon
    public static func installDaemon(daemonExecutablePath: String) throws {
        let plistContent = generateLaunchdPlist(daemonExecutablePath: daemonExecutablePath)
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(daemonPlistLabel).plist")
        try plistContent.write(to: tempURL, atomically: true, encoding: .utf8)

        var installCmd = "cp '\(tempURL.path)' '\(daemonPlistPath)' && chown root:wheel '\(daemonPlistPath)' && chmod 644 '\(daemonPlistPath)' && launchctl load -w '\(daemonPlistPath)'"
        if FileManager.default.fileExists(atPath: "/etc/newsyslog.d") {
            let confTemp = FileManager.default.temporaryDirectory.appendingPathComponent("montserrat.conf")
            try? newsyslogConfContent.write(to: confTemp, atomically: true, encoding: .utf8)
            installCmd += " && cp '\(confTemp.path)' '\(newsyslogConfPath)' && chmod 644 '\(newsyslogConfPath)'"
        }

        let result = try runPrivileged(command: installCmd)
        guard result.isSuccess else {
            throw MontserratError.commandFailed("installDaemon", exitCode: result.exitCode, output: result.stderr)
        }
    }

    /// Unloads and uninstalls the launchd daemon
    public static func uninstallDaemon() throws {
        let uninstallCmd = "launchctl unload -w '\(daemonPlistPath)' 2>/dev/null; rm -f '\(daemonPlistPath)' '\(newsyslogConfPath)'"
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
