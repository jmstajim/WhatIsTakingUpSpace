import Testing
@testable import WhatIsTakingUpSpace

private let mb: Int64 = 1_000_000
private let gb: Int64 = 1_000 * mb

/// A culprit as the user reads it in the "Largest" list.
private struct Row: Equatable, CustomStringConvertible {
    var path: String
    var kind: Culprit.Kind
    var own: Int64
    var total: Int64

    var description: String { "\(path) [\(kind)] own \(own) of \(total)" }

    static func file(_ path: String, _ size: Int64) -> Row {
        Row(path: path, kind: .file, own: size, total: size)
    }

    static func package(_ path: String, _ size: Int64) -> Row {
        Row(path: path, kind: .package, own: size, total: size)
    }

    static func folder(_ path: String, own: Int64, total: Int64) -> Row {
        Row(path: path, kind: .folder, own: own, total: total)
    }
}

private extension FileTree {
    func rows(threshold: Int64 = gb, isPackage: (String) -> Bool = { _ in false }) -> [Row] {
        culprits(threshold: threshold, isPackage: isPackage).map { culprit in
            Row(path: path(of: culprit.node), kind: culprit.kind, own: culprit.ownSize, total: culprit.totalSize)
        }
    }
}

struct CulpritsTests {
    // MARK: Files

    @Test func fileAtOrAboveTheThresholdIsACulprit() {
        let tree = FileTree(.dir("/", [
            .file("exact.bin", gb),
            .file("almost.bin", gb - 1),
        ]))

        #expect(tree.rows() == [.file("/exact.bin", gb)])
    }

    // MARK: Folders

    @Test func foldersOwnSizeLeavesOutDirectChildrenThatReachTheThreshold() {
        // Downloads: an 8 GB disk image plus 2 GB of small things.
        let tree = FileTree(.dir("/Users/ada/Downloads", [
            .file("Xcode.xip", 8 * gb),
            .file("clip.mov", 300 * mb),
            .dir("old", [.file("backup.tar", 200 * mb)]),
        ], loose: LooseFiles(count: 4_000, bytes: 1_500 * mb)))

        #expect(tree.rows() == [
            .file("/Users/ada/Downloads/Xcode.xip", 8 * gb),
            .folder("/Users/ada/Downloads", own: 2 * gb, total: 10 * gb),
        ])
    }

    @Test func folderWhoseOwnSizeIsExactlyTheThresholdIsACulprit() {
        let tree = FileTree(.dir("/", [
            .dir("exact", [.file("big.bin", 3 * gb), .file("small.bin", gb - 1)], loose: LooseFiles(count: 1, bytes: 1)),
            .dir("almost", [.file("big.bin", 2 * gb), .file("small.bin", gb - 1)]),
        ]))

        #expect(tree.rows() == [
            .file("/exact/big.bin", 3 * gb),
            .file("/almost/big.bin", 2 * gb),
            .folder("/exact", own: gb, total: 4 * gb),
        ])
    }

    @Test func directChildOneByteUnderTheThresholdStaysInItsParentsOwnSize() {
        let tree = FileTree(.dir("/", [
            .dir("parent", [
                .dir("exact", [], loose: LooseFiles(count: 9, bytes: gb)),
                .dir("almost", [], loose: LooseFiles(count: 9, bytes: gb - 1)),
            ], loose: LooseFiles(count: 1, bytes: 1)),
        ]))

        #expect(tree.rows() == [
            .folder("/parent", own: gb, total: 2 * gb),
            .folder("/parent/exact", own: gb, total: gb),
        ])
    }

    @Test func theDeepFolderIsShownInsteadOfTheFoldersAroundIt() {
        #expect(library(developerSmallStuff: 600 * mb).rows() == [
            .folder("/Users/ada/Library/Developer/Xcode/DerivedData", own: 9 * gb, total: 9 * gb),
        ])
    }

    @Test func folderAroundTheDeepOneIsShownOnceItsOwnSmallStuffReachesTheThreshold() {
        #expect(library(developerSmallStuff: 3 * gb).rows() == [
            .folder("/Users/ada/Library/Developer/Xcode/DerivedData", own: 9 * gb, total: 9 * gb),
            .folder("/Users/ada/Library/Developer", own: 3 * gb, total: 12 * gb),
        ])
    }

    @Test func scanRootItselfCanBeACulprit() {
        let tree = FileTree(.dir("/Volumes/Stick", [.file("note.txt", 2 * mb)], loose: LooseFiles(count: 50, bytes: 5 * mb)))

        #expect(tree.rows(threshold: 7 * mb) == [.folder("/Volumes/Stick", own: 7 * mb, total: 7 * mb)])
        #expect(tree.rows(threshold: 7 * mb + 1) == [])
    }

    @Test func directoriesThatCouldNotBeMeasuredNeverQualify() {
        let tree = FileTree(.dir("/", [
            .file("one-byte", 1),
            .dir("empty", []),
            .dir("private", [], flags: .unreadable),
            .dir("iCloud Drive", [], flags: .dataless),
            .dir("Volumes", [], flags: .otherVolume),
        ]))

        #expect(tree.rows(threshold: 1) == [.file("/one-byte", 1)])
    }

    // MARK: Packages

    @Test func packageIsOneCulpritAndIsNeverLookedInto() {
        let tree = FileTree(.dir("/Users/ada/Pictures", [
            .dir("Photos Library.photoslibrary", [
                .dir("originals", [.file("IMG_0001.mov", 40 * gb), .file("IMG_0002.mov", 30 * gb)]),
                .dir("database", [.file("Photos.sqlite", 4 * gb)], loose: LooseFiles(count: 900, bytes: 6 * gb)),
            ]),
        ]))

        #expect(tree.rows(isPackage: PackageDetector().isPackage(name:)) == [
            .package("/Users/ada/Pictures/Photos Library.photoslibrary", 80 * gb),
        ])
    }

    @Test func packageAtTheThresholdIsTakenOutOfItsParentAndOneUnderItIsNot() {
        let tree = FileTree(.dir("/Applications", [
            .dir("Exact.app", [.file("binary", gb)]),
            .dir("Almost.app", [.file("binary", gb - 1)]),
        ], loose: LooseFiles(count: 1, bytes: 1)))

        #expect(tree.rows(isPackage: ["Exact.app", "Almost.app"].contains) == [
            .folder("/Applications", own: gb, total: 2 * gb),
            .package("/Applications/Exact.app", gb),
        ])
    }

    /// Someone who points the scan at a package wants to know what is inside it.
    @Test func aScanRootIsLookedIntoEvenWhenItIsAPackage() {
        let tree = FileTree(.dir("/Volumes/Media/Final Cut.fcpbundle", [
            .file("render.mov", 3 * gb),
            .dir("Cache.bundle", [.file("frames", 2 * gb)]),
        ]))

        #expect(tree.rows(isPackage: { _ in true }) == [
            .file("/Volumes/Media/Final Cut.fcpbundle/render.mov", 3 * gb),
            .package("/Volumes/Media/Final Cut.fcpbundle/Cache.bundle", 2 * gb),
        ])
    }

    @Test func fileIsNeverTakenForAPackage() {
        let tree = FileTree(.dir("/", [.file("Installer.app", 2 * gb)]))

        #expect(tree.rows(isPackage: ["Installer.app"].contains) == [.file("/Installer.app", 2 * gb)])
    }

    // MARK: Order

    @Test func culpritsAreListedByOwnSizeLargestFirst() {
        let tree = FileTree(.dir("/", [
            .file("a-small.bin", 2 * gb),
            .dir("b-folder", [.file("inner.bin", 3 * gb)], loose: LooseFiles(count: 7, bytes: 4 * gb)),
            .dir("c.app", [.file("binary", 5 * gb)]),
        ]))

        #expect(tree.rows(isPackage: ["c.app"].contains) == [
            .package("/c.app", 5 * gb),
            .folder("/b-folder", own: 4 * gb, total: 7 * gb),
            .file("/b-folder/inner.bin", 3 * gb),
            .file("/a-small.bin", 2 * gb),
        ])
    }

    @Test func equalOwnSizesAreOrderedByFullPath() {
        // Scan order and bare names both disagree with the order of the full paths.
        let tree = FileTree(.dir("/", [
            .dir("b", [.file("a.bin", gb)]),
            .dir("a", [.file("z.bin", gb)]),
        ]))

        #expect(tree.rows() == [.file("/a/z.bin", gb), .file("/b/a.bin", gb)])
    }

    @Test func equalOwnSizesFollowThePathAsOneStringNotNameByName() {
        // The name "a" sorts before "a b" and "a.b", but the path "/a/x" sorts after "/a b" and "/a.b".
        let tree = FileTree(.dir("/", [
            .dir("a", [.file("x", gb)]),
            .file("a.b", gb),
            .file("a b", gb),
        ]))

        #expect(tree.rows() == [.file("/a b", gb), .file("/a.b", gb), .file("/a/x", gb)])
    }

    // MARK: Pruning

    @Test func onlyDirectoriesThatReachTheThresholdAndSitOutsidePackagesAreExamined() {
        let tree = FileTree(.dir("/Users/ada", [
            .dir("Heavy", [
                .dir("Deep", [.file("big.bin", 2 * gb)]),
                .dir("Light", [.dir("Lighter", [.file("small.bin", 100 * mb)])]),
            ]),
            .dir("Big.app", [.dir("Contents", [.file("binary", 3 * gb)])]),
            .dir("Small.app", [.dir("Contents", [.file("binary", 10 * mb)])]),
            .file("huge.bin", 4 * gb),
        ]))
        var asked: [String] = []

        _ = tree.culprits(threshold: gb) { name in
            asked.append(name)
            return name.hasSuffix(".app")
        }

        // The scan root is split without asking.
        #expect(asked.sorted() == ["Big.app", "Deep", "Heavy"])
    }

    @Test func thresholdBelowOneByteCountsAsOneByte() {
        let tree = FileTree(.dir("/", [.file("one-byte", 1), .dir("empty", [])]))

        #expect(tree.rows(threshold: 0) == [.file("/one-byte", 1)])
        #expect(tree.rows(threshold: -5) == [.file("/one-byte", 1)])
    }

    /// A path holds 1024 bytes at most, so no directory reachable by path sits deeper than this.
    @Test func treeAsDeepAsPathsAllowIsWalkedWithoutRunningOutOfStack() {
        var builder = FileTree.Builder(rootPath: "/")
        var deepest = builder.root
        for _ in 0..<512 {
            deepest = builder.addChildren([.directory("d")], to: deepest)[0]
        }
        builder.addChildren([.file("big.bin", size: 5 * gb)], to: deepest)
        let tree = builder.build()

        let culprits = tree.culprits(threshold: gb) { _ in false }

        #expect(culprits == [Culprit(node: tree.children(of: deepest)[0], kind: .file, ownSize: 5 * gb, totalSize: 5 * gb)])
    }

    // MARK: Fixtures

    /// Library holds Developer plus 0.4 GB of small stuff; Developer holds Xcode plus its own small
    /// stuff, in four equal parts; Xcode holds nothing but DerivedData: 9 GB in three hundred
    /// 30 MB folders.
    private func library(developerSmallStuff: Int64) -> FileTree {
        let part = developerSmallStuff / 4
        let builds = (0..<300).map { index in
            TreeSpec.dir("Build-\(index)", [.file("Index.db", 20 * mb)], loose: LooseFiles(count: 500, bytes: 10 * mb))
        }
        return FileTree(.dir("/Users/ada/Library", [
            .dir("Developer", [
                .dir("Xcode", [.dir("DerivedData", builds)]),
                .dir("CoreSimulator", [.file("runtime.dmg", part)]),
                .dir("Archives", [], loose: LooseFiles(count: 40, bytes: part)),
                .file("toolchain.pkg", part),
            ], loose: LooseFiles(count: 2_000, bytes: part)),
            .dir("Caches", [.file("cache.db", 150 * mb)], loose: LooseFiles(count: 800, bytes: 50 * mb)),
            .file("fonts.cache", 100 * mb),
        ], loose: LooseFiles(count: 3_000, bytes: 100 * mb)))
    }
}
