/// What the user asked to measure.
nonisolated enum ScanScope: Sendable {
    /// A whole disk: the scan also covers the other volumes of the disk's APFS container.
    case wholeDisk
    /// One folder: the scan stays on the folder's own volume.
    case folder
}

/// Decides, from the mount table alone, where volumes begin and which of them a scan may enter.
///
/// The mount table is interpreted once, here; afterwards both questions are set lookups.
nonisolated struct VolumePolicy: Sendable {
    private let mountPoints: Set<String>
    private let admitted: Set<String>

    init(scope: ScanScope, rootPath: String, mounts: [Mount]) {
        mountPoints = Set(mounts.map(\.path))
        admitted = scope == .wholeDisk ? Self.siblingVolumes(ofVolumeHolding: rootPath, among: mounts) : []
    }

    /// The mount table has a mount at exactly this path.
    func isMountPoint(_ path: String) -> Bool {
        mountPoints.contains(path)
    }

    /// The volume mounted at exactly this path shares the scan root's APFS container, so a
    /// whole-disk scan goes into it. Snapshots and everything that is not an APFS volume stay out.
    func admits(mountPointAt path: String) -> Bool {
        admitted.contains(path)
    }

    /// `path` is an admitted volume's mount point, lies inside such a volume, or holds one somewhere below.
    func touchesAdmittedVolume(_ path: String) -> Bool {
        admitted.contains { Self.holds(mountPath: $0, path: path) || Self.holds(mountPath: path, path: $0) }
    }
}

private extension VolumePolicy {
    /// Mount paths of the other APFS volumes in the container of the volume that holds `rootPath`.
    nonisolated static func siblingVolumes(ofVolumeHolding rootPath: String, among mounts: [Mount]) -> Set<String> {
        let holders = mounts.filter { holds(mountPath: $0.path, path: rootPath) }
        guard let home = holders.max(by: { $0.path.utf8.count < $1.path.utf8.count }),
              let container = apfsContainer(of: home)
        else { return [] }
        return Set(mounts.filter { $0.path != home.path && apfsContainer(of: $0) == container }.map(\.path))
    }

    /// `path` is the mount path itself or lies below it, judged on whole path components.
    nonisolated static func holds(mountPath: String, path: String) -> Bool {
        mountPath == "/" || path == mountPath || path.hasPrefix(mountPath + "/")
    }

    /// The disk number of an APFS volume's device node: "3" for `/dev/disk3s5` and `/dev/disk3s1s1`.
    /// Nil for anything that is not a plain APFS volume, such as a snapshot (`name@/dev/disk3s5`).
    nonisolated static func apfsContainer(of mount: Mount) -> Substring? {
        let devicePrefix = "/dev/disk"
        guard mount.fileSystem == "apfs", mount.source.hasPrefix(devicePrefix) else { return nil }
        let number = mount.source.dropFirst(devicePrefix.count).prefix { ("0"..."9").contains($0) }
        return number.isEmpty ? nil : number
    }
}
