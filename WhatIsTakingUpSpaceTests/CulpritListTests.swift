import Testing
@testable import WhatIsTakingUpSpace

struct CulpritListTests {
    /// 1000 bytes in all. With a threshold of 100: the image, the package, Downloads' own
    /// remainder and the root's own loose files.
    private let tree = FileTree(.dir("/Users/ada", [
        .dir("Downloads", [
            .file("image.dmg", 400),
            .dir("Photos.photoslibrary", [.file("originals", 250)]),
        ], loose: LooseFiles(count: 9, bytes: 150)),
        .file("small.txt", 50),
    ], loose: LooseFiles(count: 3, bytes: 150)))

    private func list(_ filter: CulpritFilter = .all, threshold: Int64 = 100) -> CulpritList {
        tree.culpritList(threshold: threshold, filter: filter) { $0.hasSuffix(".photoslibrary") }
    }

    @Test func everyCulpritBecomesARowInTheSameOrder() {
        #expect(list().rows.map(\.name) == ["image.dmg", "Photos.photoslibrary", "/Users/ada", "Downloads"])
        #expect(list().rows.map(\.ownSize) == [400, 250, 200, 150])
        #expect(list().rows.map(\.totalSize) == [400, 250, 1000, 800])
        #expect(list().rows.map(\.kind) == [.file, .package, .folder, .folder])
    }

    @Test func rowSaysWhereItsItemLives() {
        #expect(list().rows.map(\.location) == ["/Users/ada/Downloads", "/Users/ada/Downloads", "", "/Users/ada"])
    }

    @Test func rowIsIdentifiedByItsNode() throws {
        let image = try #require(tree.node(at: ["Downloads", "image.dmg"]))

        #expect(list().rows.first?.id == image)
        #expect(list().rows.map(\.id).contains(tree.root))
    }

    @Test func fractionIsTheRowsOwnShareOfEverythingScanned() {
        #expect(list().rows.map(\.fraction) == [0.4, 0.25, 0.2, 0.15])
    }

    @Test func foldersFilterKeepsFoldersOnly() {
        #expect(list(.folders).rows.map(\.name) == ["/Users/ada", "Downloads"])
    }

    @Test func filesFilterKeepsFilesAndPackages() {
        #expect(list(.files).rows.map(\.name) == ["image.dmg", "Photos.photoslibrary"])
    }

    @Test func totalsCountTheRowsShownAgainstEverythingScanned() {
        #expect(list().listedBytes == 1000)
        #expect(list(.folders).listedBytes == 350)
        #expect(list(.files).listedBytes == 650)
        #expect(list(.files).scannedBytes == 1000)
    }

    @Test func aHigherThresholdListsLess() {
        let coarse = list(threshold: 300)

        // The package (250) no longer stands alone and counts towards Downloads; the root keeps
        // 200 of its own, which is now too little to be listed.
        #expect(coarse.rows.map(\.name) == ["Downloads", "image.dmg"])
        #expect(coarse.rows.map(\.ownSize) == [400, 400])
        #expect(coarse.listedBytes == 800)
    }

    @Test func nothingReachesAThresholdAboveTheWholeScan() {
        let none = list(threshold: 1001)

        #expect(none.rows.isEmpty)
        #expect(none.listedBytes == 0)
        #expect(none.scannedBytes == 1000)
    }

    @Test func anEmptyScanHasNoRowsAndNoDivisionByZero() {
        let empty = FileTree(.dir("/", [])).culpritList(threshold: 0, filter: .all) { _ in false }

        #expect(empty == CulpritList(rows: [], listedBytes: 0, scannedBytes: 0))
    }
}
