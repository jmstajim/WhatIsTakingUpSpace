nonisolated extension FileTree {
    /// A copy of the tree in which the directory `target` has the contents, loose files and flags
    /// of `replacement`'s root, as after rescanning that one folder. `target` keeps its name.
    func replacingSubtree(at target: NodeID, with replacement: FileTree) -> FileTree {
        precondition(kind(of: target) == .directory, "Only a directory can be rescanned")
        let top = Origin(tree: self, node: root, substitution: Substitution(target: target, replacement: replacement))
            .substituted()
        var builder = Builder(rootPath: name(of: root))
        builder.addFlags(top.tree.flags(of: top.node), to: builder.root)
        top.copyContents(to: builder.root, in: &builder)
        return builder.build()
    }
}

private nonisolated struct Substitution {
    let target: FileTree.NodeID
    let replacement: FileTree
}

/// Where a node of the result is copied from: the original tree or, at and below the target, the replacement.
private nonisolated struct Origin {
    let tree: FileTree
    let node: FileTree.NodeID
    /// Still pending while walking the original tree; `nil` once inside the replacement.
    let substitution: Substitution?

    /// The replacement's root when this is the target, otherwise itself.
    func substituted() -> Origin {
        guard let substitution, substitution.target == node else { return self }
        return Origin(tree: substitution.replacement, node: substitution.replacement.root, substitution: nil)
    }

    func copyContents(to destination: FileTree.NodeID, in builder: inout FileTree.Builder) {
        let children = tree.children(of: node).map { child in
            // The name is read before substituting: the replacement's root is named by a full path.
            (name: tree.name(of: child), origin: Origin(tree: tree, node: child, substitution: substitution).substituted())
        }
        let created = builder.addChildren(
            children.map { $0.origin.asChild(named: $0.name) },
            loose: tree.loose(of: node),
            to: destination
        )
        for (id, child) in zip(created, children) where child.origin.isDirectory {
            child.origin.copyContents(to: id, in: &builder)
        }
    }

    private var isDirectory: Bool { tree.kind(of: node) == .directory }

    private func asChild(named name: String) -> FileTree.Builder.Child {
        isDirectory
            ? .directory(name, flags: tree.flags(of: node))
            : .file(name, size: tree.size(of: node))
    }
}
