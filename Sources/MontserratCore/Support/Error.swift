import Foundation

public enum MontserratError: LocalizedError, Sendable {
    case permissionDenied(String)
    case diskNotFound(String)
    case internalDiskProtected(String)
    case unsupportedFileSystem(String)
    case engineNotFound(String)
    case fuseTNotInstalled
    case dirtyFileSystem(String, state: FileSystemState)
    case mountFailed(String, details: String)
    case unmountFailed(String, details: String)
    case commandFailed(String, exitCode: Int32, output: String)
    case timeout(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied(let action):
            return "Permission denied: \(action) requires administrator (root) privileges."
        case .diskNotFound(let disk):
            return "Disk or partition not found: \(disk)"
        case .internalDiskProtected(let disk):
            return "Safety Violation: \(disk) is an internal macOS system disk and is strictly protected."
        case .unsupportedFileSystem(let fs):
            return "File system '\(fs)' is not supported for native mounting."
        case .engineNotFound(let engine):
            return "Engine binary not found: \(engine). Please ensure engines are built or installed."
        case .fuseTNotInstalled:
            return "FUSE-T is not installed. Please install FUSE-T (run 'montserrat install-fuse-t')."
        case .dirtyFileSystem(let disk, let state):
            return "Disk '\(disk)' was not unmounted cleanly (\(state.description)). Mount with --read-only or run fsck/repair."
        case .mountFailed(let disk, let details):
            return "Failed to mount \(disk): \(details)"
        case .unmountFailed(let disk, let details):
            return "Failed to unmount \(disk): \(details)"
        case .commandFailed(let cmd, let code, let output):
            return "Command '\(cmd)' failed with exit code \(code): \(output)"
        case .timeout(let op):
            return "Operation timed out: \(op)"
        }
    }
}
