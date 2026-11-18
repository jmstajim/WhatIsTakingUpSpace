/// The sizes the Largest view can use as "large".
nonisolated enum CulpritThreshold {
    static let choices: [Int64] = [100_000_000, 500_000_000, 1_000_000_000, 5_000_000_000, 10_000_000_000]
    static let standard: Int64 = 1_000_000_000
}

/// Which culprits the Largest view shows. The raw values are what is remembered between launches.
nonisolated enum CulpritFilter: String, CaseIterable, Sendable {
    case all
    case folders
    /// Files, and packages: Finder shows a package as a file.
    case files

    func admits(_ kind: Culprit.Kind) -> Bool {
        switch self {
        case .all: true
        case .folders: kind == .folder
        case .files: kind != .folder
        }
    }
}

/// One line of the Largest view.
nonisolated struct CulpritRow: Identifiable, Equatable, Sendable {
    let id: FileTree.NodeID
    /// The item's name; for the scan root, its full path.
    let name: String
    /// Path of the folder the item lives in. Empty for the scan root.
    let location: String
    let kind: Culprit.Kind
    let ownSize: Int64
    let totalSize: Int64
    /// `ownSize` as a share of everything scanned, 0...1.
    let fraction: Double
}

/// The Largest view's rows and how much of the scan they account for.
nonisolated struct CulpritList: Equatable, Sendable {
    var rows: [CulpritRow]
    /// Sum of the rows' own sizes.
    var listedBytes: Int64
    var scannedBytes: Int64
}

nonisolated extension FileTree {
    func culpritList(threshold: Int64, filter: CulpritFilter, isPackage: (String) -> Bool) -> CulpritList {
        let scanned = size(of: root)
        let rows = culprits(threshold: threshold, isPackage: isPackage)
            .filter { filter.admits($0.kind) }
            .map { culprit in
                CulpritRow(
                    id: culprit.node,
                    name: name(of: culprit.node),
                    location: parent(of: culprit.node).map(path(of:)) ?? "",
                    kind: culprit.kind,
                    ownSize: culprit.ownSize,
                    totalSize: culprit.totalSize,
                    // A culprit takes at least a byte, so where there is one, `scanned` is not zero.
                    fraction: Double(culprit.ownSize) / Double(scanned)
                )
            }
        return CulpritList(rows: rows, listedBytes: rows.map(\.ownSize).reduce(0, +), scannedBytes: scanned)
    }
}
