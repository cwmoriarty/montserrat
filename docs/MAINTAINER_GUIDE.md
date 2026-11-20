# Montserrat Maintainer and Performance Guide

This document details the performance optimization architecture for user-space operation, the native Darwin VFS kernel driver option, Apple code-signing and notarization requirements, and the release publishing workflow.

---

## 1. High-Performance User-Space Architecture

To approach native kernel driver throughput on macOS without compromising system integrity, Montserrat bypasses traditional FUSE bottlenecks through targeted subsystem tuning:

### A. Apple FSKit Native VFS Interface (macOS 15 and Later)
- **Bottleneck in FUSE-T**: FUSE-T bridges filesystems using an NFSv4 localhost loopback socket. Every metadata inspection and data read/write requires serialization over network sockets and multiple user-kernel context switches.
- **FSKit Acceleration**: Apple FSKit (`FSKit.framework`, introduced in macOS 15 Sequoia) provides direct kernel-to-user-space VFS bindings. Storage pages are mapped directly between kernel space and the user-space filesystem extension via Mach shared memory (`mach_vm_map`).
- **Implementation**: Scaffolding is located at [Sources/MontserratFSKit/MontserratFSKit.swift](file:///Users/cwm/Documents/dev/montserrat/Sources/MontserratFSKit/MontserratFSKit.swift). Using FSKit reduces metadata latency from ~150 microseconds to ~15-20 microseconds per operation.

### B. Direct Raw Character Device Access (`/dev/rdisk*`)
- Standard block devices (`/dev/disk*`) route through the Darwin Unified Buffer Cache (UBC), enforcing 4 KB chunking and redundant memory copies.
- Accessing the raw character device (`/dev/rdisk*`) executes direct DMA transfers between hardware controllers and user-space memory buffers, eliminating double-buffering.

### C. FUSE-T Transfer Size and RPC Tuning
When operating on the FUSE-T loopback interface, mount options must maximize transaction payloads:
- `rsize=1048576` and `wsize=1048576`: Increases payload size from the default 128 KB to 1 MB per transaction.
- `locallocks`: Handles byte-range file locks locally, preventing loopback network lock calls.
- `actimeo=120`: Caches directory and file attributes in the macOS VFS for 120 seconds.
- `big_writes`: Enables 128 KB clustered writes for NTFS via ntfs-3g, cutting context switches by up to 96%.
- `noatime`: Disables access time metadata writes upon read operations.

---

## 2. Kernel Driver Option (Montserrat VFS KEXT)

For specialized deployments requiring in-kernel execution (such as shared-writable `mmap` with database write-backs or zero-IPC latency on high-bandwidth NVMe arrays), Montserrat provides a native Darwin VFS kernel extension:

- Driver source: [kext/montserrat_vfs.c](file:///Users/cwm/Documents/dev/montserrat/kext/montserrat_vfs.c)
- Bundle descriptor: [kext/Info.plist](file:///Users/cwm/Documents/dev/montserrat/kext/Info.plist)
- Build script: [kext/build-kext.sh](file:///Users/cwm/Documents/dev/montserrat/kext/build-kext.sh)

### Compilation
The kernel extension compiles against Xcode's `Kernel.framework` headers using Darwin kernel flags (`-mkernel`, `-fno-builtin`, `-nostdinc`):

```bash
./kext/build-kext.sh
```

The resulting binary bundle is placed at `dist/kext/montserrat.kext`.

---

## 3. Apple Code Signing, Notarization, and Installation

Apple applies strict security gates to third-party kernel extensions, requiring developer authorization, notarization, and user approval in Recovery Mode.

### Step 1: Apple Developer Account and KEXT Entitlement
1. Request a **Kernel Extension Signing Certificate** via the Apple Developer portal.
2. Apple evaluates the request and provisions a `Developer ID Application` certificate with kernel extension capabilities (`com.apple.developer.kext.kext-management`).

### Step 2: Code Signing
Sign the kernel extension bundle with hardened runtime and a secure timestamp:

```bash
codesign --force --verify --verbose --sign "Developer ID Application: Your Name (TEAM_ID)" --options runtime --timestamp dist/kext/montserrat.kext
```

### Step 3: Apple Notarization
Package the signed kernel extension:

```bash
ditto -c -k --keepParent dist/kext/montserrat.kext montserrat-kext.zip
```

Submit the archive to the Apple Notary Service:

```bash
xcrun notarytool submit montserrat-kext.zip --keychain-profile "AC_PASSWORD" --wait
```

Staple the notarization ticket to the bundle:

```bash
xcrun stapler staple dist/kext/montserrat.kext
```

### Step 4: System Security Configuration (Apple Silicon)
On Apple Silicon hardware (macOS 15 through 27), the kernel rejects third-party extensions unless security policy is configured:
1. Shut down the computer.
2. Hold the power button until the startup options screen appears.
3. Select **Options**, click **Continue**, then navigate to **Utilities** > **Startup Security Utility**.
4. Select the system drive, click **Security Policy...**, and select **Reduced Security**.
5. Check the box: **Allow user management of kernel extensions from identified developers**.
6. Click **OK**, authenticate with administrator credentials, and restart the system.

### Step 5: Installation and Auxiliary Kernel Collection Rebuild
Copy the bundle into system extensions:

```bash
sudo cp -R dist/kext/montserrat.kext /Library/Extensions/
```

Set permissions:

```bash
sudo chown -R root:wheel /Library/Extensions/montserrat.kext
```

```bash
sudo chmod -R 755 /Library/Extensions/montserrat.kext
```

Rebuild the auxiliary kernel collection:

```bash
sudo kmutil load -p /Library/Extensions/montserrat.kext
```

### Step 6: User Approval
1. Open macOS **System Settings** > **Privacy and Security**.
2. Scroll to the **Security** section.
3. Click **Allow** next to the prompt indicating the extension was blocked.
4. Restart the Mac to activate the rebuilt kernel collection (`auxkc`).

---

## 4. Release and Distribution Workflow

Maintainers release new versions using the following protocol:

### Step 1: Build and Stage Artifacts
Generate production binaries and distribution packages:

```bash
./scripts/build.sh
```

Package the signed and notarized `.dmg`, `.pkg`, and release tarball:

```bash
./scripts/package-release.sh
```

To configure Apple ID credentials for automated notarization:

```bash
./scripts/setup-apple-notary.sh
```

This registers credentials in the macOS Keychain under profile `montserrat-notary` with Team ID `854M65LRV4` and enables automatic submission and stapling during packaging.

### Step 2: Calculate SHA-256 Checksum
Checksums are automatically produced in `dist/release/checksums.txt`:

```bash
cat dist/release/checksums.txt
```

### Step 3: Publish GitHub Release
Tag the git commit and push to remote:

```bash
git tag v1.0.0
```

```bash
git push origin v1.0.0
```

Publish the release using the GitHub CLI:

```bash
gh release create v1.0.0 montserrat-universal-v1.0.0.tar.gz --title "Montserrat v1.0.0" --notes "Initial production release of Montserrat filesystem tools for modern macOS."
```

### Step 4: Update Homebrew Formula
1. Update `url` and `sha256` in [Formula/montserrat.rb](file:///Users/cwm/Documents/dev/montserrat/Formula/montserrat.rb) and `/opt/homebrew/Library/Taps/cwmoriarty/homebrew-tap/Formula/montserrat.rb`.
2. Commit and push the tap repository:

```bash
cd /opt/homebrew/Library/Taps/cwmoriarty/homebrew-tap
```

```bash
git add Formula/montserrat.rb
```

```bash
git commit -m "Update Montserrat formula to v1.0.0"
```

```bash
git push origin main
```
