```text
███╗   ███╗ ██████╗ ███╗   ██╗████████╗███████╗███████╗██████╗ ██████╗  █████╗ ████████╗
████╗ ████║██╔═══██╗████╗  ██║╚══██╔══╝██╔════╝██╔════╝██╔══██╗██╔══██╗██╔══██╗╚══██╔══╝
██╔████╔██║██║   ██║██╔██╗ ██║   ██║   ███████╗█████╗  ██████╔╝██████╔╝███████║   ██║   
██║╚██╔╝██║██║   ██║██║╚██╗██║   ██║   ╚════██║██╔══╝  ██╔══██╗██╔══██╗██╔══██║   ██║   
██║ ╚═╝ ██║╚██████╔╝██║ ╚████║   ██║   ███████║███████╗██║  ██║██║  ██║██║  ██║   ██║   
╚═╝     ╚═╝ ╚═════╝ ╚═╝  ╚═══╝   ╚═╝   ╚══════╝╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝   ╚═╝   
```

# Montserrat (cwmoriarty/montserrat)

Native read-write ext4, Linux and NTFS filesystem tool suite for macOS 15 through 27 (Apple Silicon and Intel).

Montserrat provides a user-space, KEXT-free filesystem toolchain for macOS. It interfaces with Apple FSKit and FUSE-T, utilizing patched upstream engines (fuse2fs from e2fsprogs, ntfs-3g, btrfs-fuse, xfs-fuse, and f2fs-fuse).

---

## Installation

### Option A: Homebrew Formula

Install the package via Homebrew:

```bash
brew install cwmoriarty/tap/montserrat
```

### Option B: Standalone Application Package (.dmg or .pkg)

Download the pre-packaged `Montserrat-<version>.dmg` or `Montserrat-<version>.pkg` from the Releases page. Drag `Montserrat.app` to `/Applications` or run the installer package.

### Auto-Mount Background Service

Register and start the background auto-mount daemon:

```bash
sudo montserrat daemon install
```

When connected, external ext2, ext3, ext4, Btrfs, XFS, and NTFS block devices mount automatically at `/Volumes/<Label>` with read-write permissions. Eject the volume before physical disconnection.

---

## Menu Bar Application

To launch the optional status item interface:

```bash
open -a MontserratApp
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

# Format partition (use --flash for 4MB flash erase block alignment)
sudo montserrat format /dev/disk4s1 --type ext4 --label "Data" --flash

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

## Technical Specifications and Stability Functions

- Architecture: Pure user-space operation. Compatible with Apple FSKit native VFS on macOS 15.4 and later, with FUSE-T fallback.
- Host Isolation: Access to internal Apple APFS containers, recovery partitions, and EFI partitions is blocked by SafetyPolicy.
- Flash Media Wear Mitigation: Mount operations suppress macOS Spotlight indexing (.metadata_never_index) and fseventsd logging. Formatting supports 4MB erase block alignment for SD cards and USB drives.
- Backup Superblock Auto-Recovery: When the primary superblock at offset 1024 is corrupted, Montserrat scans backup superblock blocks (8192, 32768, 98304, 8193) and restores accessibility.
- Automatic Read-Only Fail-Safe: If an unclean filesystem, write-protected switch, or hardware write error prevents read-write mounting, Montserrat automatically falls back to read-only mode so data can be rescued.
- Native System Notifications: Alerts the user via macOS UserNotifications and system notification center when filesystems are discovered, mounted, or safely detached.
- Abrupt Disconnection Signal Cleanup: When an external device is physically disconnected without prior unmounting, the daemon catches the event, terminates orphaned driver processes via SIGTERM and SIGKILL, forces VFS unmount, and clears stale mountpoint directories.
- Hardware Cache Flushes: Background sync loop commits dirty buffers asynchronously every 15 seconds to maximize IOPS and prevent write pipeline stalls. Uses macOS F_FULLFSYNC for hardware barrier commits on explicit unmount and system sleep notifications.

---

## Building From Source

Prerequisites: Xcode 16 or later, Swift 6 toolchain.

```bash
git clone https://github.com/cwmoriarty/montserrat.git
cd montserrat
./scripts/build.sh
swift test
```

Binaries are generated in `dist/bin/`:
- `montserrat`: CLI utility
- `montserratd`: Background auto-mount service
- `MontserratApp`: Menu bar application

For advanced tuning, the Darwin VFS kernel driver module, code signing, and release procedures, see [docs/MAINTAINER_GUIDE.md](file:///Users/cwm/Documents/dev/montserrat/docs/MAINTAINER_GUIDE.md).

---

## Repository Structure

```text
montserrat/
├── Package.swift                 # Swift package definition
├── Formula/
│   └── montserrat.rb             # Homebrew formula
├── .github/workflows/
│   ├── ci.yml                    # Continuous integration workflow
│   └── release.yml               # Automated release packaging
├── docs/
│   └── MAINTAINER_GUIDE.md       # Kernel driver, performance tuning, and release guide
├── kext/
│   ├── montserrat_vfs.c          # Native Darwin VFS kernel extension
│   ├── Info.plist                # Kernel extension bundle configuration
│   └── build-kext.sh             # KEXT compilation script
├── Sources/
│   ├── CExt2FS/                  # C bridge for direct libext2fs linking
│   ├── MontserratCore/           # Core library
│   │   ├── DiskArbitration/      # Hardware event listening
│   │   ├── Probing/              # Superblock inspection and backup recovery
│   │   ├── Notifications/        # System notification dispatching
│   │   ├── Safety/               # Internal disk protection logic
│   │   ├── Mounting/             # Lifecycle, MountTable, SyncManager
│   │   ├── Tools/                # DiskRepairTool, DiskFormatTool
│   │   ├── Privilege/            # Launchd and elevation helpers
│   │   ├── Engines/              # Driver process discovery
│   │   └── Support/              # Subprocess execution and logging
│   ├── MontserratFSKit/          # Native Apple FSKit VFS extension
│   ├── montserrat/               # CLI executable
│   ├── montserratd/              # Daemon executable
│   └── MontserratApp/            # Menu bar executable
├── Tests/
│   └── MontserratCoreTests/      # Unit and integration test suites
├── engines/                      # Upstream engine source archives and patches
│   ├── build-engines.sh          # Compilation script
│   ├── versions.env              # Pinned versions and SHA-256 sums
│   ├── patches/                  # Darwin VFS patches for e2fsprogs
│   ├── src/                      # Btrfs, XFS, and F2FS engine sources
│   └── conf/                     # Engine configuration files
└── scripts/
    ├── setup-environment.sh      # Environment verification
    ├── build.sh                  # Release staging script
    ├── package-release.sh        # Standalone DMG and PKG packaging script
    ├── run-integration-tests.sh  # Virtual block device integration test harness
    └── install.sh                # System installation script
```

---

## Licensing

- Montserrat Swift codebase: MIT License.
- Engine utilities (e2fsprogs, ntfs-3g, btrfs-fuse, xfs-fuse): GNU General Public License (GPL-2.0).
- FUSE-T: Free for non-commercial use.
