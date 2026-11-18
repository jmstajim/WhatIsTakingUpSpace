import Synchronization
import Testing
@testable import WhatIsTakingUpSpace

struct DiskScannerTests {
    private static let mounts = [
        Mount(path: "/", source: "/dev/disk3s1s1", fileSystem: "apfs"),
        Mount(path: "/System/Data", source: "/dev/disk3s5", fileSystem: "apfs"),
        Mount(path: "/Volumes/Box", source: "/dev/disk7s1", fileSystem: "apfs"),
    ]

    private static let space = VolumeSpace(capacity: 100_000, free: 20_000, availableForImportantUsage: 30_000)

    /// A startup disk: a home folder, a sibling volume of the same container and an external disk.
    private static let disk: [String: [DirectoryEntry]] = [
        "/": [.dir("Users", 10), .dir("System", 30), .dir("Volumes", 20), .file("kernel", 1000)],
        "/System": [.dir("Data", 5, mountPoint: true)],
        "/Users": [.dir("ada", 11)],
        "/Users/ada": [.dir("Downloads", 12), .file("movie", 5000)],
        "/Users/ada/Downloads": [.file("old.dmg", 8000), .file("note", 7)],
        "/System/Data": [.file("swap", 2000)],
        "/Volumes": [.dir("Box", 21, mountPoint: true)],
        "/Volumes/Box": [.file("game", 9000)],
    ]

    private static let identities = [
        "/": FileIdentity(device: 1, inode: 2),
        "/System/Data": FileIdentity(device: 2, inode: 2),
        "/Volumes/Box": FileIdentity(device: 7, inode: 2),
    ]

    private func scanner(
        _ reader: FakeDirectoryReader,
        spaceRead: @escaping @Sendable (String) throws -> VolumeSpace = { _ in space }
    ) -> DiskScanner {
        DiskScanner(reader: reader, looseCutoff: 100, parallelism: 1, mounts: { Self.mounts }, space: spaceRead)
    }

    private func reader(_ listings: [String: [DirectoryEntry]] = disk) -> FakeDirectoryReader {
        FakeDirectoryReader(identities: Self.identities, listings: listings)
    }

    // MARK: A fresh scan

    @Test func scanOfAVolumeRootEntersTheOtherVolumesOfItsContainerButNoOthers() async throws {
        let reader = reader()

        let outcome = try await scanner(reader).scan(rootPath: "/") { _ in }

        let tree = outcome.tree
        #expect(tree.node(at: ["System", "Data"]).map(tree.size(of:)) == 2000)
        #expect(tree.node(at: ["Volumes", "Box"]).map(tree.flags(of:)) == .otherVolume)
        #expect(tree.size(of: tree.root) == 16007)
        #expect(!reader.listedPaths.contains("/Volumes/Box"))
    }

    @Test func scanOfAVolumeRootSaysHowMuchOfTheUsedSpaceItDidNotFind() async throws {
        let outcome = try await scanner(reader()).scan(rootPath: "/") { _ in }

        #expect(outcome.summary == DiskSummary(space: Self.space, foundInFiles: 16007, coversWholeVolume: true))
        #expect(outcome.summary.unaccounted == 63993)
    }

    @Test func scanOfAPlainFolderStaysOnItsVolumeAndClaimsNothingAboutTheRest() async throws {
        let reader = reader()

        let outcome = try await scanner(reader).scan(rootPath: "/Users/ada") { _ in }

        #expect(outcome.tree.name(of: outcome.tree.root) == "/Users/ada")
        #expect(outcome.summary == DiskSummary(space: Self.space, foundInFiles: 13007, coversWholeVolume: false))
        #expect(outcome.summary.unaccounted == nil)
        #expect(reader.listedPaths == ["/Users/ada", "/Users/ada/Downloads"])
    }

    @Test func scanOfAnExternalDisksRootCoversThatWholeVolume() async throws {
        let outcome = try await scanner(reader()).scan(rootPath: "/Volumes/Box") { _ in }

        #expect(outcome.summary.coversWholeVolume)
        #expect(outcome.summary.foundInFiles == 9000)
    }

    @Test func directoriesTheScanCouldNotReadAreListedWithTheOutcome() async throws {
        let reader = FakeDirectoryReader(
            identities: Self.identities,
            listings: Self.disk,
            failures: ["/Users/ada/Downloads": Unavailable()]
        )

        let outcome = try await scanner(reader).scan(rootPath: "/") { _ in }

        #expect(outcome.unreadable.map(outcome.tree.path(of:)) == ["/Users/ada/Downloads"])
    }

    @Test func spaceIsReadForTheScanRoot() async throws {
        let asked = AskedPaths()

        _ = try await scanner(reader(), spaceRead: { asked.record($0); return Self.space }).scan(rootPath: "/Users/ada") { _ in }

        #expect(asked.paths == ["/Users/ada"])
    }

    @Test func aRootThatCannotBeReadFailsTheScan() async {
        await #expect(throws: FakeDirectoryReader.NoSuchDirectory(path: "/gone")) {
            try await scanner(reader()).scan(rootPath: "/gone") { _ in }
        }
    }

    @Test func aSpaceReadingThatFailsFailsTheScan() async {
        await #expect(throws: Unavailable()) {
            try await scanner(reader(), spaceRead: { _ in throw Unavailable() }).scan(rootPath: "/") { _ in }
        }
    }

    @Test func progressOfTheScanIsPassedOn() async throws {
        let log = ProgressTotals()

        _ = try await scanner(reader()).scan(rootPath: "/Users/ada", progress: log.record)

        #expect(log.last == ScanProgress(filesSeen: 3, bytesSeen: 13007, currentPath: "/Users/ada/Downloads"))
    }

    // MARK: How much a scan expects to find

    @Test func aFirstScanOfAVolumeExpectsItsUsedSpace() async throws {
        let log = ProgressTotals()

        _ = try await scanner(reader()).scan(rootPath: "/", progress: log.record)

        #expect(log.last?.expectedBytes == 80_000)
        #expect(log.last?.bytesSeen == 16007)
    }

    @Test func aFirstScanOfAFolderDoesNotKnowWhatToExpect() async throws {
        let log = ProgressTotals()

        _ = try await scanner(reader()).scan(rootPath: "/Users/ada", progress: log.record)

        #expect(log.last?.expectedBytes == nil)
    }

    @Test func aVolumeWhoseSpaceCannotBeReadIsScannedWithoutAnExpectation() async throws {
        let log = ProgressTotals()
        let reads = Mutex(0)
        let flaky: @Sendable (String) throws -> VolumeSpace = { _ in
            // The first reading, before the walk, fails; the one for the summary works.
            if reads.withLock({ $0 += 1; return $0 }) == 1 { throw Unavailable() }
            return Self.space
        }

        _ = try await scanner(reader(), spaceRead: flaky).scan(rootPath: "/", progress: log.record)

        #expect(log.last?.expectedBytes == nil)
    }

    @Test func rescanningAFolderExpectsWhatItHeldLastTime() async throws {
        let before = try await scanner(reader()).scan(rootPath: "/") { _ in }
        let log = ProgressTotals()

        _ = try await scanner(reader(Self.diskAfterCleanup))
            .rescan(folder: ["Users", "ada", "Downloads"], of: before, progress: log.record)

        #expect(log.last?.expectedBytes == 8007)
    }

    @Test func rescanningEverythingExpectsWhatWasFoundLastTime() async throws {
        let before = try await scanner(reader()).scan(rootPath: "/Users/ada") { _ in }
        let log = ProgressTotals()

        _ = try await scanner(reader()).rescan(folder: [], of: before, progress: log.record)

        #expect(log.last?.expectedBytes == 13007)
    }

    @Test func rescanningAFolderThatWasEmptyExpectsNothingInParticular() async throws {
        var listings = Self.disk
        listings["/Users/ada/Downloads"] = []
        let before = try await scanner(reader(listings)).scan(rootPath: "/") { _ in }
        let log = ProgressTotals()

        _ = try await scanner(reader())
            .rescan(folder: ["Users", "ada", "Downloads"], of: before, progress: log.record)

        #expect(log.last?.expectedBytes == 0)
        #expect(log.last?.fraction == nil)
    }

    // MARK: Rescanning one folder

    /// What the disk looks like after the user emptied Downloads and saved a new file there.
    private static var diskAfterCleanup: [String: [DirectoryEntry]] {
        var listings = disk
        listings["/Users/ada/Downloads"] = [.file("new.iso", 300)]
        listings["/Users/ada"] = [.dir("Downloads", 12), .file("movie", 5000), .file("added-elsewhere", 4000)]
        return listings
    }

    @Test func rescanningAFolderReplacesThatFolderAndNothingElse() async throws {
        let before = try await scanner(reader()).scan(rootPath: "/") { _ in }
        let after = reader(Self.diskAfterCleanup)

        let outcome = try await scanner(after).rescan(folder: ["Users", "ada", "Downloads"], of: before) { _ in }

        let tree = outcome.tree
        #expect(tree.node(at: ["Users", "ada", "Downloads"]).map(tree.size(of:)) == 300)
        #expect(tree.node(at: ["Users", "ada", "Downloads", "new.iso"]) != nil)
        #expect(tree.node(at: ["Users", "ada", "Downloads", "old.dmg"]) == nil)
        // The rest of the tree is as it was scanned: the file added next to Downloads is not seen.
        #expect(tree.node(at: ["Users", "ada", "added-elsewhere"]) == nil)
        #expect(tree.size(of: tree.root) == 8300)
        #expect(after.listedPaths == ["/Users/ada/Downloads"])
    }

    @Test func rescanningAFolderBringsTheSummaryUpToDate() async throws {
        let before = try await scanner(reader()).scan(rootPath: "/") { _ in }
        let freed = VolumeSpace(capacity: 100_000, free: 27_707, availableForImportantUsage: 30_000)

        let outcome = try await scanner(reader(Self.diskAfterCleanup), spaceRead: { _ in freed })
            .rescan(folder: ["Users", "ada", "Downloads"], of: before) { _ in }

        #expect(outcome.summary == DiskSummary(space: freed, foundInFiles: 8300, coversWholeVolume: true))
    }

    @Test func rescanningAFolderOfAFolderScanKeepsItAFolderScan() async throws {
        let before = try await scanner(reader()).scan(rootPath: "/Users/ada") { _ in }

        let outcome = try await scanner(reader(Self.diskAfterCleanup)).rescan(folder: ["Downloads"], of: before) { _ in }

        #expect(outcome.tree.name(of: outcome.tree.root) == "/Users/ada")
        #expect(outcome.summary == DiskSummary(space: Self.space, foundInFiles: 5300, coversWholeVolume: false))
    }

    @Test func rescanningTheRootScansEverythingAgain() async throws {
        let before = try await scanner(reader()).scan(rootPath: "/") { _ in }
        let after = reader(Self.diskAfterCleanup)

        let outcome = try await scanner(after).rescan(folder: [], of: before) { _ in }

        #expect(outcome.tree.node(at: ["Users", "ada", "added-elsewhere"]) != nil)
        #expect(outcome.tree.size(of: outcome.tree.root) == 12300)
        #expect(after.listedPaths.first == "/")
    }

    /// A folder that holds a volume the scan enters cannot be rescanned by itself: the volume is
    /// read last, after everything outside it, and only a whole scan keeps that order.
    @Test(arguments: [["System"], ["System", "Data"]])
    func rescanningAFolderAtOrAboveAnEnteredVolumeScansEverythingAgain(folder: [String]) async throws {
        let before = try await scanner(reader()).scan(rootPath: "/") { _ in }
        let after = reader(Self.diskAfterCleanup)

        let outcome = try await scanner(after).rescan(folder: folder, of: before) { _ in }

        #expect(after.listedPaths.first == "/")
        #expect(outcome.tree.size(of: outcome.tree.root) == 12300)
    }

    @Test func rescanningAFolderThatIsGoneRescansTheNearestFolderThatIsStillThere() async throws {
        let before = try await scanner(reader()).scan(rootPath: "/") { _ in }
        var listings = Self.disk
        listings["/Users/ada/Downloads"] = nil
        listings["/Users/ada"] = [.file("movie", 5000)]
        let after = reader(listings)

        let outcome = try await scanner(after).rescan(folder: ["Users", "ada", "Downloads"], of: before) { _ in }

        let tree = outcome.tree
        #expect(tree.node(at: ["Users", "ada", "Downloads"]) == nil)
        #expect(tree.node(at: ["Users", "ada"]).map(tree.size(of:)) == 5000)
        #expect(after.listedPaths == ["/Users/ada/Downloads", "/Users/ada"])
    }

    @Test func rescanningSomethingThatIsNotAFolderOfTheTreeScansEverythingAgain() async throws {
        let before = try await scanner(reader()).scan(rootPath: "/") { _ in }
        let after = reader()

        _ = try await scanner(after).rescan(folder: ["Users", "ada", "movie"], of: before) { _ in }
        _ = try await scanner(after).rescan(folder: ["Users", "nobody"], of: before) { _ in }

        #expect(after.listedPaths.filter { $0 == "/" }.count == 2)
    }

    @Test func aCancelledRescanIsNotRetriedHigherUp() async throws {
        let before = try await scanner(reader()).scan(rootPath: "/") { _ in }
        let after = reader()

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await scanner(after).rescan(folder: ["Users", "ada", "Downloads"], of: before) { _ in }
        }

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(after.listedPaths == [])
    }
}

private struct Unavailable: Error, Equatable {}

private final class AskedPaths: Sendable {
    private let collected = Mutex<[String]>([])
    var paths: [String] { collected.withLock(\.self) }
    func record(_ path: String) { collected.withLock { $0.append(path) } }
}

private final class ProgressTotals: Sendable {
    private let latest = Mutex<ScanProgress?>(nil)
    var last: ScanProgress? { latest.withLock(\.self) }
    func record(_ progress: ScanProgress) { latest.withLock { $0 = progress } }
}
