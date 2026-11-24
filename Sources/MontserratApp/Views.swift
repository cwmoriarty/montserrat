import SwiftUI
import MontserratCore

struct DiskMenuView: View {
    @ObservedObject var model: AppModel
    @State private var showingLogs = false
    @State private var showingFormatSheet = false
    @State private var formatTarget = ""
    @State private var formatLabel = "Data"
    @State private var formatKind: FileSystemKind = .ext4
    @State private var showingLUKSSheet = false
    @State private var luksTarget = ""
    @State private var luksPassphrase = ""
    @State private var luksReadOnly = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header bar
            HStack(spacing: 8) {
                Image(systemName: "internaldrive")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)

                Text("Montserrat")
                    .font(.system(size: 13, weight: .semibold))

                Text("v\(model.appVersion)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color(NSColor.quaternaryLabelColor))
                    .cornerRadius(4)

                Spacer()

                Button(action: { model.refresh() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Refresh disk list")
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider()

            // Quick Controls Bar
            HStack(spacing: 10) {
                Toggle("Fakeroot", isOn: $model.useFakeroot)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 10))
                    .help("Map ext2/3/4 file permissions to current user on mount")

                if !model.daemonLoaded {
                    Toggle("Auto-Mount", isOn: $model.autoMountEnabled)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 10))
                        .help("Automatically mount supported drives while menu bar app is running")
                } else {
                    Text("Daemon: Active")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.green)
                }

                Spacer()

                Button(model.daemonLoaded ? "Uninstall Daemon" : "Install Daemon") {
                    model.toggleDaemonInstall()
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .font(.system(size: 10))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            // Disk and Volume Content
            if model.disks.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "externaldrive")
                        .font(.system(size: 28, weight: .light))
                        .foregroundColor(.secondary.opacity(0.7))
                        .padding(.top, 16)

                    Text("No External Drives")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)

                    Text("Connected Linux, BSD, NTFS, and archival block devices appear here automatically.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 16)
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.disks) { disk in
                            DiskCard(disk: disk, model: model, onFormat: { bsd in
                                formatTarget = "/dev/\(bsd)"
                                showingFormatSheet = true
                            }, onUnlockLUKS: { bsd in
                                luksTarget = "/dev/\(bsd)"
                                luksPassphrase = ""
                                showingLUKSSheet = true
                            })
                        }
                    }
                    .padding(12)
                }
                .frame(maxHeight: 280)
            }

            Divider()

            // Status and Footer Bar
            HStack(spacing: 8) {
                Circle()
                    .fill(model.activeMounts.isEmpty ? Color.secondary.opacity(0.4) : Color.green)
                    .frame(width: 6, height: 6)

                Text(model.statusMessage)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Spacer()

                Button("Logs") {
                    showingLogs.toggle()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)

                Text("•")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary.opacity(0.4))

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 380)
        .sheet(isPresented: $showingFormatSheet) {
            FormatSheet(
                target: formatTarget,
                label: $formatLabel,
                type: $formatKind,
                onCancel: { showingFormatSheet = false },
                onFormat: {
                    model.format(target: formatTarget, type: formatKind, label: formatLabel)
                    showingFormatSheet = false
                }
            )
        }
        .sheet(isPresented: $showingLUKSSheet) {
            UnlockLUKSSheet(
                target: luksTarget,
                passphrase: $luksPassphrase,
                readOnly: $luksReadOnly,
                onCancel: {
                    luksPassphrase = ""
                    showingLUKSSheet = false
                },
                onUnlock: {
                    let pass = luksPassphrase
                    luksPassphrase = ""
                    showingLUKSSheet = false
                    model.unlockLUKS(target: luksTarget, passphrase: pass, readOnly: luksReadOnly)
                }
            )
        }
        .popover(isPresented: $showingLogs) {
            LogView(logs: model.logs)
                .frame(width: 480, height: 280)
        }
    }
}

struct DiskCard: View {
    let disk: DiskInfo
    @ObservedObject var model: AppModel
    let onFormat: (String) -> Void
    let onUnlockLUKS: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "externaldrive")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)

                Text(disk.name)
                    .font(.system(size: 12, weight: .semibold))

                Text(disk.bsdName)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)

                Spacer()

                Button("Eject") {
                    model.eject(disk: disk.bsdName)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .font(.system(size: 10, weight: .medium))
            }

            ForEach(disk.volumes) { vol in
                VolumeRow(
                    vol: vol,
                    model: model,
                    onFormat: { onFormat(vol.bsdName) },
                    onUnlockLUKS: { onUnlockLUKS(vol.bsdName) }
                )
            }
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(NSColor.separatorColor).opacity(0.5), lineWidth: 0.5)
        )
    }
}

struct VolumeRow: View {
    let vol: VolumeInfo
    @ObservedObject var model: AppModel
    let onFormat: () -> Void
    let onUnlockLUKS: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(vol.isMounted ? Color.green : Color.secondary.opacity(0.35))
                .frame(width: 6, height: 6)

            Text(vol.fileSystem.label ?? vol.bsdName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(1)

            Text(vol.fileSystem.kind.displayName.uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(.secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color(NSColor.quaternaryLabelColor))
                .cornerRadius(3)

            Spacer()

            if vol.isMounted {
                if let mnt = vol.effectiveMountPoint {
                    Button("Open") {
                        model.openMountPoint(mnt)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .font(.system(size: 10, weight: .medium))
                }

                Button("Unmount") {
                    model.unmount(target: vol.effectiveMountPoint ?? "/dev/\(vol.bsdName)")
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .font(.system(size: 10, weight: .medium))
            } else if vol.fileSystem.kind.isSupportedByMontserrat {
                Button("Mount") {
                    model.mount(target: "/dev/\(vol.bsdName)", readOnly: false)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
                .font(.system(size: 10, weight: .semibold))

                Menu {
                    Button("Mount Read-Only") {
                        model.mount(target: "/dev/\(vol.bsdName)", readOnly: true)
                    }
                    Button("Check (Read-Only)") {
                        model.checkReadOnly(target: "/dev/\(vol.bsdName)")
                    }
                    Button("Check and Repair") {
                        model.repair(target: "/dev/\(vol.bsdName)")
                    }
                    if model.testDiskNGPath != nil {
                        Divider()
                        Button("Recover Partition (TestDisk-NG)") {
                            model.openInTestDiskNG(target: "/dev/\(vol.bsdName)", preferPhotoRec: false)
                        }
                    }
                    if model.photoRecNGPath != nil {
                        Button("Carve Files (PhotoRec-NG)") {
                            model.openInTestDiskNG(target: "/dev/\(vol.bsdName)", preferPhotoRec: true)
                        }
                    }
                    Divider()
                    Button("Format...") {
                        onFormat()
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 10, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 14)
            } else if vol.fileSystem.kind.isReadOnlySupported {
                Button("Mount Read-Only") {
                    model.mount(target: "/dev/\(vol.bsdName)", readOnly: true)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .font(.system(size: 10, weight: .semibold))

                Menu {
                    if model.testDiskNGPath != nil {
                        Button("Recover Partition (TestDisk-NG)") {
                            model.openInTestDiskNG(target: "/dev/\(vol.bsdName)", preferPhotoRec: false)
                        }
                    }
                    if model.photoRecNGPath != nil {
                        Button("Carve Files (PhotoRec-NG)") {
                            model.openInTestDiskNG(target: "/dev/\(vol.bsdName)", preferPhotoRec: true)
                        }
                    }
                    if model.testDiskNGPath != nil || model.photoRecNGPath != nil {
                        Divider()
                    }
                    Button("Format...") {
                        onFormat()
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 10, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 14)
            } else if vol.fileSystem.kind == .luks1 || vol.fileSystem.kind == .luks2 {
                Button("Unlock...") {
                    onUnlockLUKS()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
                .font(.system(size: 10, weight: .semibold))

                Menu {
                    if model.testDiskNGPath != nil {
                        Button("Recover Partition (TestDisk-NG)") {
                            model.openInTestDiskNG(target: "/dev/\(vol.bsdName)", preferPhotoRec: false)
                        }
                        Divider()
                    }
                    Button("Format...") {
                        onFormat()
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 10, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 14)
            } else if vol.fileSystem.kind == .lvm2 {
                Button("Activate VG") {
                    model.activateLVM2(target: "/dev/\(vol.bsdName)")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
                .font(.system(size: 10, weight: .semibold))

                Menu {
                    if model.testDiskNGPath != nil {
                        Button("Recover Partition (TestDisk-NG)") {
                            model.openInTestDiskNG(target: "/dev/\(vol.bsdName)", preferPhotoRec: false)
                        }
                        Divider()
                    }
                    Button("Format...") {
                        onFormat()
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 10, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 14)
            } else {
                Text(vol.fileSystem.kind.isContainer ? "Container" : "Detected")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)

                Menu {
                    if model.testDiskNGPath != nil {
                        Button("Recover Partition (TestDisk-NG)") {
                            model.openInTestDiskNG(target: "/dev/\(vol.bsdName)", preferPhotoRec: false)
                        }
                    }
                    if model.photoRecNGPath != nil {
                        Button("Carve Files (PhotoRec-NG)") {
                            model.openInTestDiskNG(target: "/dev/\(vol.bsdName)", preferPhotoRec: true)
                        }
                    }
                    if model.testDiskNGPath != nil || model.photoRecNGPath != nil {
                        Divider()
                    }
                    Button("Format...") {
                        onFormat()
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 10, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 14)
            }
        }
        .padding(.leading, 8)
        .padding(.vertical, 2)
    }
}

struct FormatSheet: View {
    let target: String
    @Binding var label: String
    @Binding var type: FileSystemKind
    let onCancel: () -> Void
    let onFormat: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Format Partition: \(target)")
                .font(.system(size: 13, weight: .semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("Volume Name")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)

                TextField("Label", text: $label)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Filesystem Type")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)

                Picker("", selection: $type) {
                    Text("ext4 (Linux Standard)").tag(FileSystemKind.ext4)
                    Text("XFS (Linux Server)").tag(FileSystemKind.xfs)
                    Text("Btrfs (Linux Copy-on-Write)").tag(FileSystemKind.btrfs)
                    Text("ext3 (Linux Journaled)").tag(FileSystemKind.ext3)
                    Text("ext2 (Linux Legacy)").tag(FileSystemKind.ext2)
                    Text("NTFS (Windows Standard)").tag(FileSystemKind.ntfs)
                }
                .pickerStyle(.radioGroup)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Caution: All files and structures on \(target) will be erased permanently.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(6)

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Button("Format", action: onFormat)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 4)
        }
        .padding(16)
        .frame(width: 340)
    }
}

struct UnlockLUKSSheet: View {
    let target: String
    @Binding var passphrase: String
    @Binding var readOnly: Bool
    let onCancel: () -> Void
    let onUnlock: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Unlock Encrypted Volume: \(target)")
                .font(.system(size: 13, weight: .semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("LUKS Passphrase")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)

                SecureField("Enter passphrase", text: $passphrase)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }

            Toggle("Mount Read-Only", isOn: $readOnly)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Button("Unlock and Mount", action: onUnlock)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(passphrase.isEmpty)
            }
            .padding(.top, 4)
        }
        .padding(16)
        .frame(width: 340)
    }
}

struct LogView: View {
    let logs: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Activity and Engine Log")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(logs.count) entries")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(logs.indices, id: \.self) { idx in
                        Text(logs[idx])
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
            }
            .background(Color(NSColor.textBackgroundColor))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(NSColor.separatorColor).opacity(0.5), lineWidth: 0.5)
            )
        }
        .padding(14)
    }
}
