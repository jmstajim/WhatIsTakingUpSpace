import Foundation
import Testing
@testable import WhatIsTakingUpSpace

struct BrowserRowsTests {
    private let tree = FileTree(.dir("/", [
        .dir("Applications", [
            .dir("Xcode.app", [.file("Xcode", 6_000_000)]),
            .dir("Utilities", [.file("tool", 1_000_000)]),
            .file("installer.pkg", 2_000_000),
            .dir("Locked", [], flags: .unreadable),
        ], loose: LooseFiles(count: 12, bytes: 1_000_000)),
        .dir("Empty", []),
    ]))

    private func isPackage(_ name: String) -> Bool { name.hasSuffix(".app") }

    @Test func rowsAreLargestFirstWithLooseFilesLast() throws {
        let applications = try #require(tree.node(at: ["Applications"]))

        let rows = tree.browserRows(of: applications, isPackage: isPackage)

        #expect(rows.map(\.name) == ["Xcode.app", "installer.pkg", "Utilities", "Locked", ""])
        #expect(rows.map(\.size) == [6_000_000, 2_000_000, 1_000_000, 0, 1_000_000])
        #expect(rows.map(\.kind) == [.package, .file, .folder, .folder, .looseFiles(count: 12)])
    }

    @Test func fractionIsTheShareOfTheFolderBeingShown() throws {
        let applications = try #require(tree.node(at: ["Applications"]))

        let rows = tree.browserRows(of: applications, isPackage: isPackage)

        #expect(rows.map(\.fraction) == [0.6, 0.2, 0.1, 0, 0.1])
    }

    @Test func foldersAndPackagesCanBeEnteredFilesAndLooseFilesCannot() throws {
        let applications = try #require(tree.node(at: ["Applications"]))

        let rows = tree.browserRows(of: applications, isPackage: isPackage)

        #expect(rows.map(\.canEnter) == [true, false, true, true, false])
    }

    @Test func rowIdentifiesItsNodeAndLooseRowHasNone() throws {
        let applications = try #require(tree.node(at: ["Applications"]))
        let xcode = try #require(tree.node(at: ["Applications", "Xcode.app"]))

        let rows = tree.browserRows(of: applications, isPackage: isPackage)

        #expect(rows.first?.node == xcode)
        #expect(rows.first?.id == .node(xcode))
        #expect(rows.last?.node == nil)
        #expect(rows.last?.id == .looseFiles)
    }

    @Test func flagsTravelWithTheRow() throws {
        let applications = try #require(tree.node(at: ["Applications"]))

        let rows = tree.browserRows(of: applications, isPackage: isPackage)

        #expect(rows.map(\.flags) == [[], [], [], .unreadable, []])
    }

    @Test func folderWithoutLooseFilesHasNoLooseRow() {
        let rows = tree.browserRows(of: tree.root, isPackage: isPackage)

        #expect(rows.map(\.name) == ["Applications", "Empty"])
        #expect(rows.map(\.fraction) == [1, 0])
    }

    @Test func emptyFolderHasNoRowsAndAnAllZeroFolderHasZeroFractions() throws {
        let empty = try #require(tree.node(at: ["Empty"]))
        let zeros = FileTree(.dir("/", [.dir("a", []), .dir("b", [])]))

        #expect(tree.browserRows(of: empty, isPackage: isPackage).isEmpty)
        #expect(zeros.browserRows(of: zeros.root, isPackage: isPackage).map(\.fraction) == [0, 0])
    }

    @Test func aSingleLooseFileStillGetsItsRow() {
        let lonely = FileTree(.dir("/", [], loose: LooseFiles(count: 1, bytes: 10)))

        #expect(lonely.browserRows(of: lonely.root, isPackage: isPackage).map(\.kind) == [.looseFiles(count: 1)])
    }

    @Test func aFolderOfOneByteIsStillSharedOut() {
        let tiny = FileTree(.dir("/", [.file("a", 1)]))

        #expect(tiny.browserRows(of: tiny.root, isPackage: isPackage).map(\.fraction) == [1])
    }

    // MARK: - Showing an item from another view

    @Test func aFolderIsShownByOpeningIt() throws {
        let utilities = try #require(tree.node(at: ["Applications", "Utilities"]))

        #expect(tree.browseTarget(for: utilities, isPackage: isPackage)
            == BrowseTarget(location: ["Applications", "Utilities"], selection: nil))
    }

    @Test func aFileIsShownSelectedInTheFolderThatHoldsIt() throws {
        let installer = try #require(tree.node(at: ["Applications", "installer.pkg"]))

        #expect(tree.browseTarget(for: installer, isPackage: isPackage)
            == BrowseTarget(location: ["Applications"], selection: .node(installer)))
    }

    @Test func aPackageIsShownSelectedLikeAFileNotOpened() throws {
        let xcode = try #require(tree.node(at: ["Applications", "Xcode.app"]))

        #expect(tree.browseTarget(for: xcode, isPackage: isPackage)
            == BrowseTarget(location: ["Applications"], selection: .node(xcode)))
    }

    @Test func somethingDirectlyInTheScanRootIsSelectedThere() throws {
        let flat = FileTree(.dir("/Volumes/Box", [.file("big.bin", 5_000_000)]))
        let file = try #require(flat.node(at: ["big.bin"]))

        #expect(flat.browseTarget(for: file, isPackage: isPackage) == BrowseTarget(location: [], selection: .node(file)))
    }

    @Test func theScanRootIsShownByOpeningItEvenWhenItIsNamedLikeAPackage() {
        let scannedPackage = FileTree(.dir("/Applications/Xcode.app", [.file("Xcode", 6_000_000)]))

        #expect(scannedPackage.browseTarget(for: scannedPackage.root, isPackage: { _ in true })
            == BrowseTarget(location: [], selection: nil))
    }

    // MARK: - Keeping the place across a rescan

    @Test func relativeComponentsAreTheNamesBelowTheRoot() throws {
        let xcode = try #require(tree.node(at: ["Applications", "Xcode.app"]))

        #expect(tree.relativeComponents(of: xcode) == ["Applications", "Xcode.app"])
        #expect(tree.relativeComponents(of: tree.root) == [])
    }

    @Test func nearestDirectoryIsTheDeepestOneThatStillExists() throws {
        let applications = try #require(tree.node(at: ["Applications"]))
        let utilities = try #require(tree.node(at: ["Applications", "Utilities"]))

        #expect(tree.nearestDirectory(at: ["Applications", "Utilities"]) == utilities)
        #expect(tree.nearestDirectory(at: ["Applications", "Deleted", "Deeper"]) == applications)
        #expect(tree.nearestDirectory(at: ["Gone"]) == tree.root)
        #expect(tree.nearestDirectory(at: []) == tree.root)
    }

    @Test func nearestDirectoryStopsAboveAFile() throws {
        let applications = try #require(tree.node(at: ["Applications"]))

        #expect(tree.nearestDirectory(at: ["Applications", "installer.pkg"]) == applications)
    }

    // MARK: Sorting by a column

    @Test func sortedByNameTheRowsAreInFinderOrderAndLooseFilesStayLast() throws {
        let applications = try #require(tree.node(at: ["Applications"]))
        let rows = tree.browserRows(of: applications, isPackage: isPackage)

        let byName = rows.arranged(by: [KeyPathComparator(\.name, comparator: .localizedStandard)])
        let reversed = rows.arranged(by: [KeyPathComparator(\.name, comparator: .localizedStandard, order: .reverse)])

        #expect(byName.map(\.name) == ["installer.pkg", "Locked", "Utilities", "Xcode.app", ""])
        #expect(reversed.map(\.name) == ["Xcode.app", "Utilities", "Locked", "installer.pkg", ""])
    }

    @Test func sortedBySizeSmallestFirstLooseFilesStillStayLast() throws {
        let applications = try #require(tree.node(at: ["Applications"]))
        let rows = tree.browserRows(of: applications, isPackage: isPackage)

        let smallestFirst = rows.arranged(by: [KeyPathComparator(\.size)])

        #expect(smallestFirst.map(\.name) == ["Locked", "Utilities", "installer.pkg", "Xcode.app", ""])
    }

    @Test func withNoOrderGivenTheRowsStayAsTheyAre() throws {
        let applications = try #require(tree.node(at: ["Applications"]))
        let rows = tree.browserRows(of: applications, isPackage: isPackage)

        #expect(rows.arranged(by: []) == rows)
    }

    @Test func aFolderOfLooseFilesOnlyIsArrangedToItself() {
        let lonely = FileTree(.dir("/", [], loose: LooseFiles(count: 2, bytes: 10)))
        let rows = lonely.browserRows(of: lonely.root, isPackage: isPackage)

        #expect(rows.arranged(by: [KeyPathComparator(\.size)]) == rows)
    }

    @Test func aRowStandsForOneItemOfItsKindUnlessItIsTheLooseFiles() {
        #expect(BrowserRow.Kind.folder.item == .folder)
        #expect(BrowserRow.Kind.package.item == .package)
        #expect(BrowserRow.Kind.file.item == .file)
        #expect(BrowserRow.Kind.looseFiles(count: 3).item == nil)
    }
}
