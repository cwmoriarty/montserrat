import Foundation

public enum FileSystemState: String, Codable, Sendable {
    case clean
    case needsRecovery
    case needsCheck
    case backupSuperblockRecoverable
    case unknown

    public var isSafeForReadWrite: Bool {
        return self == .clean
    }

    public var description: String {
        switch self {
        case .clean: return "Clean"
        case .needsRecovery: return "Journal recovery required"
        case .needsCheck: return "Requires fsck / file system check"
        case .backupSuperblockRecoverable: return "Primary superblock corrupted; backup superblock recoverable"
        case .unknown: return "Unknown"
        }
    }
}
