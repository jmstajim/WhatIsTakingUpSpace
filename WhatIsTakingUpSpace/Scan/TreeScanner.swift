import Foundation

/// Walks a directory hierarchy through a `DirectoryReader` and assembles what it finds into a `FileTree`.
///
/// Worker tasks only read directories. Every decision, and all mutable state, belongs to the
/// single `ScanAssembly` driven by the task that called `scan`, so nothing is shared or locked.
nonisolated struct TreeScanner: Sendable {
    private let reader: any DirectoryReader
    private let classifier: ListingClassifier
    private let parallelism: Int
    private let progressInterval: Int

    /// - Parameters:
    ///   - looseCutoff: files smaller than this many bytes are folded into their directory's `LooseFiles`.
    ///   - parallelism: how many directories may be read at the same time; at least one.
    ///   - progressInterval: how many directories are read between two progress reports; at least one.
    init(
        reader: any DirectoryReader,
        policy: VolumePolicy,
        looseCutoff: Int64 = LooseFiles.cutoff,
        parallelism: Int = ProcessInfo.processInfo.activeProcessorCount,
        progressInterval: Int = 512
    ) {
        self.reader = reader
        classifier = ListingClassifier(policy: policy, looseCutoff: looseCutoff)
        self.parallelism = max(1, parallelism)
        self.progressInterval = max(1, progressInterval)
    }

    /// Scans everything below `root`. Throws when the root itself cannot be read, and
    /// `CancellationError` when the surrounding task is cancelled.
    ///
    /// `progress` is called on the scanning task: once every `progressInterval` directories and
    /// once more at the end with the totals of the finished tree. A cancelled scan reports nothing more.
    @concurrent
    func scan(root: String, progress: @Sendable (ScanProgress) -> Void) async throws -> FileTree {
        // Before the root is touched: a scan cancelled from the start asks the reader for nothing.
        try Task.checkCancellation()
        var assembly = ScanAssembly(
            rootPath: root,
            classifier: classifier,
            parallelism: parallelism,
            progressInterval: progressInterval
        )
        return try await withThrowingTaskGroup(of: DirectoryRead.self) { group in
            while let read = try await nextFinishedRead(for: &assembly, in: &group) {
                if let report = try assembly.accept(read) { progress(report) }
            }
            progress(assembly.progress)
            return assembly.finish()
        }
    }

    private typealias Workers = ThrowingTaskGroup<DirectoryRead, any Error>

    /// Keeps the workers busy and waits for one of them; nil when nothing is left to read.
    ///
    /// Cancellation is looked for on both sides of the wait: before, so that no read is started
    /// for a scan that is already over, and after, so that what a worker brings back is neither
    /// taken in nor reported.
    private func nextFinishedRead(
        for assembly: inout ScanAssembly,
        in workers: inout Workers
    ) async throws -> DirectoryRead? {
        try Task.checkCancellation()
        startReads(for: &assembly, in: &workers)
        let read = try await workers.next()
        try Task.checkCancellation()
        return read
    }

    private func startReads(for assembly: inout ScanAssembly, in workers: inout Workers) {
        while let directory = assembly.nextRead() {
            workers.addTask { [reader] in
                DirectoryRead(
                    directory: directory,
                    listing: Result { try reader.listing(ofDirectoryAt: directory.path) }
                )
            }
        }
    }
}

/// A directory the scan has decided to read, and the tree node waiting for its contents.
nonisolated struct PendingDirectory: Sendable {
    let path: String
    let node: FileTree.NodeID

    func path(ofChild name: String) -> String {
        path.hasSuffix("/") ? path + name : path + "/" + name
    }
}

/// What a worker brings back: the listing of one directory, or why it could not be read.
nonisolated struct DirectoryRead: Sendable {
    let directory: PendingDirectory
    let listing: Result<DirectoryListing, any Error>
}

/// What one listing contributes to the tree.
nonisolated struct ListingPlan: Sendable {
    nonisolated struct Descent: Sendable {
        /// Position of the directory among `children`.
        let childIndex: Int
        let path: String
    }

    var children: [FileTree.Builder.Child] = []
    var loose = LooseFiles.none
    /// Positions among `children` of the directories that will not be read.
    var leaves: [Int] = []
    /// Child directories to read.
    var descents: [Descent] = []
    /// Roots of admitted volumes, to read once nothing outside admitted volumes is left.
    var volumes: [Descent] = []
    /// Files counted in this listing, loose ones included, and their bytes on disk.
    var filesCounted = 0
    var bytesCounted: Int64 = 0
}

/// What the scan has already accounted for, so that nothing is counted twice.
nonisolated struct ScanLedger: Sendable {
    private var directories: Set<FileIdentity> = []
    private var hardLinks: Set<FileIdentity> = []

    /// False when the directory was read before under another path. Asked with the identity the
    /// directory's own listing reports: what a parent lists for a firmlink or a mount point is a
    /// placeholder, so an alias can only be recognised once it has been opened.
    mutating func claimDirectory(_ identity: FileIdentity) -> Bool {
        directories.insert(identity).inserted
    }

    /// False when another name of the same file was counted before.
    mutating func claimHardLink(_ identity: FileIdentity) -> Bool {
        hardLinks.insert(identity).inserted
    }
}

/// Turns one directory listing into its contribution to the tree. Pure apart from the ledger of
/// hard links it is handed.
nonisolated struct ListingClassifier: Sendable {
    /// What becomes of one child directory.
    private nonisolated enum Disposition {
        /// A node that is not read, flagged with the reason.
        case leaf(FileTree.Flags)
        /// A node on the same volume as its parent, to read.
        case descend
        /// The root of an admitted volume: a node to read after everything outside such volumes.
        case volume
    }

    let policy: VolumePolicy
    let looseCutoff: Int64

    func plan(
        for listing: DirectoryListing,
        in directory: PendingDirectory,
        ledger: inout ScanLedger
    ) -> ListingPlan {
        var plan = ListingPlan()
        for entry in listing.entries {
            switch entry.kind {
            case .directory:
                addDirectory(entry, at: directory.path(ofChild: entry.name), on: listing.identity.device, to: &plan)
            case .file, .other: addFile(entry, to: &plan, ledger: &ledger)
            }
        }
        return plan
    }

    private func addFile(_ entry: DirectoryEntry, to plan: inout ListingPlan, ledger: inout ScanLedger) {
        let isHardLink = entry.kind == .file && entry.linkCount > 1
        guard !isHardLink || ledger.claimHardLink(entry.identity) else { return }
        plan.filesCounted += 1
        plan.bytesCounted += entry.allocatedSize
        if entry.allocatedSize >= looseCutoff {
            plan.children.append(.file(entry.name, size: entry.allocatedSize))
        } else {
            plan.loose.count += 1
            plan.loose.bytes += entry.allocatedSize
        }
    }

    /// `device` is the one the listed directory itself is on.
    private func addDirectory(_ entry: DirectoryEntry, at path: String, on device: Int32, to plan: inout ListingPlan) {
        let childIndex = plan.children.count
        switch disposition(of: entry, at: path, from: device) {
        case let .leaf(flags):
            plan.leaves.append(childIndex)
            plan.children.append(.directory(entry.name, flags: flags))
            return
        case .descend:
            plan.descents.append(.init(childIndex: childIndex, path: path))
        case .volume:
            plan.volumes.append(.init(childIndex: childIndex, path: path))
        }
        plan.children.append(.directory(entry.name))
    }

    /// A dataless directory is never opened, whatever else is true of it.
    private func disposition(of entry: DirectoryEntry, at path: String, from device: Int32) -> Disposition {
        if entry.isDataless { return .leaf(.dataless) }
        guard isBoundary(entry, at: path, from: device) else { return .descend }
        return policy.admits(mountPointAt: path) ? .volume : .leaf(.otherVolume)
    }

    /// A child on any other device than the directory listing it belongs to another volume.
    private func isBoundary(_ entry: DirectoryEntry, at path: String, from device: Int32) -> Bool {
        entry.isMountPoint || entry.identity.device != device || policy.isMountPoint(path)
    }
}

/// The single owner of everything a scan accumulates: the tree under construction, what has
/// been counted already and the directories still to read.
nonisolated struct ScanAssembly: Sendable {
    private let classifier: ListingClassifier
    private let parallelism: Int
    private let progressInterval: Int
    private var builder: FileTree.Builder
    private var ledger = ScanLedger()
    /// A stack: reading depth-first keeps the backlog of pending directories small.
    private var ready: [PendingDirectory]
    /// Roots of admitted volumes. They wait until `ready` has run dry and no read is in flight, so
    /// that a directory reachable both from outside a volume and through it has been read, and
    /// claimed, outside before the volume offers it again.
    private var waitingVolumes: [PendingDirectory] = []
    private var readsInFlight = 0
    private var directoriesRead = 0
    /// Totals so far, and the directory taken in most recently.
    private(set) var progress: ScanProgress

    init(rootPath: String, classifier: ListingClassifier, parallelism: Int, progressInterval: Int) {
        self.classifier = classifier
        self.parallelism = parallelism
        self.progressInterval = progressInterval
        builder = FileTree.Builder(rootPath: rootPath)
        ready = [PendingDirectory(path: rootPath, node: builder.root)]
        progress = ScanProgress(filesSeen: 0, bytesSeen: 0, currentPath: rootPath)
    }

    /// The next directory a worker should read, or nil when the limit of simultaneous reads is
    /// reached or nothing can be started right now.
    mutating func nextRead() -> PendingDirectory? {
        guard readsInFlight < parallelism else { return nil }
        if ready.isEmpty && readsInFlight == 0 { swap(&ready, &waitingVolumes) }
        guard let next = ready.popLast() else { return nil }
        readsInFlight += 1
        return next
    }

    /// Takes in what a worker read and returns a progress report when one is due.
    /// Throws only when the scan root itself could not be read.
    mutating func accept(_ read: DirectoryRead) throws -> ScanProgress? {
        readsInFlight -= 1
        switch read.listing {
        case let .success(listing):
            take(listing, of: read.directory)
        case let .failure(error):
            guard read.directory.node != builder.root else { throw error }
            builder.addFlags(.unreadable, to: read.directory.node)
            builder.addChildren([], to: read.directory.node)
        }
        directoriesRead += 1
        progress.currentPath = read.directory.path
        return directoriesRead.isMultiple(of: progressInterval) ? progress : nil
    }

    consuming func finish() -> FileTree {
        builder.build()
    }

    /// A directory that was already read under another path contributes nothing and leaves the tree.
    private mutating func take(_ listing: DirectoryListing, of directory: PendingDirectory) {
        guard ledger.claimDirectory(listing.identity) else {
            builder.omit(directory.node)
            return
        }
        fill(directory, with: classifier.plan(for: listing, in: directory, ledger: &ledger))
    }

    private mutating func fill(_ directory: PendingDirectory, with plan: ListingPlan) {
        let nodes = builder.addChildren(plan.children, loose: plan.loose, to: directory.node)
        func pending(_ descent: ListingPlan.Descent) -> PendingDirectory {
            PendingDirectory(path: descent.path, node: nodes[descent.childIndex])
        }
        ready.append(contentsOf: plan.descents.map(pending))
        waitingVolumes.append(contentsOf: plan.volumes.map(pending))
        // The builder wants every directory filled, the ones that are never read included.
        for leaf in plan.leaves {
            builder.addChildren([], to: nodes[leaf])
        }
        progress.filesSeen += plan.filesCounted
        progress.bytesSeen += plan.bytesCounted
    }
}
