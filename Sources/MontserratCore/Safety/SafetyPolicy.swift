import Foundation

public enum SafetyPolicy {
    /// Well-known protected partition type UUIDs
    public static let protectedPartitionUUIDs: Set<String> = [
        "C12A7328-F81F-11D2-BA4B-00A0C93EC93B", // EFI System Partition
        "7C3457EF-0000-11AA-AA11-00306543ECAC", // Apple APFS Container
        "52637672-7900-11AA-AA11-00306543ECAC", // Apple Recovery
        "426F6F74-0000-11AA-AA11-00306543ECAC", // Apple Boot
        "69646961-6700-11AA-AA11-00306543ECAC"  // Apple Diagnostics
    ]

    /// Validates whether a given disk or partition is safe for Montserrat to operate on
    public static func validate(disk: DiskInfo, volume: VolumeInfo? = nil) throws {
        // 1. Strictly forbid internal disks unless it's a disk image
        if disk.isInternal && !disk.isDiskImage {
            throw MontserratError.internalDiskProtected("\(disk.bsdName) is an internal macOS system disk.")
        }

        // 2. If a specific volume is requested, check partition UUID and type
        if let vol = volume {
            if let uuid = vol.partitionUUID?.uppercased(), protectedPartitionUUIDs.contains(uuid) {
                throw MontserratError.internalDiskProtected("Partition \(vol.bsdName) has protected type UUID (\(uuid)).")
            }
            if let partType = vol.partitionType?.lowercased() {
                if partType.contains("efi") || partType.contains("apple_apfs") || partType.contains("apple_boot") {
                    throw MontserratError.internalDiskProtected("Partition \(vol.bsdName) is protected type: \(partType).")
                }
            }
        }
    }

    /// Verifies if a given device path is an internal disk
    public static func isInternal(devicePath: String) -> Bool {
        // e.g. /dev/disk0, /dev/disk1, /dev/rdisk0
        let bsd = devicePath.replacingOccurrences(of: "/dev/r", with: "").replacingOccurrences(of: "/dev/", with: "")
        // Simple fast check: disk0, disk1 on modern Apple Silicon are internal NVMe/APFS
        if bsd.hasPrefix("disk0") || bsd.hasPrefix("disk1") || bsd.hasPrefix("disk3") {
            // Further verification should be done via DiskProbe
            return true
        }
        return false
    }
}
