```text
  __  __             _                           _   
 |  \/  | ___  _ __ | |_ ___  ___ _ __ _ __ __ _| |_ 
 | |\/| |/ _ \| '_ \| __/ __|/ _ \ '__| '__/ _` | __|
 | |  | | (_) | | | | |_\__ \  __/ |  | | | (_| | |_ 
 |_|  |_|\___/|_| |_|\__|___/\___|_|  |_|  \__,_|\__|
                                cwmoriarty/montserrat                                               
```

# Montserrat

Native read-write ext4, Linux and NTFS filesystem mounting tool for macOS 13+ (Ventura, Sonoma, Sequoia, and later — Apple Silicon and Intel). 

Montserrat provides a user-space, KEXT-free filesystem toolchain for macOS. It mounts ext2, ext3, ext4, XFS, Btrfs, and NTFS read-write (via native **Apple FSKit** on macOS 15.4+ or **FUSE-T** on macOS 13+), mounts 11 archival and optical formats read-only and identifies 37 total filesystems and storage containers via **[legacyfs](https://github.com/cwmoriarty/legacyfs)**, unlocks LUKS1/LUKS2 encrypted drives and assembles LVM2 volume groups, and provides one-click diagnostic recovery handoff to **[TestDisk-NG](https://github.com/cwmoriarty/TestDisk-NG)**.

It is a modern solution, whose goal is to make technical and functional improvements to alternatives: macFUSE, fuse-ext2, e2fsprogs, and legacy commercial solutions (DiskInternals or Paragon).
I am being careful with my wording here, see legal notice below.

---

## Installation

### Homebrew Formula

Install the package via Homebrew:

```bash
brew install cwmoriarty/tap/montserrat
```

### Standalone Application

Download the pre-packaged `Montserrat-<version>.dmg` or `Montserrat-<version>.pkg` from the Releases page. 

Drag `Montserrat.app` to `/Applications` or run the installer package.

### Auto-Mount Background Daemon

Once installed, register and start the background auto-mount daemon once:

```bash
sudo montserrat daemon install
```

When connected, external **ext2, ext3, ext4, XFS, Btrfs, and NTFS** block devices mount automatically at `/Volumes/<Label>` with read-write permissions (clean volumes) or read-only fail-safe (unclean volumes), and supported archival volumes mount read-only. Encrypted LUKS containers and LVM2 volume groups can be unlocked or activated from the menu bar or CLI.

> [!TIP]
> Be sure and use Finder's Eject function before removing a drive.

---

## Menu Bar Application

To launch the optional status item interface:

```bash
open -a Montserrat
```

Provides volume listing, mount state, manual mount or unmount controls, filesystem checking, and formatting.

---

## CLI Reference

```bash
# List external storage devices
montserrat list

# Inspect device superblock
montserrat probe /dev/disk4s1

# Manual mount
sudo montserrat mount /dev/disk4s1
sudo montserrat mount /dev/disk4s1 --read-only

# Filesystem check and repair (supports backup superblock recovery)
sudo montserrat check /dev/disk4s1
sudo montserrat repair /dev/disk4s1

# Format partition (ext4, ext3, ext2, xfs, btrfs, or ntfs)
sudo montserrat format /dev/disk4s1 --type ext4 --label "Data" --flash
sudo montserrat format /dev/disk4s1 --type xfs --label "LinuxServer"

# Guided LUKS unlock and LVM2 volume group activation
montserrat luks info /dev/disk4s2
sudo montserrat luks unlock /dev/disk4s2
montserrat lvm scan /dev/disk4s3
sudo montserrat lvm activate /dev/disk4s3

# Generate recovery diagnostics and launch TestDisk-NG with safety snapshot
sudo montserrat recover /dev/disk4s1

# Re-export mounted volume via macOS nfsd
sudo montserrat share-nfs /Volumes/Data

# Clean unmount with buffer flush
sudo montserrat unmount /Volumes/Data

# Eject whole disk
sudo montserrat eject disk4

# Verify engine and driver paths
montserrat engines
```

---

## Specs

- Architecture: Pure user-space operation via native **Apple FSKit** on macOS 15.4 and later (supporting ext2/3/4, XFS, Btrfs read-write and 13 `legacyfs` formats read-only without third-party installers) and **FUSE-T** across macOS 13 and later.
- Host Isolation: Access to internal Apple APFS containers, recovery partitions, and EFI partitions is blocked by SafetyPolicy.
- Flash Media Wear Mitigation: Mount operations suppress macOS Spotlight indexing (.metadata_never_index) and fseventsd logging. Formatting supports 4MB erase block alignment for SD cards and USB drives.
- Backup Superblock Auto-Recovery: When the primary superblock at offset 1024 is corrupted, Montserrat scans backup superblock blocks (8192, 32768, 98304, 8193) and restores accessibility.
- Automatic Read-Only Fail-Safe: If an unclean filesystem, write-protected switch, or hardware write error prevents read-write mounting, Montserrat automatically falls back to read-only mode so data can be rescued.
- Native System Notifications: Alerts the user via macOS UserNotifications and system notification center when filesystems are discovered, mounted, or safely detached.
- Abrupt Disconnection Signal Cleanup: When an external device is physically disconnected without prior unmounting, the daemon catches the event, terminates orphaned driver processes via SIGTERM and SIGKILL, forces VFS unmount, and clears stale mountpoint directories.
- Hardware Cache Flushes: Background sync loop commits dirty buffers asynchronously every 15 seconds to maximize IOPS and prevent write pipeline stalls. Uses macOS F_FULLFSYNC for hardware barrier commits on explicit unmount and system sleep notifications.

---

## Licensing

- Montserrat Swift codebase: MIT License.
- Archival filesystem library and read-only FUSE driver ([`legacyfs`](https://github.com/cwmoriarty/legacyfs)): MIT License.
- Engine utilities (`e2fsprogs`, `ntfs-3g`) and optional recovery companion ([`TestDisk-NG`](https://github.com/cwmoriarty/TestDisk-NG)): GNU General Public License (GPL-2.0).
- FUSE-T: Free for non-commercial use.


> [!NOTE]
> *All product names, trademarks, and registered trademarks (such as DiskInternals® or Paragon®) are property of their respective owners. Reference to them does not imply endorsement or affiliation. *  
