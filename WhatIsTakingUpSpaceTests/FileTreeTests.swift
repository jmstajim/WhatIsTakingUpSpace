import Testing
@testable import WhatIsTakingUpSpace

struct FileTreeTests {
    private let tree = FileTree(.dir("/", [
        .dir("Users", [
            .dir("ada", [
                .file("movie.mov", 5_000_000),
                .file("disk.dmg", 8_000_000),
                .dir("Empty", []),
            ], loose: LooseFiles(count: 3, bytes: 300)),
        ]),
        .file("swapfile", 2_000_000),
        .dir("private", [], flags: .unreadable),
    ], loose: LooseFiles(count: 1, bytes: 10)))

    @Test func directorySizeIsItsFilesLooseFilesAndSubdirectories() throws {
        let ada = try #require(tree.node(at: ["Users", "ada"]))
        let users = try #require(tree.node(at: ["Users"]))

        #expect(tree.size(of: ada) == 13_000_300)
        #expect(tree.size(of: users) == 13_000_300)
        #expect(tree.size(of: tree.root) == 15_000_310)
    }

    @Test func aFileHasNoLooseFiles() throws {
        let swapfile = try #require(tree.node(at: ["swapfile"]))

        #expect(tree.loose(of: swapfile) == .none)
    }

    @Test func emptyDirectoryHasZeroSize() throws {
        let empty = try #require(tree.node(at: ["Users", "ada", "Empty"]))

        #expect(tree.size(of: empty) == 0)
        #expect(tree.contents(of: empty).children.isEmpty)
    }

    @Test func pathJoinsNamesFromTheScanRoot() throws {
        let ada = try #require(tree.node(at: ["Users", "ada"]))

        #expect(tree.path(of: tree.root) == "/")
        #expect(tree.path(of: ada) == "/Users/ada")
    }

    @Test func pathUnderANonSlashRootKeepsTheRootPrefix() throws {
        let tree = FileTree(.dir("/Volumes/Box", [.dir("a", [.file("b.bin", 2_000_000)])]))
        let file = try #require(tree.node(at: ["a", "b.bin"]))

        #expect(tree.path(of: file) == "/Volumes/Box/a/b.bin")
        #expect(tree.name(of: tree.root) == "/Volumes/Box")
    }

    @Test func contentsListChildrenLargestFirstWithLooseFilesApart() throws {
        let ada = try #require(tree.node(at: ["Users", "ada"]))

        let contents = tree.contents(of: ada)

        #expect(contents.children.map(tree.name(of:)) == ["disk.dmg", "movie.mov", "Empty"])
        #expect(contents.loose == LooseFiles(count: 3, bytes: 300))
    }

    @Test func childrenOfEqualSizeAreOrderedByName() {
        let tree = FileTree(.dir("/", [.file("b", 2_000_000), .file("a", 2_000_000)]))

        #expect(tree.contents(of: tree.root).children.map(tree.name(of:)) == ["a", "b"])
    }

    @Test func lineageRunsFromRootDownToTheNode() throws {
        let ada = try #require(tree.node(at: ["Users", "ada"]))

        #expect(tree.lineage(of: ada).map(tree.name(of:)) == ["/", "Users", "ada"])
        #expect(tree.lineage(of: tree.root) == [tree.root])
    }

    @Test func parentOfRootIsNil() throws {
        let users = try #require(tree.node(at: ["Users"]))

        #expect(tree.parent(of: tree.root) == nil)
        #expect(tree.parent(of: users) == tree.root)
    }

    @Test func nodeLookupFailsForAMissingPath() {
        #expect(tree.node(at: ["Users", "nobody"]) == nil)
        #expect(tree.node(at: ["swapfile", "inside"]) == nil)
        #expect(tree.node(at: []) == tree.root)
    }

    @Test func kindAndFlagsAreKept() throws {
        let priv = try #require(tree.node(at: ["private"]))
        let swap = try #require(tree.node(at: ["swapfile"]))

        #expect(tree.kind(of: priv) == .directory)
        #expect(tree.kind(of: swap) == .file)
        #expect(tree.flags(of: priv) == .unreadable)
        #expect(tree.nodes(flagged: .unreadable) == [priv])
    }

    @Test func nonASCIINamesSurvive() throws {
        let tree = FileTree(.dir("/", [.dir("Фото и видео", [.file("отпуск 🌴.mov", 3_000_000)])]))
        let file = try #require(tree.node(at: ["Фото и видео", "отпуск 🌴.mov"]))

        #expect(tree.path(of: file) == "/Фото и видео/отпуск 🌴.mov")
    }

    @Test func builderAcceptsDirectoriesFilledInAnyOrder() {
        var builder = FileTree.Builder(rootPath: "/")
        let top = builder.addChildren([.directory("a"), .directory("b")], to: builder.root)
        // "b" is filled before "a", as happens when directories are read in parallel.
        builder.addChildren([.file("y", size: 7_000_000)], to: top[1])
        builder.addChildren([.file("x", size: 2_000_000)], loose: LooseFiles(count: 2, bytes: 5), to: top[0])
        let tree = builder.build()

        #expect(tree.size(of: tree.root) == 9_000_005)
        #expect(tree.contents(of: tree.root).children.map(tree.name(of:)) == ["b", "a"])
        #expect(tree.node(at: ["a", "x"]).map(tree.size(of:)) == 2_000_000)
        #expect(tree.nodeCount == 5)
    }

    @Test func omittedDirectoryIsAbsentAndItsSiblingsKeepTheirContents() {
        var builder = FileTree.Builder(rootPath: "/")
        let top = builder.addChildren(
            [.directory("first"), .directory("alias"), .directory("last"), .file("big.bin", size: 4_000_000)],
            loose: LooseFiles(count: 1, bytes: 1),
            to: builder.root
        )
        builder.addChildren([.file("a", size: 1_000_000)], to: top[0])
        let inLast = builder.addChildren([.directory("deep"), .file("c", size: 3_000_000)], to: top[2])
        builder.addChildren([.file("d", size: 2_000_000)], to: inLast[0])
        builder.omit(top[1])
        let tree = builder.build()

        #expect(tree.nodeCount == 8)
        #expect(tree.children(of: tree.root).map(tree.name(of:)) == ["first", "last", "big.bin"])
        #expect(tree.node(at: ["alias"]) == nil)
        #expect(tree.node(at: ["first", "a"]).map(tree.size(of:)) == 1_000_000)
        #expect(tree.node(at: ["last", "deep", "d"]).map(tree.path(of:)) == "/last/deep/d")
        #expect(tree.node(at: ["last"]).map(tree.size(of:)) == 5_000_000)
        #expect(tree.node(at: ["last"]).map { tree.children(of: $0).map(tree.name(of:)) } == ["deep", "c"])
        #expect(tree.size(of: tree.root) == 10_000_001)
        #expect(tree.node(at: ["last", "deep"]).flatMap(tree.parent(of:)) == tree.node(at: ["last"]))
    }

    @Test func omittingTheFirstTheLastAndAnOnlyChildLeavesConsistentRanges() {
        var builder = FileTree.Builder(rootPath: "/")
        let top = builder.addChildren([.directory("a"), .directory("b"), .directory("c")], to: builder.root)
        let inB = builder.addChildren([.directory("only")], to: top[1])
        builder.omit(top[0])
        builder.omit(top[2])
        builder.omit(inB[0])
        let tree = builder.build()

        #expect(tree.nodeCount == 2)
        #expect(tree.children(of: tree.root).map(tree.name(of:)) == ["b"])
        #expect(tree.node(at: ["b"]).map { tree.children(of: $0).isEmpty } == true)
        #expect(tree.node(at: ["b", "only"]) == nil)
    }

    @Test func flagsAddedWhileBuildingAreKeptAlongsideEarlierOnes() throws {
        var builder = FileTree.Builder(rootPath: "/")
        let top = builder.addChildren([.directory("cloud", flags: .dataless), .directory("plain")], to: builder.root)
        builder.addFlags(.unreadable, to: top[0])
        let tree = builder.build()

        #expect(tree.flags(of: top[0]) == [.dataless, .unreadable])
        #expect(tree.flags(of: top[1]) == [])
        #expect(tree.children(of: tree.root).map(tree.name(of:)) == ["cloud", "plain"])
        #expect(tree.loose(of: tree.root) == .none)
    }
}
