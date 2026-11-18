import SwiftUI

/// Where a scan is chosen: the startup disk, or any folder.
struct StartView: View {
    let workspace: ScanWorkspace

    @State private var access = FullDiskAccess.Status.notGranted
    @State private var startupDisk = StartupDisk.current()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "internaldrive")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text("What Is Taking Up Space")
                    .font(.largeTitle.bold())
                Text(startupDisk.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button("Scan \(startupDisk.name)", action: workspace.scanStartupDisk)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                Button("Choose Folder…") { workspace.isChoosingFolder = true }
            }
            .controlSize(.large)
            Text("You can also drop a folder on this window.")
                .font(.callout)
                .foregroundStyle(.secondary)
            FullDiskAccessNotice(status: access)
                .frame(maxWidth: 520)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: scenePhase, initial: true) {
            // Coming back from System Settings: the answer may have changed.
            access = FullDiskAccess.status()
            startupDisk = StartupDisk.current()
        }
    }
}

/// Says whether the app can read everything, and how to let it.
private struct FullDiskAccessNotice: View {
    let status: FullDiskAccess.Status
    @Environment(\.openURL) private var openURL

    var body: some View {
        switch status {
        case .granted:
            Label("Full Disk Access is on: every folder you can read will be measured.", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.secondary)
        case .notGranted:
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Full Disk Access is off", systemImage: "lock.trianglebadge.exclamationmark")
                        .font(.headline)
                    Text("Without it, protected folders such as Mail and other apps’ data are shown as “No access”, and macOS asks about Documents, Desktop and Downloads one at a time. Turn it on for this app, then reopen the app.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open System Settings…") { openURL(FullDiskAccess.settingsURL) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
        }
    }
}

/// The startup disk's name and how full it is.
struct StartupDisk: Equatable {
    var name: String
    var caption: String

    static func current() -> StartupDisk {
        let name = VolumeName.ofVolume(holding: "/") ?? "Startup Disk"
        guard let space = try? VolumeSpace.read(forPath: "/") else {
            return StartupDisk(name: name, caption: "Find the folders and files that fill your disk.")
        }
        let free = space.free.formatted(.fileSize)
        let capacity = space.capacity.formatted(.fileSize)
        return StartupDisk(name: name, caption: "\(name): \(free) free of \(capacity)")
    }
}

#if DEBUG
#Preview("Access on") {
    FullDiskAccessNotice(status: .granted).padding()
}

#Preview("Access off") {
    FullDiskAccessNotice(status: .notGranted).padding().frame(width: 560)
}
#endif
