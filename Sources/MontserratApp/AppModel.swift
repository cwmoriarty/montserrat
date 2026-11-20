import SwiftUI
import MontserratCore

@MainActor
public final class AppModel: ObservableObject {
    @Published public var disks: [DiskInfo] = []
    @Published public var activeMounts: [MountRecord] = []
    @Published public var autoMountEnabled: Bool = true
    @Published public var selectedDiskForRepair: String? = nil
    @Published public var statusMessage: String = "Ready"
    @Published public var logs: [String] = []

    private let watcher = DiskWatcher()
    private let mountManager = MountManager.shared

    public init() {
        NotificationManager.shared.requestAuthorization()
        refresh()
        startWatcher()
    }

    public func refresh() {
        self.disks = DiskProbe.listDisks(includeInternal: false)
        self.activeMounts = mountManager.activeMounts()
    }

    private func startWatcher() {
        watcher.start { [weak self] bsdName, event in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.log("Disk event: \(bsdName) -> \(event)")
                self.refresh()
            }
        }
    }

    public func mount(target: String, readOnly: Bool = false) {
        log("Mounting \(target) (RO: \(readOnly))...")
        statusMessage = "Mounting \(target)..."
        Task.detached {
            do {
                let req = MountRequest(target: target, readOnly: readOnly)
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
                try MountManager.shared.unmount(target: target)
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
                try MountManager.shared.eject(target: disk)
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

    public func repair(target: String) {
        log("Checking and repairing \(target)...")
        statusMessage = "Repairing..."
        Task.detached {
            do {
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

    public func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logs.append("[\(timestamp)] \(message)")
        if logs.count > 100 {
            logs.removeFirst()
        }
    }
}
