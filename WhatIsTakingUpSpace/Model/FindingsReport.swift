/// What a scan found, cut down to what someone else needs in order to say what it is and whether
/// it can go: the disk's numbers, the "Largest" list with full paths, and for each folder in it
/// the biggest things its own size is made of.
nonisolated struct FindingsReport: Equatable, Sendable {
    /// Something directly inside a listed folder that counts towards the folder's own size.
    nonisolated struct Item: Equatable, Sendable {
        var name: String
        var kind: Culprit.Kind
        var size: Int64
    }

    /// What was left out to keep the report short.
    nonisolated struct Remainder: Equatable, Sendable {
        var count: Int
        var bytes: Int64

        static let none = Remainder(count: 0, bytes: 0)
    }

    /// One row of the "Largest" list.
    nonisolated struct Entry: Equatable, Sendable {
        var path: String
        var kind: Culprit.Kind
        var ownSize: Int64
        var totalSize: Int64
        /// Largest first. Empty for a file or a package: those are taken whole.
        var items: [Item] = []
        var otherItems: Remainder = .none
        var looseFiles: LooseFiles = .none
    }

    /// How much of each list goes into the report. None of them may be negative.
    nonisolated struct Limits: Equatable, Sendable {
        var entries: Int
        var itemsPerEntry: Int
        var unreadable: Int

        /// Small enough to paste into a chat, large enough to cover a disk's real offenders.
        static let standard = Limits(entries: 100, itemsPerEntry: 10, unreadable: 50)
    }

    var rootPath: String
    var summary: DiskSummary
    var threshold: Int64
    /// Largest own size first.
    var entries: [Entry]
    /// Entries beyond the limit; its bytes are their own sizes added up.
    var otherEntries: Remainder
    /// Paths of folders the scan could not read, in alphabetical order.
    var unreadable: [String]
    var otherUnreadable: Int
}

nonisolated extension FileTree {
    /// The report for this tree at `threshold`, which means here what it means to `culprits`.
    func findingsReport(
        summary: DiskSummary,
        unreadable: [NodeID],
        threshold: Int64,
        limits: FindingsReport.Limits = .standard,
        isPackage: (String) -> Bool
    ) -> FindingsReport {
        let culprits = culprits(threshold: threshold, isPackage: isPackage)
        let paths = unreadable.map(path(of:)).sorted()
        return FindingsReport(
            rootPath: path(of: root),
            summary: summary,
            threshold: threshold,
            entries: culprits.prefix(limits.entries).map { culprit in
                entry(for: culprit, threshold: threshold, itemLimit: limits.itemsPerEntry, isPackage: isPackage)
            },
            otherEntries: FindingsReport.Remainder(
                count: culprits.dropFirst(limits.entries).count,
                bytes: culprits.dropFirst(limits.entries).reduce(0) { $0 + $1.ownSize }
            ),
            unreadable: Array(paths.prefix(limits.unreadable)),
            otherUnreadable: paths.dropFirst(limits.unreadable).count
        )
    }

    private func entry(
        for culprit: Culprit,
        threshold: Int64,
        itemLimit: Int,
        isPackage: (String) -> Bool
    ) -> FindingsReport.Entry {
        var entry = FindingsReport.Entry(
            path: path(of: culprit.node),
            kind: culprit.kind,
            ownSize: culprit.ownSize,
            totalSize: culprit.totalSize
        )
        guard culprit.kind == .folder else { return entry }

        let contents = contents(of: culprit.node)
        // A child that reaches the threshold is not part of the folder's own size, and one that
        // takes no space explains nothing.
        let own = contents.children.filter { size(of: $0) > 0 && size(of: $0) < threshold }
        entry.items = own.prefix(itemLimit).map { child in
            FindingsReport.Item(
                name: name(of: child),
                kind: indivisibleKind(of: child, isPackage: isPackage) ?? .folder,
                size: size(of: child)
            )
        }
        entry.otherItems = FindingsReport.Remainder(
            count: own.dropFirst(itemLimit).count,
            bytes: own.dropFirst(itemLimit).reduce(0) { $0 + size(of: $1) }
        )
        entry.looseFiles = contents.loose
        return entry
    }
}
