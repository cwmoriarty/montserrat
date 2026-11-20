import Foundation

public enum DiskProbe {
    /// Lists all disks currently connected to the system
    public static func listDisks(includeInternal: Bool = false) -> [DiskInfo] {
        guard let listOutput = try? CommandRunner.run("/usr/sbin/diskutil", arguments: ["list", "-plist"]),
              let listData = listOutput.stdout.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: listData, format: nil) as? [String: Any],
              let allDisks = plist["AllDisksAndPartitions"] as? [[String: Any]] else {
            return []
        }

        var results: [DiskInfo] = []

        for diskDict in allDisks {
            guard let bsdName = diskDict["DeviceIdentifier"] as? String else { continue }
            guard let diskInfo = inspectDisk(bsdName: bsdName) else { continue }

            if !includeInternal && diskInfo.isInternal && !diskInfo.isDiskImage {
                continue
            }
            results.append(diskInfo)
        }

        return results
    }

    /// Inspects a specific disk or partition BSD name (e.g. "disk4" or "disk4s2")
    public static func inspectDisk(bsdName: String) -> DiskInfo? {
        let cleanBsd = bsdName.replacingOccurrences(of: "/dev/r", with: "").replacingOccurrences(of: "/dev/", with: "")
        guard let infoResult = try? CommandRunner.run("/usr/sbin/diskutil", arguments: ["info", "-plist", cleanBsd]),
              let data = infoResult.stdout.data(using: .utf8),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }

        let isWholeDisk = (dict["WholeDisk"] as? Bool) ?? true
        let wholeDiskBsd = (dict["ParentWholeDisk"] as? String) ?? cleanBsd
        let mediaName = (dict["MediaName"] as? String) ?? (dict["IORegistryEntryName"] as? String) ?? cleanBsd
        let size = (dict["TotalSize"] as? UInt64) ?? UInt64((dict["Size"] as? Int64) ?? 0)
        let bus = dict["BusProtocol"] as? String
        let isInternal = (dict["Internal"] as? Bool) ?? false
        let isRemovable = (dict["RemovableMedia"] as? Bool) ?? false
        let isEjectable = (dict["Ejectable"] as? Bool) ?? false
        let isDiskImage = (bus == "Disk Image") || (dict["VirtualOrPhysical"] as? String == "Virtual")

        var volumes: [VolumeInfo] = []

        if isWholeDisk {
            // Find partitions if any using diskutil list -plist <bsdName>
            var partitionIds: [String] = []
            if let listOutput = try? CommandRunner.run("/usr/sbin/diskutil", arguments: ["list", "-plist", cleanBsd]),
               let listData = listOutput.stdout.data(using: .utf8),
               let listPlist = try? PropertyListSerialization.propertyList(from: listData, format: nil) as? [String: Any],
               let allDisks = listPlist["AllDisksAndPartitions"] as? [[String: Any]] {
                for d in allDisks {
                    if let parts = d["Partitions"] as? [[String: Any]] {
                        for p in parts {
                            if let pId = p["DeviceIdentifier"] as? String {
                                partitionIds.append(pId)
                            }
                        }
                    }
                }
            }

            if !partitionIds.isEmpty {
                for pBsd in partitionIds {
                    if let vol = inspectVolume(bsdName: pBsd, parentDisk: wholeDiskBsd) {
                        volumes.append(vol)
                    }
                }
            } else {
                let content = (dict["Content"] as? String) ?? ""
                let isPartitionScheme = content.lowercased().contains("partition_scheme")
                if !isPartitionScheme {
                    // Whole disk without partitions (e.g. raw formatted /dev/disk4)
                    if let vol = inspectVolume(bsdName: cleanBsd, parentDisk: wholeDiskBsd) {
                        volumes.append(vol)
                    }
                }
            }
        } else {
            if let vol = inspectVolume(bsdName: cleanBsd, parentDisk: wholeDiskBsd) {
                volumes.append(vol)
            }
        }

        return DiskInfo(
            bsdName: cleanBsd,
            size: size,
            name: mediaName,
            connection: bus,
            isInternal: isInternal,
            isRemovable: isRemovable,
            isEjectable: isEjectable,
            isDiskImage: isDiskImage,
            isProtected: isInternal && !isDiskImage,
            volumes: volumes
        )
    }

    /// Inspects a specific volume / partition
    public static func inspectVolume(bsdName: String, parentDisk: String? = nil) -> VolumeInfo? {
        let cleanBsd = bsdName.replacingOccurrences(of: "/dev/r", with: "").replacingOccurrences(of: "/dev/", with: "")
        guard let infoResult = try? CommandRunner.run("/usr/sbin/diskutil", arguments: ["info", "-plist", cleanBsd]),
              let data = infoResult.stdout.data(using: .utf8),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }

        let wholeDiskBsd = parentDisk ?? (dict["ParentWholeDisk"] as? String) ?? cleanBsd
        let size = (dict["TotalSize"] as? UInt64) ?? UInt64((dict["Size"] as? Int64) ?? 0)
        let partType = dict["Content"] as? String
        let partUUID = dict["PartitionUUID"] as? String
        let rawSysMount = dict["MountPoint"] as? String
        let sysMount = (rawSysMount?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? rawSysMount : nil

        // Check superblock probe for precise filesystem identification
        let devPath = "/dev/\(cleanBsd)"
        let probeResult = SuperblockProbe.probe(path: devPath)

        let fsKind: FileSystemKind
        let fsState: FileSystemState
        let label: String?
        let uuid: String?
        let isVerified: Bool

        if let probe = probeResult {
            fsKind = probe.fileSystem
            fsState = probe.state
            label = probe.label ?? (dict["VolumeName"] as? String)
            uuid = probe.uuid ?? (dict["VolumeUUID"] as? String)
            isVerified = true
        } else {
            // Deduce from diskutil plist info
            let rawFs = (dict["FilesystemType"] as? String ?? dict["FilesystemName"] as? String ?? "").lowercased()
            let content = (dict["Content"] as? String ?? "").lowercased()
            if rawFs.contains("ext4") || content.contains("ext4") { fsKind = .ext4 }
            else if rawFs.contains("ext3") || content.contains("ext3") { fsKind = .ext3 }
            else if rawFs.contains("ext2") || content.contains("ext2") { fsKind = .ext2 }
            else if rawFs.contains("btrfs") || content.contains("btrfs") { fsKind = .btrfs }
            else if rawFs.contains("xfs") || content.contains("xfs") { fsKind = .xfs }
            else if rawFs.contains("f2fs") || content.contains("f2fs") { fsKind = .f2fs }
            else if rawFs.contains("linux") || content.contains("linux") { fsKind = .ext4 }
            else if rawFs.contains("ntfs") || content.contains("ntfs") || content.contains("windows_ntfs") { fsKind = .ntfs }
            else if rawFs.contains("exfat") || content.contains("exfat") { fsKind = .exfat }
            else if rawFs.contains("ms-dos") || rawFs.contains("fat32") || content.contains("dos") { fsKind = .fat32 }
            else if rawFs.contains("apfs") || content.contains("apfs") { fsKind = .apfs }
            else if rawFs.contains("hfs") || content.contains("hfs") { fsKind = .hfsplus }
            else { fsKind = .unknown }

            fsState = .unknown
            label = dict["VolumeName"] as? String
            uuid = dict["VolumeUUID"] as? String
            isVerified = false
        }

        let fsInfo = FileSystemInfo(
            kind: fsKind,
            label: label,
            uuid: uuid,
            state: fsState,
            isVerified: isVerified
        )

        return VolumeInfo(
            bsdName: cleanBsd,
            wholeDiskBSDName: wholeDiskBsd,
            size: size,
            partitionType: partType,
            partitionUUID: partUUID,
            fileSystem: fsInfo,
            systemMountPoint: sysMount,
            montserratMountPoint: nil
        )
    }
}
