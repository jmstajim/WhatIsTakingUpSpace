#if DEBUG
/// A literal description of a tree, for tests and previews.
nonisolated enum TreeSpec: Sendable {
    case dir(String, [TreeSpec], loose: LooseFiles = .none, flags: FileTree.Flags = [])
    case file(String, Int64)
}

extension FileTree {
    /// Builds a tree from a literal. The top-level spec must be a `.dir` named by the scan root's path.
    nonisolated init(_ spec: TreeSpec) {
        guard case let .dir(rootPath, children, loose, flags) = spec else {
            preconditionFailure("The scan root must be a directory")
        }
        var builder = Builder(rootPath: rootPath)
        builder.addFlags(flags, to: builder.root)
        builder.fill(builder.root, with: children, loose: loose)
        self = builder.build()
    }
}

private extension FileTree.Builder {
    nonisolated mutating func fill(_ parent: FileTree.NodeID, with specs: [TreeSpec], loose: LooseFiles) {
        let ids = addChildren(specs.map(\.child), loose: loose, to: parent)
        for (id, spec) in zip(ids, specs) {
            if case let .dir(_, children, loose, _) = spec {
                fill(id, with: children, loose: loose)
            }
        }
    }
}

private extension TreeSpec {
    nonisolated var child: FileTree.Builder.Child {
        switch self {
        case let .dir(name, _, _, flags): .directory(name, flags: flags)
        case let .file(name, size): .file(name, size: size)
        }
    }
}
#endif

#if DEBUG
extension FileTree {
    /// A small disk for previews.
    nonisolated static let preview = FileTree(.dir("/", [
        .dir("Users", [
            .dir("ada", [
                .dir("Library", [
                    .dir("Developer", [
                        .dir("Xcode", [.dir("DerivedData", [], loose: LooseFiles(count: 48_210, bytes: 96_000_000_000))]),
                    ], loose: LooseFiles(count: 320, bytes: 600_000_000)),
                    .dir("Mail", [], flags: .unreadable),
                ], loose: LooseFiles(count: 1_204, bytes: 400_000_000)),
                .dir("Downloads", [
                    .file("macOS Installer.dmg", 14_000_000_000),
                    .file("archive.zip", 2_300_000_000),
                ], loose: LooseFiles(count: 412, bytes: 180_000_000)),
                .dir("Pictures", [.dir("Photos Library.photoslibrary", [.file("originals", 80_000_000_000)])]),
                .dir("iCloud Drive", [], flags: .dataless),
            ]),
        ]),
        .dir("Applications", [.dir("Xcode.app", [.file("Xcode", 12_000_000_000)])]),
        .dir("Volumes", [.dir("Backup", [], flags: .otherVolume)]),
    ], loose: LooseFiles(count: 3, bytes: 12_000)))
}
#endif
