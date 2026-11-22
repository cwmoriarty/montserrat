import Foundation

public enum SafetyPolicy {
    /// Well-known protected GPT partition type GUIDs (stored in diskutil Content / partitionType)
    public static let protectedPartitionTypeGUIDs: Set<String> = [
        "C12A7328-F81F-11D2-BA4B-00A0C93EC93B", // EFI System Partition
        "7C3457EF-0000-11AA-AA11-00306543ECAC", // Apple APFS Container
        "52637672-7900-11AA-AA11-00306543ECAC", // Apple Recovery
        "426F6F74-0000-11AA-AA11-00306543ECAC", // Apple Boot
        "69646961-6700-11AA-AA11-00306543ECAC", // Apple Diagnostics
        "53746F72-6167-11AA-AA11-00306543ECAC"  // Apple CoreStorage
    ]

    /// Validates whether a given disk or partition is safe for Montserrat to operate on.
    public static func validate(disk: DiskInfo, volume: VolumeInfo? = nil) throws {
        // 1. Strictly forbid any internal disk regardless of virtual or synthesized status.
        if disk.isInternal {
            throw MontserratError.internalDiskProtected("\(disk.bsdName) is an internal macOS system disk.")
        }

        if disk.isProtected {
            throw MontserratError.internalDiskProtected("\(disk.bsdName) is a protected macOS disk or container.")
        }

        // 2. If a specific volume is requested, verify partition type and filesystem kind.
        if let vol = volume {
            if vol.fileSystem.kind == .apfs {
                throw MontserratError.internalDiskProtected("Partition \(vol.bsdName) is an APFS volume.")
            }

            if let partType = vol.partitionType {
                let upper = partType.uppercased()
                if protectedPartitionTypeGUIDs.contains(upper) {
                    throw MontserratError.internalDiskProtected("Partition \(vol.bsdName) has protected type GUID (\(upper)).")
                }

                let lower = partType.lowercased()
                if lower.contains("efi") ||
                   lower.contains("apple_apfs") ||
                   lower.contains("apple_boot") ||
                   lower.contains("apple_recovery") ||
                   lower.contains("apple_isc") {
                    throw MontserratError.internalDiskProtected("Partition \(vol.bsdName) has protected partition type: \(partType).")
                }
            }
        }
    }

    /// Fail-closed validation for a block device path (e.g. "/dev/disk4s1" or "disk0").
    /// Rejects the operation if diskutil inspection fails or if the device is internal/protected.
    @discardableResult
    public static func validateBlockDevice(target: String) throws -> (disk: DiskInfo, volume: VolumeInfo?) {
        let cleanBsd = DiskProbe.cleanBSDName(target)
        let wholeBsd = DiskProbe.extractWholeDiskBSDName(cleanBsd)

        let vol = DiskProbe.inspectVolume(bsdName: cleanBsd)
        let resolvedWholeBsd = vol?.wholeDiskBSDName ?? wholeBsd

        guard let disk = DiskProbe.inspectDisk(bsdName: resolvedWholeBsd) else {
            if isReservedInternalDiskName(wholeBsd) {
                throw MontserratError.internalDiskProtected("\(target) is a reserved internal system disk.")
            }
            throw MontserratError.diskNotFound("Unable to inspect device \(target) via diskutil; failing closed.")
        }

        try validate(disk: disk, volume: vol)
        return (disk: disk, volume: vol)
    }

    /// Exact whole-disk name check for reserved system disks when diskutil is unavailable.
    /// Uses exact token equality so "disk1" never matches "disk10" through "disk19".
    public static func isReservedInternalDiskName(_ bsdName: String) -> Bool {
        let whole = DiskProbe.extractWholeDiskBSDName(bsdName)
        let reserved: Set<String> = ["disk0", "disk1", "disk2", "disk3"]
        return reserved.contains(whole)
    }

    /// Verifies if a given device path is an internal or protected disk. Fails closed on probe failure.
    public static func isInternal(devicePath: String) -> Bool {
        let cleanBsd = DiskProbe.cleanBSDName(devicePath)
        let wholeBsd = DiskProbe.extractWholeDiskBSDName(cleanBsd)
        if let disk = DiskProbe.inspectDisk(bsdName: wholeBsd) {
            return disk.isInternal || disk.isProtected
        }
        // Fail closed: if diskutil cannot inspect the device, treat as protected/internal
        return true
    }
}
