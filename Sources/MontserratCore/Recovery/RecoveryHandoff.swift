import Foundation

public struct RecoveryHandoffReport: Codable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: String
    public let sourceTool: String
    public let target: String
    public let wholeDiskTarget: String
    public let detectedFileSystem: String?
    public let fileSystemState: String
    public let volumeLabel: String?
    public let volumeUUID: String?
    public let backupSuperblockBlock: UInt64?
    public let safetySnapshotDirectory: String
    public let recommendedTool: String
    public let notes: [String]
}

public struct PreparedRecoveryHandoff: Sendable {
    public let report: RecoveryHandoffReport
    public let reportFileURL: URL
    public let executablePath: String?
    public let arguments: [String]
    public let shellCommand: String
}

public enum RecoveryHandoff {
    /// Generates a structured diagnostic JSON report and prepares an invocation for TestDisk-NG or PhotoRec-NG
    /// with automatic safety-snapshot protection enabled (`--auto-snapshot --handoff-report <path>`).
    public static func prepareHandoff(
        target: String,
        preferPhotoRec: Bool = false,
        baseDir: URL? = nil
    ) throws -> PreparedRecoveryHandoff {
        let rootDir = baseDir ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".montserrat/recovery", isDirectory: true)
        let snapshotsDir = rootDir.appendingPathComponent("snapshots", isDirectory: true)
        let carvedDir = rootDir.appendingPathComponent("carved", isDirectory: true)

        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: snapshotsDir, withIntermediateDirectories: true)

        let probe = SuperblockProbe.probe(path: target)
        let isBlockDevice = target.hasPrefix("/dev/") || target.hasPrefix("disk")
        let cleanBsd = DiskProbe.cleanBSDName(target)
        let wholeDiskTarget: String
        if isBlockDevice {
            let whole = DiskProbe.extractWholeDiskBSDName(cleanBsd)
            wholeDiskTarget = "/dev/\(whole)"
        } else {
            wholeDiskTarget = target
        }

        var notes: [String] = []
        if let probe {
            notes.append("Superblock identified as \(probe.fileSystem.displayName) (\(probe.state.description)).")
            if let sb = probe.backupSuperblockBlock {
                notes.append("Primary superblock damaged; valid backup superblock found at block \(sb).")
            }
            if probe.fileSystem.isReadOnlySupported || probe.fileSystem.isCowFS || probe.fileSystem.isExt {
                notes.append("Directory-level file listing is available via TestDisk-NG [P] List Files before raw carving.")
            }
        } else {
            notes.append("No intact primary superblock detected; partition scan or PhotoRec-NG signature carving recommended.")
        }

        let formatter = ISO8601DateFormatter()
        let nowStr = formatter.string(from: Date())
        let toolName = preferPhotoRec ? "photorec-ng" : "testdisk-ng"

        let report = RecoveryHandoffReport(
            schemaVersion: 1,
            generatedAt: nowStr,
            sourceTool: "Montserrat 1.1.0",
            target: target,
            wholeDiskTarget: wholeDiskTarget,
            detectedFileSystem: probe?.fileSystem.rawValue,
            fileSystemState: probe?.state.rawValue ?? FileSystemState.unknown.rawValue,
            volumeLabel: probe?.label,
            volumeUUID: probe?.uuid,
            backupSuperblockBlock: probe?.backupSuperblockBlock,
            safetySnapshotDirectory: snapshotsDir.path,
            recommendedTool: toolName,
            notes: notes
        )

        let safeBase = URL(fileURLWithPath: target).lastPathComponent
            .replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        let stamp = Int(Date().timeIntervalSince1970)
        let reportURL = rootDir.appendingPathComponent("handoff-\(safeBase)-\(stamp).json")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jsonData = try encoder.encode(report)
        try jsonData.write(to: reportURL, options: .atomic)

        let resolvedBinary = EngineRegistry.findBinary(toolName, requireRootOwned: false)
        let invokeBinary = resolvedBinary ?? toolName
        let handoffTarget = preferPhotoRec ? target : wholeDiskTarget

        let args: [String]
        if preferPhotoRec {
            try FileManager.default.createDirectory(at: carvedDir, withIntermediateDirectories: true)
            args = ["/d", carvedDir.path, handoffTarget]
        } else {
            args = ["--auto-snapshot", "--handoff-report", reportURL.path, handoffTarget]
        }

        var cmdTokens: [String] = []
        if isBlockDevice && !PrivilegeManager.isRoot {
            cmdTokens.append("sudo")
        }
        cmdTokens.append(PrivilegeManager.escapeShellArgument(invokeBinary))
        cmdTokens.append(contentsOf: args.map { PrivilegeManager.escapeShellArgument($0) })
        let shellCommand = cmdTokens.joined(separator: " ")

        return PreparedRecoveryHandoff(
            report: report,
            reportFileURL: reportURL,
            executablePath: resolvedBinary,
            arguments: args,
            shellCommand: shellCommand
        )
    }
}
