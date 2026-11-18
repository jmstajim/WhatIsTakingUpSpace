import Foundation

/// What a finished scan hands to the interface.
nonisolated struct ScanOutcome: Sendable, Identifiable {
    /// Tells one finished scan from the next; node IDs of one must not be used with another.
    let id = UUID()
    let tree: FileTree
    let summary: DiskSummary
    /// The directories the scan was not allowed to read, found once here because looking for
    /// them means going through every node.
    let unreadable: [FileTree.NodeID]

    init(tree: FileTree, summary: DiskSummary) {
        self.tree = tree
        self.summary = summary
        unreadable = tree.nodes(flagged: .unreadable)
    }
}

/// Measures a disk or a folder. The interface knows scanning only through this.
nonisolated protocol Scanning: Sendable {
    /// Scans everything below `rootPath`, which must be an absolute path without symlinks.
    func scan(rootPath: String, progress: @escaping @Sendable (ScanProgress) -> Void) async throws -> ScanOutcome

    /// Brings one folder of an earlier scan up to date. `folder` is named by the path components
    /// leading to it from the scan root.
    func rescan(
        folder: [String],
        of previous: ScanOutcome,
        progress: @escaping @Sendable (ScanProgress) -> Void
    ) async throws -> ScanOutcome
}

/// Puts the pieces together: the mount table decides how far a scan reaches, the scanner walks
/// the directories, and the volume's own figures say how much the walk did not find.
nonisolated struct DiskScanner: Scanning {
    var reader: any DirectoryReader = BulkDirectoryReader()
    var looseCutoff: Int64 = LooseFiles.cutoff
    var parallelism: Int = ProcessInfo.processInfo.activeProcessorCount
    var mounts: @Sendable () -> [Mount] = MountTable.current
    var space: @Sendable (String) throws -> VolumeSpace = VolumeSpace.read(forPath:)

    @concurrent
    func scan(rootPath: String, progress: @escaping @Sendable (ScanProgress) -> Void) async throws -> ScanOutcome {
        try await scan(rootPath: rootPath, foundLastTime: nil, progress: progress)
    }

    /// Rescans only `folder` when that gives the same answer as a whole scan would. It does not when
    /// the folder is the scan root, is not a folder of the tree, or lies at, inside or above a volume
    /// the scan enters: such volumes are read after everything outside them, an order only a whole
    /// scan keeps. A folder that has disappeared is replaced by a rescan of its parent.
    @concurrent
    func rescan(
        folder: [String],
        of previous: ScanOutcome,
        progress: @escaping @Sendable (ScanProgress) -> Void
    ) async throws -> ScanOutcome {
        let tree = previous.tree
        let rootPath = tree.name(of: tree.root)
        guard let node = separatelyScannableFolder(at: folder, in: tree, reach: reach(ofScanAt: rootPath)) else {
            return try await scan(rootPath: rootPath, foundLastTime: tree.size(of: tree.root), progress: progress)
        }
        let path = tree.path(of: node)
        do {
            let subtree = try await walk(
                path,
                policy: reach(ofScanAt: path, scope: .folder).policy,
                expecting: tree.size(of: node),
                progress: progress
            )
            return try outcome(
                tree.replacingSubtree(at: node, with: subtree),
                coversWholeVolume: previous.summary.coversWholeVolume
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return try await rescan(folder: Array(folder.dropLast()), of: previous, progress: progress)
        }
    }
}

private nonisolated extension DiskScanner {
    /// How far a scan started at some path goes.
    struct Reach {
        let policy: VolumePolicy
        /// The scan starts at the root of a volume, so what it finds can be set against the volume's figures.
        let coversWholeVolume: Bool
    }

    /// A scan that starts at a volume's mount point measures the whole disk; any other, one folder.
    func reach(ofScanAt rootPath: String, scope: ScanScope? = nil) -> Reach {
        let mounts = mounts()
        let startsAtVolumeRoot = mounts.contains { $0.path == rootPath }
        let scope = scope ?? (startsAtVolumeRoot ? .wholeDisk : .folder)
        return Reach(
            policy: VolumePolicy(scope: scope, rootPath: rootPath, mounts: mounts),
            coversWholeVolume: startsAtVolumeRoot
        )
    }

    /// A whole scan. It expects to find what it found last time; a first scan of a volume, what the
    /// volume says is used, which is more than its files hold; a first scan of a folder, nothing.
    func scan(
        rootPath: String,
        foundLastTime: Int64?,
        progress: @escaping @Sendable (ScanProgress) -> Void
    ) async throws -> ScanOutcome {
        let reach = reach(ofScanAt: rootPath)
        let expected = foundLastTime ?? (reach.coversWholeVolume ? usedSpace(ofVolumeAt: rootPath) : nil)
        let tree = try await walk(rootPath, policy: reach.policy, expecting: expected, progress: progress)
        return try outcome(tree, coversWholeVolume: reach.coversWholeVolume)
    }

    /// `nil` when the volume will not say: the scan then runs without an expectation.
    func usedSpace(ofVolumeAt path: String) -> Int64? {
        (try? space(path)).map { $0.capacity - $0.free }
    }

    func separatelyScannableFolder(at components: [String], in tree: FileTree, reach: Reach) -> FileTree.NodeID? {
        guard let node = tree.node(at: components), node != tree.root, tree.kind(of: node) == .directory,
              !reach.policy.touchesAdmittedVolume(tree.path(of: node))
        else { return nil }
        return node
    }

    func walk(
        _ rootPath: String,
        policy: VolumePolicy,
        expecting expected: Int64?,
        progress: @escaping @Sendable (ScanProgress) -> Void
    ) async throws -> FileTree {
        try await TreeScanner(reader: reader, policy: policy, looseCutoff: looseCutoff, parallelism: parallelism)
            .scan(root: rootPath) { report in
                var report = report
                report.expectedBytes = expected
                progress(report)
            }
    }

    func outcome(_ tree: FileTree, coversWholeVolume: Bool) throws -> ScanOutcome {
        let rootPath = tree.name(of: tree.root)
        let summary = DiskSummary(
            space: try space(rootPath),
            foundInFiles: tree.size(of: tree.root),
            coversWholeVolume: coversWholeVolume
        )
        return ScanOutcome(tree: tree, summary: summary)
    }
}
