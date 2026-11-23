import SwiftUI
import AppKit
import MontserratCore
#if canImport(Darwin)
import Darwin
#endif

@MainActor
public final class AppModel: ObservableObject {
    @Published public var disks: [DiskInfo] = []
    @Published public var activeMounts: [MountRecord] = []
    @Published public var autoMountEnabled: Bool = false
    @Published public var useFakeroot: Bool = false
    @Published public var daemonLoaded: Bool = false
    @Published public var selectedDiskForRepair: String? = nil
    @Published public var statusMessage: String = "Ready"
    @Published public var logs: [String] = []

    private let watcher = DiskWatcher()
    private let mountManager = MountManager.shared

    public var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.1"
    }

    public init() {
        NotificationManager.shared.requestAuthorization()
        refresh()
        startWatcher()
    }

    public func refresh() {
        self.disks = DiskProbe.listDisks(includeInternal: false)
        self.activeMounts = mountManager.activeMounts()
        self.daemonLoaded = PrivilegeManager.isDaemonLoaded()
    }

    private func startWatcher() {
        watcher.start { [weak self] bsdName, event in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.log("Disk event: \(bsdName) -> \(event)")
                self.refresh()
                if event == .appeared, self.autoMountEnabled, !self.daemonLoaded {
                    self.autoMountNewDevice(bsdName: bsdName)
                }
            }
        }
    }

    private func autoMountNewDevice(bsdName: String) {
        let cleanBsd = DiskProbe.cleanBSDName(bsdName)
        let targetDisks = disks.filter {
            $0.bsdName == cleanBsd || $0.volumes.contains(where: { $0.bsdName == cleanBsd })
        }
        for disk in targetDisks {
            for vol in disk.volumes where vol.fileSystem.kind.isSupportedByMontserrat && !vol.isMounted {
                let needsRO = vol.fileSystem.state == .needsRecovery ||
                              vol.fileSystem.state == .needsCheck ||
                              vol.fileSystem.state == .backupSuperblockRecoverable
                mount(target: "/dev/\(vol.bsdName)", readOnly: needsRO)
            }
        }
    }

    private nonisolated static func requiresElevation(for target: String, writeAccess: Bool) -> Bool {
        if PrivilegeManager.isRoot {
            return false
        }
        #if canImport(Darwin)
        let mode: Int32 = writeAccess ? (R_OK | W_OK) : R_OK
        return Darwin.access(target, mode) != 0
        #else
        return false
        #endif
    }

    private nonisolated static func runPrivilegedCLI(arguments: [String]) throws -> CommandResult {
        guard let cliPath = EngineRegistry.findBinary("montserrat", requireRootOwned: false) else {
            throw MontserratError.engineNotFound("montserrat")
        }
        let command = ([cliPath] + arguments)
            .map { PrivilegeManager.escapeShellArgument($0) }
            .joined(separator: " ")
        let res = try PrivilegeManager.runPrivileged(command: command)
        guard res.isSuccess else {
            let output = res.stderr.isEmpty ? res.stdout : res.stderr
            throw MontserratError.commandFailed("montserrat \(arguments.first ?? "")", exitCode: res.exitCode, output: output)
        }
        return res
    }

    public func mount(target: String, readOnly: Bool = false) {
        let fakeroot = useFakeroot
        log("Mounting \(target) (RO: \(readOnly), fakeroot: \(fakeroot))...")
        statusMessage = "Mounting \(target)..."
        Task.detached {
            do {
                if Self.requiresElevation(for: target, writeAccess: !readOnly) {
                    var args = ["mount", target]
                    if readOnly { args.append("--read-only") }
                    if fakeroot { args.append("--fakeroot") }
                    _ = try Self.runPrivilegedCLI(arguments: args)
                    await MainActor.run {
                        self.log("Mounted \(target) via administrator authorization")
                        self.statusMessage = "Mounted \(target)"
                        NotificationManager.shared.post(
                            event: .volumeMounted(volume: target, fsKind: "Montserrat", mountPoint: "/Volumes")
                        )
                        self.refresh()
                    }
                    return
                }

                let req = MountRequest(target: target, readOnly: readOnly, fakeroot: fakeroot)
                let rec = try MountManager.shared.mount(req)
                await MainActor.run {
                    self.log("Mounted \(rec.source) at \(rec.mountPoint)")
                    self.statusMessage = "Mounted at \(rec.mountPoint)"
                    NotificationManager.shared.post(
                        event: .volumeMounted(
                            volume: rec.source,
                            fsKind: rec.fileSystem.displayName,
                            mountPoint: rec.mountPoint
                        )
                    )
                    self.refresh()
                }
            } catch {
                await MainActor.run {
                    self.log("Mount failed: \(error.localizedDescription)")
                    self.statusMessage = "Error: \(error.localizedDescription)"
                    NotificationManager.shared.post(
                        event: .mountFailed(volume: target, error: error.localizedDescription)
                    )
                }
            }
        }
    }

    public func unmount(target: String) {
        log("Unmounting \(target)...")
        statusMessage = "Unmounting..."
        Task.detached {
            do {
                do {
                    try MountManager.shared.unmount(target: target)
                } catch {
                    if !PrivilegeManager.isRoot {
                        _ = try Self.runPrivilegedCLI(arguments: ["unmount", target])
                    } else {
                        throw error
                    }
                }
                await MainActor.run {
                    self.log("Unmounted \(target)")
                    self.statusMessage = "Unmounted \(target)"
                    NotificationManager.shared.post(event: .volumeUnmounted(volume: target))
                    self.refresh()
                }
            } catch {
                await MainActor.run {
                    self.log("Unmount error: \(error.localizedDescription)")
                    self.statusMessage = "Error: \(error.localizedDescription)"
                }
            }
        }
    }

    public func eject(disk: String) {
        log("Ejecting \(disk)...")
        statusMessage = "Ejecting..."
        Task.detached {
            do {
                do {
                    try MountManager.shared.eject(target: disk)
                } catch {
                    if !PrivilegeManager.isRoot {
                        _ = try Self.runPrivilegedCLI(arguments: ["eject", disk])
                    } else {
                        throw error
                    }
                }
                await MainActor.run {
                    self.log("Ejected \(disk)")
                    self.statusMessage = "Ejected \(disk)"
                    NotificationManager.shared.post(event: .volumeUnmounted(volume: disk))
                    self.refresh()
                }
            } catch {
                await MainActor.run {
                    self.log("Eject error: \(error.localizedDescription)")
                    self.statusMessage = "Error: \(error.localizedDescription)"
                }
            }
        }
    }

    public func checkReadOnly(target: String) {
        log("Checking (read-only) \(target)...")
        statusMessage = "Checking..."
        Task.detached {
            do {
                if Self.requiresElevation(for: target, writeAccess: false) {
                    let res = try Self.runPrivilegedCLI(arguments: ["check", target, "--force"])
                    await MainActor.run {
                        self.log(res.stdout)
                        self.statusMessage = "Check completed cleanly"
                        self.refresh()
                    }
                    return
                }

                let result = try DiskRepairTool.repair(target: target, force: true, autoFix: false)
                await MainActor.run {
                    self.log("Check result for \(target): exit code \(result.exitCode)")
                    self.log(result.details)
                    self.statusMessage = result.success ? "Filesystem is clean" : "Check found issues"
                    self.refresh()
                }
            } catch {
                await MainActor.run {
                    self.log("Check error: \(error.localizedDescription)")
                    self.statusMessage = "Error: \(error.localizedDescription)"
                }
            }
        }
    }

    public func repair(target: String) {
        log("Checking and repairing \(target)...")
        statusMessage = "Repairing..."
        Task.detached {
            do {
                if Self.requiresElevation(for: target, writeAccess: true) {
                    let res = try Self.runPrivilegedCLI(arguments: ["repair", target, "--force"])
                    await MainActor.run {
                        self.log(res.stdout)
                        self.statusMessage = "Repair completed successfully"
                        NotificationManager.shared.post(
                            event: .repairCompleted(volume: target, success: true, details: res.stdout)
                        )
                        self.refresh()
                    }
                    return
                }

                let result = try DiskRepairTool.repair(target: target, force: true, autoFix: true)
                await MainActor.run {
                    self.log("Repair result for \(target): exit code \(result.exitCode)")
                    self.log(result.details)
                    self.statusMessage = result.success ? "Repair completed successfully" : "Repair reported warnings"
                    NotificationManager.shared.post(
                        event: .repairCompleted(
                            volume: target,
                            success: result.success,
                            details: result.details
                        )
                    )
                    self.refresh()
                }
            } catch {
                await MainActor.run {
                    self.log("Repair error: \(error.localizedDescription)")
                    self.statusMessage = "Error: \(error.localizedDescription)"
                }
            }
        }
    }

    public func format(target: String, type: FileSystemKind, label: String) {
        log("Formatting \(target) as \(type.displayName)...")
        statusMessage = "Formatting..."
        Task.detached {
            do {
                if Self.requiresElevation(for: target, writeAccess: true) {
                    _ = try Self.runPrivilegedCLI(
                        arguments: ["format", target, "--type", type.rawValue, "--label", label, "--force", "--yes"]
                    )
                    await MainActor.run {
                        self.log("Formatted \(target) successfully")
                        self.statusMessage = "Formatted \(target)"
                        NotificationManager.shared.post(
                            event: .formatCompleted(volume: target, fsKind: type.displayName)
                        )
                        self.refresh()
                    }
                    return
                }

                let opts = FormatOptions(type: type, label: label, force: true)
                _ = try DiskFormatTool.format(target: target, options: opts)
                await MainActor.run {
                    self.log("Formatted \(target) successfully")
                    self.statusMessage = "Formatted \(target)"
                    NotificationManager.shared.post(
                        event: .formatCompleted(volume: target, fsKind: type.displayName)
                    )
                    self.refresh()
                }
            } catch {
                await MainActor.run {
                    self.log("Format error: \(error.localizedDescription)")
                    self.statusMessage = "Error: \(error.localizedDescription)"
                }
            }
        }
    }

    public func openMountPoint(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }

    public func toggleDaemonInstall() {
        let shouldUninstall = daemonLoaded
        statusMessage = shouldUninstall ? "Uninstalling daemon..." : "Installing daemon..."
        Task.detached {
            do {
                if shouldUninstall {
                    try PrivilegeManager.uninstallDaemon()
                } else {
                    guard let daemonPath = EngineRegistry.findBinary("montserratd", requireRootOwned: false) else {
                        throw MontserratError.engineNotFound("montserratd")
                    }
                    try PrivilegeManager.installDaemon(daemonExecutablePath: daemonPath)
                }
                await MainActor.run {
                    self.log(shouldUninstall ? "Uninstalled background daemon" : "Installed and started background daemon")
                    self.statusMessage = shouldUninstall ? "Daemon uninstalled" : "Daemon running"
                    self.refresh()
                }
            } catch {
                await MainActor.run {
                    self.log("Daemon update error: \(error.localizedDescription)")
                    self.statusMessage = "Error: \(error.localizedDescription)"
                }
            }
        }
    }

    public func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logs.append("[\(timestamp)] \(message)")
        if logs.count > 100 {
            logs.removeFirst()
        }
    }
}
