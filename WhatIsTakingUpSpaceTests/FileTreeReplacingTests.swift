import Testing
@testable import WhatIsTakingUpSpace

struct FileTreeReplacingTests {
    private let tree = FileTree(.dir("/", [
        .dir("Users", [
            .dir("ada", [
                .dir("Downloads", [
                    .file("old.dmg", 8_000_000),
                    .dir("junk", [.file("a.bin", 3_000_000)]),
                ], loose: LooseFiles(count: 4, bytes: 400)),
                .file("movie.mov", 5_000_000),
            ], loose: LooseFiles(count: 1, bytes: 10)),
        ], flags: .unreadable),
        .dir("Applications", [.file("big.app", 9_000_000)]),
    ], loose: LooseFiles(count: 2, bytes: 20)))

    /// What a fresh scan of Downloads returns: its root is named by the full path it was scanned at.
    private let rescanned = FileTree(.dir("/Users/ada/Downloads", [
        .file("new.iso", 2_000_000),
        .dir("kept", [.file("b.bin", 1_000_000)], loose: LooseFiles(count: 1, bytes: 5)),
    ], loose: LooseFiles(count: 7, bytes: 70)))

    @Test func replacedDirectoryShowsTheNewContentsUnderItsOldName() throws {
        let downloads = try #require(tree.node(at: ["Users", "ada", "Downloads"]))

        let result = tree.replacingSubtree(at: downloads, with: rescanned)

        #expect(sizesByPath(result) == [
            "/": 17_000_105,
            "/Users": 8_000_085,
            "/Users/ada": 8_000_085,
            "/Users/ada/Downloads": 3_000_075,
            "/Users/ada/Downloads/new.iso": 2_000_000,
            "/Users/ada/Downloads/kept": 1_000_005,
            "/Users/ada/Downloads/kept/b.bin": 1_000_000,
            "/Users/ada/movie.mov": 5_000_000,
            "/Applications": 9_000_000,
            "/Applications/big.app": 9_000_000,
        ])
    }

    @Test func looseFilesComeFromTheReplacementAtTheTargetAndFromTheOriginalElsewhere() throws {
        let downloads = try #require(tree.node(at: ["Users", "ada", "Downloads"]))

        let result = tree.replacingSubtree(at: downloads, with: rescanned)

        let newDownloads = try #require(result.node(at: ["Users", "ada", "Downloads"]))
        let kept = try #require(result.node(at: ["Users", "ada", "Downloads", "kept"]))
        let ada = try #require(result.node(at: ["Users", "ada"]))
        #expect(result.loose(of: newDownloads) == LooseFiles(count: 7, bytes: 70))
        #expect(result.loose(of: kept) == LooseFiles(count: 1, bytes: 5))
        #expect(result.loose(of: ada) == LooseFiles(count: 1, bytes: 10))
        #expect(result.loose(of: result.root) == LooseFiles(count: 2, bytes: 20))
    }

    @Test func flagsComeFromTheReplacementAtTheTargetAndFromTheOriginalElsewhere() throws {
        let users = try #require(tree.node(at: ["Users"]))
        let ada = try #require(tree.node(at: ["Users", "ada"]))
        let nowCloudOnly = FileTree(.dir("/Users/ada", [], flags: .dataless))

        let untouched = tree.replacingSubtree(at: ada, with: nowCloudOnly)
        let cleared = tree.replacingSubtree(at: users, with: FileTree(.dir("/Users", [])))

        #expect(untouched.node(at: ["Users"]).map(untouched.flags(of:)) == .unreadable)
        #expect(untouched.node(at: ["Users", "ada"]).map(untouched.flags(of:)) == .dataless)
        #expect(cleared.node(at: ["Users"]).map(cleared.flags(of:)) == [])
    }

    @Test func kindsAreKept() throws {
        let downloads = try #require(tree.node(at: ["Users", "ada", "Downloads"]))

        let result = tree.replacingSubtree(at: downloads, with: rescanned)

        #expect(result.node(at: ["Users", "ada", "movie.mov"]).map(result.kind(of:)) == .file)
        #expect(result.node(at: ["Users", "ada", "Downloads", "new.iso"]).map(result.kind(of:)) == .file)
        #expect(result.node(at: ["Users", "ada", "Downloads", "kept"]).map(result.kind(of:)) == .directory)
    }

    @Test func replacingTheRootKeepsItsNameAndTakesEverythingElseFromTheReplacement() {
        let fresh = FileTree(.dir("/", [.file("only.bin", 4_000_000)], loose: LooseFiles(count: 1, bytes: 1), flags: .otherVolume))

        let result = tree.replacingSubtree(at: tree.root, with: fresh)

        #expect(sizesByPath(result) == ["/": 4_000_001, "/only.bin": 4_000_000])
        #expect(result.flags(of: result.root) == .otherVolume)
        #expect(result.loose(of: result.root) == LooseFiles(count: 1, bytes: 1))
    }

    @Test func theOriginalTreeIsLeftAsItWas() throws {
        let downloads = try #require(tree.node(at: ["Users", "ada", "Downloads"]))
        let before = sizesByPath(tree)

        _ = tree.replacingSubtree(at: downloads, with: rescanned)

        #expect(sizesByPath(tree) == before)
        #expect(before["/Users/ada/Downloads/old.dmg"] == 8_000_000)
    }

    private func sizesByPath(_ tree: FileTree) -> [String: Int64] {
        var sizes: [String: Int64] = [:]
        var pending = [tree.root]
        while let node = pending.popLast() {
            sizes[tree.path(of: node)] = tree.size(of: node)
            pending.append(contentsOf: tree.children(of: node))
        }
        return sizes
    }
}
