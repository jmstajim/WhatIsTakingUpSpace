import Foundation

/// Files below the scanner's size cutoff, folded into a count and a byte sum on their directory.
nonisolated struct LooseFiles: Equatable, Sendable {
    var count: Int
    var bytes: Int64

    static let none = LooseFiles(count: 0, bytes: 0)

    /// Files smaller than this many bytes are folded: 1 MB, in the decimal units Finder shows.
    static let cutoff: Int64 = 1_000_000
}

/// The result of a scan: every directory and every file at or above the size cutoff.
///
/// Nodes live in one flat array. The children of a directory are contiguous and always sit
/// after their parent, so directory sizes are rolled up in a single backward pass.
/// `Builder` is the only way to make a tree and is what keeps those invariants.
nonisolated struct FileTree: Sendable {
    nonisolated struct NodeID: Hashable, Sendable {
        fileprivate let index: Int32
    }

    nonisolated enum Kind: UInt8, Sendable {
        case directory
        case file
    }

    nonisolated struct Flags: OptionSet, Hashable, Sendable {
        let rawValue: UInt8

        /// The directory could not be read; its contents are missing from the tree.
        static let unreadable = Flags(rawValue: 1 << 0)
        /// The directory lives in the cloud and takes no local space; it was not opened.
        static let dataless = Flags(rawValue: 1 << 1)
        /// A mount point of a volume the scan does not cover.
        static let otherVolume = Flags(rawValue: 1 << 2)
    }

    /// A contiguous run of nodes, e.g. the children of one directory.
    nonisolated struct NodeRange: RandomAccessCollection, Sendable {
        fileprivate let first: Int32
        let count: Int

        var startIndex: Int { 0 }
        var endIndex: Int { count }

        subscript(position: Int) -> NodeID {
            precondition(position >= 0 && position < count, "NodeRange index out of bounds")
            return NodeID(index: first + Int32(position))
        }
    }

    nonisolated struct Contents: Sendable {
        /// Largest first; equal sizes are ordered by name.
        var children: [NodeID]
        var loose: LooseFiles
    }

    fileprivate struct Node: Sendable {
        var nameOffset: UInt32
        var nameLength: UInt16
        var kind: Kind
        var flags: Flags
        var parent: Int32
        /// Means something only while `childCount` is above zero. In a builder, negative until the
        /// directory is filled.
        var firstChild: Int32
        var childCount: Int32
        var looseCount: UInt32
        var size: Int64
        var looseBytes: Int64
    }

    private let nodes: [Node]
    private let names: [UInt8]

    fileprivate init(nodes: [Node], names: [UInt8]) {
        self.nodes = nodes
        self.names = names
    }

    var root: NodeID { NodeID(index: 0) }
    var nodeCount: Int { nodes.count }

    /// The scan root's name is its full path; every other node is named by its last path component.
    func name(of id: NodeID) -> String {
        String(decoding: nameBytes(of: id), as: UTF8.self)
    }

    /// Bytes on disk. For a directory: everything below it, loose files included.
    func size(of id: NodeID) -> Int64 { node(id).size }
    func kind(of id: NodeID) -> Kind { node(id).kind }
    func flags(of id: NodeID) -> Flags { node(id).flags }

    func loose(of id: NodeID) -> LooseFiles {
        LooseFiles(count: Int(node(id).looseCount), bytes: node(id).looseBytes)
    }

    func parent(of id: NodeID) -> NodeID? {
        let parent = node(id).parent
        return parent < 0 ? nil : NodeID(index: parent)
    }

    /// Children in scan order. Use `contents(of:)` for display order.
    func children(of id: NodeID) -> NodeRange {
        NodeRange(first: node(id).firstChild, count: Int(node(id).childCount))
    }

    func contents(of id: NodeID) -> Contents {
        let sorted = children(of: id).sorted { lhs, rhs in
            let (lhsSize, rhsSize) = (size(of: lhs), size(of: rhs))
            return lhsSize != rhsSize ? lhsSize > rhsSize : name(of: lhs) < name(of: rhs)
        }
        return Contents(children: sorted, loose: loose(of: id))
    }

    /// The chain of nodes from the root down to `id`, both included.
    func lineage(of id: NodeID) -> [NodeID] {
        var chain = [id]
        var current = id
        while let parent = parent(of: current) {
            chain.append(parent)
            current = parent
        }
        return chain.reversed()
    }

    func path(of id: NodeID) -> String {
        let rootPath = name(of: root)
        let components = lineage(of: id).dropFirst().map(name(of:))
        if components.isEmpty { return rootPath }
        let prefix = rootPath.hasSuffix("/") ? String(rootPath.dropLast()) : rootPath
        return prefix + "/" + components.joined(separator: "/")
    }

    /// Finds a node by the names leading to it from the root. An empty list is the root itself.
    func node(at components: [String]) -> NodeID? {
        var current = root
        for component in components {
            guard let next = children(of: current).first(where: { nameBytes(of: $0).elementsEqual(component.utf8) })
            else { return nil }
            current = next
        }
        return current
    }

    func nodes(flagged flags: Flags) -> [NodeID] {
        nodes.indices
            .filter { nodes[$0].flags.contains(flags) }
            .map { NodeID(index: Int32($0)) }
    }

    private func node(_ id: NodeID) -> Node { nodes[Int(id.index)] }

    private func nameBytes(of id: NodeID) -> ArraySlice<UInt8> {
        let node = node(id)
        let start = Int(node.nameOffset)
        return names[start..<start + Int(node.nameLength)]
    }
}

extension FileTree {
    /// Assembles a tree. Directories may be filled in any order, each exactly once.
    nonisolated struct Builder: Sendable {
        nonisolated struct Child: Sendable {
            fileprivate let name: String
            fileprivate let kind: Kind
            fileprivate let size: Int64
            fileprivate let flags: Flags

            static func directory(_ name: String, flags: Flags = []) -> Child {
                Child(name: name, kind: .directory, size: 0, flags: flags)
            }

            static func file(_ name: String, size: Int64) -> Child {
                Child(name: name, kind: .file, size: size, flags: [])
            }
        }

        private var nodes: [Node] = []
        private var names: [UInt8] = []
        private var omitted: Set<Int32> = []

        init(rootPath: String) {
            append(.directory(rootPath), parent: -1)
        }

        var root: NodeID { NodeID(index: 0) }

        /// Sets the contents of `parent`, which must be a directory that has not been filled yet.
        @discardableResult
        mutating func addChildren(_ children: [Child], loose: LooseFiles = .none, to parent: NodeID) -> NodeRange {
            let parentIndex = Int(parent.index)
            precondition(nodes[parentIndex].kind == .directory, "Only a directory can have children")
            precondition(nodes[parentIndex].firstChild < 0, "A directory is filled exactly once")

            let first = Int32(nodes.count)
            nodes[parentIndex].firstChild = first
            nodes[parentIndex].childCount = Int32(children.count)
            nodes[parentIndex].looseCount = UInt32(clamping: loose.count)
            nodes[parentIndex].looseBytes = loose.bytes
            for child in children {
                append(child, parent: parent.index)
            }
            return NodeRange(first: first, count: children.count)
        }

        mutating func addFlags(_ flags: Flags, to id: NodeID) {
            nodes[Int(id.index)].flags.formUnion(flags)
        }

        /// Leaves a directory out of the finished tree: one that, once opened, turned out to be
        /// a directory already scanned under another path. It must not have been filled.
        ///
        /// IDs handed out by the builder stay valid in the built tree only if nothing was omitted.
        mutating func omit(_ id: NodeID) {
            let index = Int(id.index)
            precondition(index > 0, "The scan root cannot be omitted")
            precondition(nodes[index].firstChild < 0, "A filled directory cannot be omitted")
            omitted.insert(id.index)
        }

        consuming func build() -> FileTree {
            dropOmitted()
            for index in nodes.indices {
                nodes[index].size += nodes[index].looseBytes
            }
            for index in nodes.indices.dropFirst().reversed() {
                nodes[Int(nodes[index].parent)].size += nodes[index].size
            }
            return FileTree(nodes: nodes, names: names)
        }

        /// Closes the gaps left by omitted nodes. Siblings stay contiguous and in order, so each
        /// directory's child range is rebuilt from its surviving children's parent links.
        private mutating func dropOmitted() {
            guard !omitted.isEmpty else { return }
            var newIndex = [Int32](repeating: -1, count: nodes.count)
            var kept: [Node] = []
            for index in nodes.indices where !omitted.contains(Int32(index)) {
                newIndex[index] = Int32(kept.count)
                var node = nodes[index]
                // The old `firstChild` is left to be overwritten by the first child that stays;
                // with no children left it is never read.
                node.childCount = 0
                if node.parent >= 0 {
                    node.parent = newIndex[Int(node.parent)]
                    if kept[Int(node.parent)].childCount == 0 {
                        kept[Int(node.parent)].firstChild = Int32(kept.count)
                    }
                    kept[Int(node.parent)].childCount += 1
                }
                kept.append(node)
            }
            nodes = kept
            omitted = []
        }

        private mutating func append(_ child: Child, parent: Int32) {
            let utf8 = Array(child.name.utf8)
            nodes.append(Node(
                nameOffset: UInt32(names.count),
                nameLength: UInt16(clamping: utf8.count),
                kind: child.kind,
                flags: child.flags,
                parent: parent,
                firstChild: -1,
                childCount: 0,
                looseCount: 0,
                size: child.size,
                looseBytes: 0
            ))
            names.append(contentsOf: utf8.prefix(Int(UInt16.max)))
        }
    }
}
