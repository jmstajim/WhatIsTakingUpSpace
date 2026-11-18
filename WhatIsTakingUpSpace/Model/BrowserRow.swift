import Foundation

/// One line of the Browse view: a child of the folder being shown, or its loose files as a whole.
nonisolated struct BrowserRow: Identifiable, Equatable, Sendable {
    nonisolated enum ID: Hashable, Sendable {
        case node(FileTree.NodeID)
        case looseFiles

        var node: FileTree.NodeID? {
            if case let .node(node) = self { node } else { nil }
        }
    }

    nonisolated enum Kind: Equatable, Sendable {
        case folder
        /// A directory Finder shows as a single file. Browse still lets you step into it.
        case package
        case file
        case looseFiles(count: Int)

        /// The kind of the one item the row stands for; `nil` for the loose files, which are many.
        var item: Culprit.Kind? {
            switch self {
            case .folder: .folder
            case .package: .package
            case .file: .file
            case .looseFiles: nil
            }
        }
    }

    let id: ID
    /// Empty for the loose-files row; the view words that one itself.
    let name: String
    let kind: Kind
    let size: Int64
    /// Share of the shown folder's size, 0...1.
    let fraction: Double
    let flags: FileTree.Flags

    var node: FileTree.NodeID? { id.node }

    var canEnter: Bool { kind == .folder || kind == .package }
}

nonisolated extension [BrowserRow] {
    /// The rows in the order a click on a column heading asks for. The loose-files row is not one
    /// item among the others, so it stays at the end whatever the order.
    func arranged(by order: [KeyPathComparator<BrowserRow>]) -> [BrowserRow] {
        filter { $0.node != nil }.sorted(using: order) + filter { $0.node == nil }
    }
}

/// Where the Browse view should go to show a given item.
nonisolated struct BrowseTarget: Equatable, Sendable {
    /// Names leading from the scan root to the folder to show.
    var location: [String]
    /// The row to select there, if the item is not the folder itself.
    var selection: BrowserRow.ID?
}

nonisolated extension FileTree {
    /// A folder is shown by opening it. A file or a package is shown selected in the folder that
    /// holds it, the way Finder reveals one. The scan root is always opened.
    func browseTarget(for node: NodeID, isPackage: (String) -> Bool) -> BrowseTarget {
        guard let parent = parent(of: node), rowKind(of: node, named: name(of: node), isPackage: isPackage) != .folder
        else { return BrowseTarget(location: relativeComponents(of: node), selection: nil) }
        return BrowseTarget(location: relativeComponents(of: parent), selection: .node(node))
    }

    /// The rows of `folder`: its children largest first, then one row for its loose files, if any.
    func browserRows(of folder: NodeID, isPackage: (String) -> Bool) -> [BrowserRow] {
        let contents = contents(of: folder)
        let total = size(of: folder)
        var rows = contents.children.map { child in
            let name = name(of: child)
            return BrowserRow(
                id: .node(child),
                name: name,
                kind: rowKind(of: child, named: name, isPackage: isPackage),
                size: size(of: child),
                fraction: Self.fraction(of: size(of: child), in: total),
                flags: flags(of: child)
            )
        }
        if contents.loose.count > 0 {
            rows.append(BrowserRow(
                id: .looseFiles,
                name: "",
                kind: .looseFiles(count: contents.loose.count),
                size: contents.loose.bytes,
                fraction: Self.fraction(of: contents.loose.bytes, in: total),
                flags: []
            ))
        }
        return rows
    }

    /// The names leading from the root to `node`; the inverse of `node(at:)`.
    func relativeComponents(of node: NodeID) -> [String] {
        lineage(of: node).dropFirst().map(name(of:))
    }

    /// The deepest directory along `components` that exists: where to land when the exact place is gone.
    func nearestDirectory(at components: [String]) -> NodeID {
        var prefix = components
        while !prefix.isEmpty {
            if let node = node(at: prefix), kind(of: node) == .directory { return node }
            prefix.removeLast()
        }
        return root
    }

    private func rowKind(of node: NodeID, named name: String, isPackage: (String) -> Bool) -> BrowserRow.Kind {
        guard kind(of: node) == .directory else { return .file }
        return isPackage(name) ? .package : .folder
    }

    private static func fraction(of part: Int64, in total: Int64) -> Double {
        total > 0 ? Double(part) / Double(total) : 0
    }
}
