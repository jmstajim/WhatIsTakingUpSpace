import Foundation

/// One row of the "Largest" list: a place where disk space really is.
nonisolated struct Culprit: Equatable, Sendable {
    nonisolated enum Kind: Equatable, Sendable {
        case folder
        case file
        /// A directory Finder shows as a single file; never looked into.
        case package

        /// What to call it in a sentence.
        var word: String {
            switch self {
            case .folder: "folder"
            case .file: "file"
            case .package: "package"
            }
        }
    }

    let node: FileTree.NodeID
    let kind: Kind
    /// Bytes this row answers for by itself. A folder's own size leaves out its direct children
    /// that reach the threshold; a file or a package is taken whole.
    let ownSize: Int64
    /// Everything at and below the node.
    let totalSize: Int64
}

nonisolated extension FileTree {
    /// The flat, non-overlapping list of where the space is, largest own size first.
    /// `isPackage` is given a directory's name; it is never asked about the scan root.
    ///
    /// A threshold below one byte counts as one byte: something that takes no space is never a culprit.
    func culprits(threshold: Int64, isPackage: (String) -> Bool) -> [Culprit] {
        var found: [Culprit] = []
        _ = claim(root, threshold: max(threshold, 1), isPackage: isPackage, into: &found)
        return found.sorted(by: outranks)
    }

    /// Records the culprits at and below `node`. Returns the bytes `node` takes out of its parent's
    /// own size: all of them when it reaches the threshold, none otherwise.
    ///
    /// Nothing smaller than the threshold is entered, which is what keeps this fast on a tree of
    /// millions of nodes.
    private func claim(
        _ node: NodeID,
        threshold: Int64,
        isPackage: (String) -> Bool,
        into found: inout [Culprit]
    ) -> Int64 {
        let size = size(of: node)
        guard size >= threshold else { return 0 }
        if let kind = indivisibleKind(of: node, isPackage: isPackage) {
            found.append(Culprit(node: node, kind: kind, ownSize: size, totalSize: size))
            return size
        }
        var ownSize = size
        for child in children(of: node) {
            ownSize -= claim(child, threshold: threshold, isPackage: isPackage, into: &found)
        }
        if ownSize >= threshold {
            found.append(Culprit(node: node, kind: .folder, ownSize: ownSize, totalSize: size))
        }
        return size
    }

    /// What `node` is when it is taken whole; nil for a folder, which is split among its children.
    ///
    /// The scan root is always split: someone who points the scan at a package wants to see inside it.
    func indivisibleKind(of node: NodeID, isPackage: (String) -> Bool) -> Culprit.Kind? {
        if kind(of: node) == .file { return .file }
        guard node != root else { return nil }
        return isPackage(name(of: node)) ? .package : nil
    }

    private func outranks(_ lhs: Culprit, _ rhs: Culprit) -> Bool {
        lhs.ownSize != rhs.ownSize ? lhs.ownSize > rhs.ownSize : path(of: lhs.node) < path(of: rhs.node)
    }
}
