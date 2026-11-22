import Foundation

public enum DiskProbe {
    /// Normalizes a device string (e.g. "/dev/rdisk4s1" or "/dev/disk4s1") into a bare BSD name ("disk4s1")
    public static func cleanBSDName(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("/dev/r") {
            s = String(s.dropFirst("/dev/r".count))
        } else if s.hasPrefix("/dev/") {
            s = String(s.dropFirst("/dev/".count))
        }
        return s
    }

    /// Extracts the parent whole-disk BSD name from a slice BSD name (e.g. "disk4s1" -> "disk4")
    public static func extractWholeDiskBSDName(_ raw: String) -> String {
        let clean = cleanBSDName(raw)
        guard clean.hasPrefix("disk") else { return clean }
        let afterDisk = clean.dropFirst("disk".count)
        let digits = afterDisk.prefix(while: { $0.isNumber })
        guard !digits.isEmpty else { return clean }
        return "disk\(digits)"
    }

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

            if !includeInternal && diskInfo.isInternal {
                continue
            }
            results.append(diskInfo)
        }

        return results
    }

    /// Inspects a specific disk or partition BSD name (e.g. "disk4" or "disk4s2")
    public static func inspectDisk(bsdName: String) -> DiskInfo? {
        let cleanBsd = cleanBSDName(bsdName)
        guard !cleanBsd.isEmpty,
              let infoResult = try? CommandRunner.run("/usr/sbin/diskutil", arguments: ["info", "-plist", cleanBsd]),
              infoResult.isSuccess,
              let data = infoResult.stdout.data(using: .utf8),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }

        let isWholeDisk = (dict["WholeDisk"] as? Bool) ?? true
        let wholeDiskBsd = (dict["ParentWholeDisk"] as? String) ?? extractWholeDiskBSDName(cleanBsd)
        let mediaName = (dict["MediaName"] as? String) ?? (dict["IORegistryEntryName"] as? String) ?? cleanBsd
        let size = (dict["TotalSize"] as? UInt64) ?? UInt64((dict["Size"] as? Int64) ?? 0)
        let bus = dict["BusProtocol"] as? String
        let isInternal = (dict["Internal"] as? Bool) ?? false
        let isRemovable = (dict["RemovableMedia"] as? Bool) ?? false
        let isEjectable = (dict["Ejectable"] as? Bool) ?? false
        // Only treat BusProtocol == "Disk Image" as a disk image, never VirtualOrPhysical == "Virtual"
        // because Apple Silicon synthesized APFS containers report Internal=true and Virtual=Yes.
        let isDiskImage = (bus == "Disk Image") && !isInternal
        let content = (dict["Content"] as? String) ?? ""
        let isApfsContainer = content.lowercased().contains("apple_apfs") || (dict["APFSContainerReference"] != nil)
        let isProtected = isInternal || isApfsContainer

        var volumes: [VolumeInfo] = []

        if isWholeDisk {
            var partitionIds: [String] = []
            if let listOutput = try? CommandRunner.run("/usr/sbin/diskutil", arguments: ["list", "-plist", cleanBsd]),
               listOutput.isSuccess,
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
                let isPartitionScheme = content.lowercased().contains("partition_scheme")
                if !isPartitionScheme {
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
            isProtected: isProtected,
            volumes: volumes
        )
    }

    /// Inspects a specific volume / partition
    public static func inspectVolume(bsdName: String, parentDisk: String? = nil) -> VolumeInfo? {
        let cleanBsd = cleanBSDName(bsdName)
        guard !cleanBsd.isEmpty,
              let infoResult = try? CommandRunner.run("/usr/sbin/diskutil", arguments: ["info", "-plist", cleanBsd]),
              infoResult.isSuccess,
              let data = infoResult.stdout.data(using: .utf8),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }

        let wholeDiskBsd = parentDisk ?? (dict["ParentWholeDisk"] as? String) ?? extractWholeDiskBSDName(cleanBsd)
        let size = (dict["TotalSize"] as? UInt64) ?? UInt64((dict["Size"] as? Int64) ?? 0)
        let partType = dict["Content"] as? String
        let partUUID = dict["PartitionUUID"] as? String
        let rawSysMount = dict["MountPoint"] as? String
        let sysMount = (rawSysMount?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? rawSysMount : nil

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

        let activeRecords = MountManager.shared.allRecordedMounts()
        let activeSysMounts = Set(MountTable.entries().map { MountTable.canonicalPath($0.on) })
        let montMount = activeRecords.first(where: { rec in
            let matchesBsd = (rec.bsdName == cleanBsd) ||
                             (DiskProbe.cleanBSDName(rec.source) == cleanBsd)
            let stdMount = MountTable.canonicalPath(rec.mountPoint)
            return matchesBsd && activeSysMounts.contains(stdMount)
        })?.mountPoint

        return VolumeInfo(
            bsdName: cleanBsd,
            wholeDiskBSDName: wholeDiskBsd,
            size: size,
            partitionType: partType,
            partitionUUID: partUUID,
            fileSystem: fsInfo,
            systemMountPoint: sysMount,
            montserratMountPoint: montMount
        )
    }
}
