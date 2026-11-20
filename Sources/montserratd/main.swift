import Foundation
import MontserratCore

final class MontserratDaemon: @unchecked Sendable {
    private let watcher = DiskWatcher()
    private let mountManager = MountManager.shared
    private var isRunning = false

    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())

        if args.contains("--install") {
            do {
                let binPath = CommandLine.arguments[0]
                try PrivilegeManager.installDaemon(daemonExecutablePath: binPath)
                print("Successfully installed and started com.cwmoriarty.montserratd")
                exit(0)
            } catch {
                fputs("Failed to install daemon: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }

        if args.contains("--uninstall") {
            do {
                try PrivilegeManager.uninstallDaemon()
                print("Successfully uninstalled com.cwmoriarty.montserratd")
                exit(0)
            } catch {
                fputs("Failed to uninstall daemon: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }

        if args.contains("--status") {
            let loaded = PrivilegeManager.isDaemonLoaded()
            print("Daemon loaded: \(loaded ? "YES" : "NO")")
            exit(0)
        }

        print("Starting montserratd auto-mount background daemon...")
        let daemon = MontserratDaemon()
        daemon.start()
    }

    func start() {
        isRunning = true

        // Initial scan of connected external disks
        scanAndMountExistingDisks()

        // Start listening to live DiskArbitration events
        watcher.start { bsdName, event in
            switch event {
            case .appeared:
                self.handleDiskAppeared(bsdName: bsdName)
            case .disappeared:
                self.handleDiskDisappeared(bsdName: bsdName)
            case .changed:
                self.mountManager.reconcileActiveMounts()
            }
        }

        // Periodic timer to reconcile external unmounts/ejects every 5 seconds
        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            self.mountManager.reconcileActiveMounts()
        }

        // Periodic log rotation check every hour
        rotateLogsIfNeeded()
        Timer.scheduledTimer(withTimeInterval: 3600.0, repeats: true) { _ in
            self.rotateLogsIfNeeded()
        }

        print("montserratd is actively monitoring external disks. Running runloop...")
        RunLoop.current.run()
    }

    private func scanAndMountExistingDisks() {
        print("[montserratd] Scanning connected external disks...")
        let disks = DiskProbe.listDisks(includeInternal: false)
        print("[montserratd] Found \(disks.count) external disk(s)")
        for disk in disks {
            print("[montserratd] Disk \(disk.bsdName): \(disk.volumes.count) volume(s)")
            for vol in disk.volumes {
                tryMountVolume(vol)
            }
        }
    }

    private func handleDiskAppeared(bsdName: String) {
        print("[montserratd] Device appearance notification: \(bsdName)")
        // Sleep briefly to let kernel and disk arbitration settle partition table
        Thread.sleep(forTimeInterval: 0.5)

        if let disk = DiskProbe.inspectDisk(bsdName: bsdName) {
            print("[montserratd] Inspected disk \(bsdName) with \(disk.volumes.count) volume(s)")
            for vol in disk.volumes {
                tryMountVolume(vol)
            }
        } else if let vol = DiskProbe.inspectVolume(bsdName: bsdName) {
            tryMountVolume(vol)
        }
    }

    private func tryMountVolume(_ vol: VolumeInfo) {
        print("[montserratd] Checking volume: \(vol.bsdName), filesystem: \(vol.fileSystem.kind.displayName), isMounted: \(vol.isMounted)")
        guard vol.fileSystem.kind.isSupportedByMontserrat else {
            return
        }

        guard !vol.isMounted else {
            return
        }

        // Validate safety policy
        if let disk = DiskProbe.inspectDisk(bsdName: vol.wholeDiskBSDName) {
            do {
                try SafetyPolicy.validate(disk: disk, volume: vol)
            } catch {
                fputs("[montserratd] Safety violation for \(vol.bsdName): \(error.localizedDescription)\n", stderr)
                return
            }
        }

        let devPath = "/dev/\(vol.bsdName)"
        let readOnly = (vol.fileSystem.state == .needsRecovery || vol.fileSystem.state == .needsCheck)

        let req = MountRequest(
            target: devPath,
            readOnly: readOnly,
            allowUnclean: false
        )

        do {
            print("[montserratd] Auto-mounting \(devPath) (\(vol.fileSystem.kind.displayName), \(readOnly ? "RO" : "RW"))...")
            let record = try mountManager.mount(req)
            print("[montserratd] Successfully auto-mounted \(devPath) at \(record.mountPoint)")
            NotificationManager.shared.post(
                event: .volumeMounted(
                    volume: vol.bsdName,
                    fsKind: vol.fileSystem.kind.displayName,
                    mountPoint: record.mountPoint
                )
            )
        } catch {
            fputs("[montserratd] Auto-mount failed for \(devPath): \(error.localizedDescription)\n", stderr)
            NotificationManager.shared.post(
                event: .mountFailed(volume: vol.bsdName, error: error.localizedDescription)
            )
        }
    }

    private func handleDiskDisappeared(bsdName: String) {
        print("[montserratd] Disk disappeared: \(bsdName). Cleaning up active mounts and orphaned processes...")
        mountManager.handleDeviceDisappeared(bsdName: bsdName)
        mountManager.reconcileActiveMounts()
        NotificationManager.shared.post(event: .volumeUnmounted(volume: bsdName))
    }

    private func rotateLogsIfNeeded() {
        let maxBytes: UInt64 = 10 * 1024 * 1024
        let logPaths = ["/var/log/montserratd.log", "/var/log/montserratd.err.log"]
        let fm = FileManager.default
        for path in logPaths {
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let size = attrs[.size] as? UInt64,
                  size > maxBytes else {
                continue
            }
            let backupPath = "\(path).1"
            _ = try? fm.removeItem(atPath: backupPath)
            _ = try? fm.moveItem(atPath: path, toPath: backupPath)
            fm.createFile(atPath: path, contents: Data(), attributes: nil)
        }
    }
}

MontserratDaemon.main()
