import Foundation
import Testing
@testable import WhatIsTakingUpSpace

@MainActor
final class ScanWorkspaceTests {
    private let scanner = StubScanner()
    private let suite = "ScanWorkspaceTests-\(UUID())"
    private let defaults: UserDefaults

    private static let disk = TreeSpec.dir("/", [
        .dir("Users", [
            .dir("ada", [
                .dir("Downloads", [.file("big.dmg", 9000)]),
                .dir("Photos.photoslibrary", [.file("originals", 7000)]),
                .file("movie", 5000),
            ], loose: LooseFiles(count: 3, bytes: 30)),
        ]),
        .dir("Applications", [.dir("Xcode.app", [.file("Xcode", 4000)])]),
    ])

    private static let folder = TreeSpec.dir("/Volumes/Box/Games", [.dir("Saves", [.file("slot", 100)])])

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    deinit {
        defaults.removePersistentDomain(forName: suite)
    }

    private func workspace() -> ScanWorkspace {
        ScanWorkspace(
            session: ScanSession(scanner: scanner, progressPause: .zero),
            defaults: defaults,
            isPackage: { $0.hasSuffix(".app") || $0.hasSuffix(".photoslibrary") }
        )
    }

    /// A workspace showing a scan of `spec`.
    private func workspace(showing spec: TreeSpec) async -> ScanWorkspace {
        let workspace = workspace()
        await show(spec, in: workspace) { workspace.scanStartupDisk() }
        return workspace
    }

    private func show(_ spec: TreeSpec, in workspace: ScanWorkspace, after start: () -> Void) async {
        start()
        scanner.finish(.success(.of(spec)))
        await workspace.session.activeScan?.value
    }

    private func node(_ components: String..., in workspace: ScanWorkspace) throws -> FileTree.NodeID {
        try #require(workspace.session.outcome?.tree.node(at: components))
    }

    // MARK: What is remembered between launches

    @Test func aNewWorkspaceBrowsesAndListsEverythingFromOneGigabyteUp() {
        let workspace = workspace()

        #expect(workspace.mode == .browse)
        #expect(workspace.threshold == 1_000_000_000)
        #expect(workspace.filter == .all)
    }

    @Test func theViewTheSizeAndTheFilterAreRememberedForTheNextLaunch() {
        let first = workspace()
        first.mode = .largest
        first.threshold = 5_000_000_000
        first.filter = .files

        let next = workspace()

        #expect(next.mode == .largest)
        #expect(next.threshold == 5_000_000_000)
        #expect(next.filter == .files)
    }

    @Test func rememberedValuesThatAreNoLongerOfferedGiveWayToTheStandardOnes() {
        defaults.set("treemap", forKey: "resultMode")
        defaults.set(123, forKey: "largestThreshold")
        defaults.set("symlinks", forKey: "largestFilter")

        let workspace = workspace()

        #expect(workspace.mode == .browse)
        #expect(workspace.threshold == 1_000_000_000)
        #expect(workspace.filter == .all)
    }

    @Test func everySizeOnOfferCanBeRemembered() {
        for choice in CulpritThreshold.choices {
            workspace().threshold = choice
            #expect(workspace().threshold == choice)
        }
    }

    // MARK: Moving through folders

    @Test func browseStartsAtTheScanRootWithNowhereToGoBackOrUp() async {
        let workspace = await workspace(showing: Self.disk)

        #expect(workspace.shownFolder == workspace.session.outcome?.tree.root)
        #expect(!workspace.canGoBack)
        #expect(!workspace.canGoUp)
    }

    @Test func openingAFolderShowsItAndDropsTheSelection() async throws {
        let workspace = await workspace(showing: Self.disk)
        let users = try node("Users", in: workspace)
        workspace.selection.browse = .node(users)

        workspace.open(users)

        #expect(workspace.shownFolder == users)
        #expect(workspace.location == ["Users"])
        #expect(workspace.selection.browse == nil)
        #expect(workspace.canGoBack)
        #expect(workspace.canGoUp)
    }

    @Test func backReturnsToTheFolderShownBeforeWithNothingSelected() async throws {
        let workspace = await workspace(showing: Self.disk)
        workspace.open(try node("Users", "ada", in: workspace))
        workspace.open(try node("Applications", in: workspace))
        workspace.selection.browse = .looseFiles

        workspace.goBack()

        #expect(workspace.location == ["Users", "ada"])
        #expect(workspace.selection.browse == nil)
        workspace.goBack()
        #expect(workspace.location == [])
        #expect(!workspace.canGoBack)
    }

    @Test func goingUpShowsTheParentWithTheFolderLeftSelected() async throws {
        let workspace = await workspace(showing: Self.disk)
        let ada = try node("Users", "ada", in: workspace)
        workspace.open(ada)

        workspace.goUp()

        #expect(workspace.location == ["Users"])
        #expect(workspace.selection.browse == .node(ada))
        workspace.goBack()
        #expect(workspace.location == ["Users", "ada"])
    }

    @Test func goingUpFromTheScanRootChangesNothing() async {
        let workspace = await workspace(showing: Self.disk)
        workspace.selection.browse = .looseFiles

        workspace.goUp()

        #expect(workspace.location == [])
        #expect(workspace.selection.browse == .looseFiles)
        #expect(!workspace.canGoBack)
    }

    @Test func aCrumbTakesYouThatManyFoldersBelowTheRoot() async throws {
        let workspace = await workspace(showing: Self.disk)
        workspace.open(try node("Users", "ada", "Downloads", in: workspace))
        workspace.selection.browse = .looseFiles

        workspace.go(toDepth: 1)

        #expect(workspace.location == ["Users"])
        #expect(workspace.selection.browse == nil)
        workspace.go(toDepth: 0)
        #expect(workspace.location == [])
    }

    @Test func theSelectedFolderOrPackageCanBeOpenedButNotAFile() async throws {
        let workspace = await workspace(showing: Self.disk)
        workspace.open(try node("Users", "ada", in: workspace))
        #expect(!workspace.canOpenSelection)

        workspace.selection.browse = .node(try node("Users", "ada", "movie", in: workspace))
        #expect(!workspace.canOpenSelection)
        workspace.openSelection()
        #expect(workspace.location == ["Users", "ada"])

        workspace.selection.browse = .looseFiles
        #expect(!workspace.canOpenSelection)

        workspace.selection.browse = .node(try node("Users", "ada", "Photos.photoslibrary", in: workspace))
        #expect(workspace.canOpenSelection)

        workspace.selection.browse = .node(try node("Users", "ada", "Downloads", in: workspace))
        #expect(workspace.canOpenSelection)
        workspace.openSelection()
        #expect(workspace.location == ["Users", "ada", "Downloads"])
    }

    @Test func aFileIsShownInBrowseSelectedInItsFolder() async throws {
        let workspace = await workspace(showing: Self.disk)
        workspace.mode = .largest
        let movie = try node("Users", "ada", "movie", in: workspace)
        workspace.selection.largest = movie
        #expect(workspace.canShowSelectionInBrowse)

        workspace.showSelectionInBrowse()

        #expect(workspace.mode == .browse)
        #expect(workspace.location == ["Users", "ada"])
        #expect(workspace.selection.browse == .node(movie))
        #expect(!workspace.canShowSelectionInBrowse)
    }

    @Test func aFolderIsShownInBrowseByOpeningIt() async throws {
        let workspace = await workspace(showing: Self.disk)
        workspace.mode = .largest

        workspace.showInBrowse(try node("Users", "ada", "Downloads", in: workspace))

        #expect(workspace.mode == .browse)
        #expect(workspace.location == ["Users", "ada", "Downloads"])
        #expect(workspace.selection.browse == nil)
        #expect(workspace.canGoBack)
    }

    @Test func withNothingSelectedInLargestThereIsNothingToShowInBrowse() async {
        let workspace = await workspace(showing: Self.disk)
        workspace.mode = .largest

        #expect(!workspace.canShowSelectionInBrowse)
        workspace.showSelectionInBrowse()
        #expect(workspace.mode == .largest)
    }

    @Test func movingThroughFoldersIsForBrowseOnly() async throws {
        let workspace = await workspace(showing: Self.disk)
        let downloads = try node("Users", "ada", "Downloads", in: workspace)
        workspace.open(try node("Users", "ada", in: workspace))
        workspace.selection.browse = .node(downloads)
        #expect(workspace.canGoBack && workspace.canGoUp && workspace.canOpenSelection)

        workspace.mode = .largest

        #expect(!workspace.canGoBack)
        #expect(!workspace.canGoUp)
        #expect(!workspace.canOpenSelection)
    }

    // MARK: What belongs to one scan

    @Test func theFolderShownIsKeptWhenTheSameRootIsScannedAgain() async throws {
        let workspace = await workspace(showing: Self.disk)
        workspace.open(try node("Users", "ada", in: workspace))

        await show(Self.disk, in: workspace) { workspace.rescan() }

        #expect(workspace.location == ["Users", "ada"])
        #expect(workspace.shownFolder == (try node("Users", "ada", in: workspace)))
        #expect(workspace.canGoBack)
    }

    @Test func aScanOfAnotherRootStartsAtThatRoot() async throws {
        let workspace = await workspace(showing: Self.disk)
        workspace.open(try node("Users", "ada", in: workspace))

        await show(Self.folder, in: workspace) { workspace.scan(folder: URL(filePath: "/")) }

        #expect(workspace.location == [])
        #expect(!workspace.canGoBack)
        #expect(workspace.shownFolder == workspace.session.outcome?.tree.root)
    }

    @Test func aSelectionDoesNotOutliveItsScan() async throws {
        let workspace = await workspace(showing: Self.disk)
        workspace.selection.browse = .node(try node("Users", in: workspace))
        workspace.selection.largest = try node("Applications", in: workspace)

        await show(Self.disk, in: workspace) { workspace.rescan() }

        #expect(workspace.selection.browse == nil)
        #expect(workspace.selection.largest == nil)
    }

    @Test func withoutAResultThereIsNothingToShowSelectOrMoveThrough() throws {
        let workspace = workspace()

        workspace.selection.browse = .looseFiles
        workspace.goUp()
        workspace.go(toDepth: 0)
        workspace.openSelection()

        #expect(workspace.shownFolder == nil)
        #expect(workspace.location == [])
        #expect(workspace.targetPath == nil)
        #expect(!workspace.canGoUp)
        #expect(!workspace.canOpenSelection)
    }

    // MARK: What Show in Finder, Quick Look and Copy Path act on

    @Test func inBrowseTheTargetIsTheSelectedRow() async throws {
        let workspace = await workspace(showing: Self.disk)
        workspace.open(try node("Users", "ada", in: workspace))

        workspace.selection.browse = .node(try node("Users", "ada", "movie", in: workspace))

        #expect(workspace.targetPath == "/Users/ada/movie")
    }

    @Test func inBrowseWithNoRowOfItsOwnTheTargetIsTheFolderShown() async throws {
        let workspace = await workspace(showing: Self.disk)
        workspace.open(try node("Users", "ada", in: workspace))

        #expect(workspace.targetPath == "/Users/ada")
        workspace.selection.browse = .looseFiles
        #expect(workspace.targetPath == "/Users/ada")
    }

    @Test func inLargestTheTargetIsTheSelectedItemOrNothing() async throws {
        let workspace = await workspace(showing: Self.disk)
        workspace.mode = .largest
        #expect(workspace.targetPath == nil)

        workspace.selection.largest = try node("Applications", "Xcode.app", in: workspace)

        #expect(workspace.targetPath == "/Applications/Xcode.app")
    }

    @Test func thePreviewOpensOnTheTargetAndClosesWhenAskedAgain() async throws {
        let workspace = await workspace(showing: Self.disk)
        workspace.selection.browse = .node(try node("Users", in: workspace))

        workspace.togglePreview()
        #expect(workspace.preview == URL(filePath: "/Users"))

        workspace.togglePreview()
        #expect(workspace.preview == nil)
    }

    @Test func withNoTargetThereIsNothingToPreview() async {
        let workspace = await workspace(showing: Self.disk)
        workspace.mode = .largest

        workspace.togglePreview()

        #expect(workspace.preview == nil)
    }

    // MARK: Scanning

    @Test func scanningTheStartupDiskScansFromTheRoot() async throws {
        let workspace = workspace()

        workspace.scanStartupDisk()
        try await eventually { !scanner.calls.isEmpty }

        #expect(scanner.calls == [.scan(rootPath: "/")])
        #expect(workspace.isScanning)
    }

    @Test func rescanningTheFolderShownAsksForJustThatFolder() async throws {
        let workspace = await workspace(showing: Self.disk)
        workspace.open(try node("Users", "ada", in: workspace))

        workspace.rescanShownFolder()
        try await eventually { scanner.calls.count == 2 }

        #expect(scanner.calls.last == .rescan(folder: ["Users", "ada"], rootPath: "/"))
    }

    @Test func aResultCanBeRescannedOrLeftOnlyWhileNoScanRuns() async {
        let workspace = workspace()
        #expect(!workspace.canRescan && !workspace.canRescanShownFolder)

        await show(Self.disk, in: workspace) { workspace.scanStartupDisk() }
        #expect(workspace.canRescan && workspace.canRescanShownFolder)
        #expect(!workspace.isScanning)

        workspace.rescan()
        #expect(!workspace.canRescan && !workspace.canRescanShownFolder)
    }

    @Test func oneFolderIsRescannedFromBrowseOnly() async {
        let workspace = await workspace(showing: Self.disk)

        workspace.mode = .largest

        #expect(workspace.canRescan)
        #expect(!workspace.canRescanShownFolder)
    }

    @Test func aNewScanLeavesTheResultForTheStartScreen() async {
        let workspace = await workspace(showing: Self.disk)

        workspace.startNewScan()

        #expect(workspace.session.outcome == nil)
        #expect(workspace.shownFolder == nil)
    }
}
