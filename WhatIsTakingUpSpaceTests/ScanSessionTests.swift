import Foundation
import Synchronization
import Testing
@testable import WhatIsTakingUpSpace

@MainActor
struct ScanSessionTests {
    private let scanner = StubScanner()
    private let first = ScanOutcome.sample(root: "/", size: 5000)
    private let second = ScanOutcome.sample(root: "/", size: 7000)

    private func session() -> ScanSession {
        ScanSession(scanner: scanner, progressPause: .zero)
    }

    /// A session already showing `first`.
    private func sessionShowingFirst() async -> ScanSession {
        let session = session()
        session.scan(rootPath: "/")
        scanner.finish(.success(first))
        await session.activeScan?.value
        return session
    }

    // MARK: First scan

    @Test func aNewSessionWaitsToBeToldWhatToScan() {
        let session = session()

        #expect(session.outcome == nil)
        #expect(session.progress == nil)
        #expect(session.failure == nil)
    }

    @Test func startingAScanShowsProgressAtOnce() {
        let session = session()

        session.scan(rootPath: "/Users/ada")

        #expect(session.progress == ScanProgress(filesSeen: 0, bytesSeen: 0, currentPath: "/Users/ada"))
        #expect(session.outcome == nil)
    }

    @Test func aFinishedScanIsShown() async {
        let session = session()

        session.scan(rootPath: "/")
        scanner.finish(.success(first))
        await session.activeScan?.value

        #expect(session.outcome?.summary == first.summary)
        #expect(session.progress == nil)
        #expect(session.failure == nil)
        #expect(scanner.calls == [.scan(rootPath: "/")])
    }

    @Test func aFailedFirstScanGoesBackToTheStartWithTheReason() async {
        let session = session()

        session.scan(rootPath: "/gone")
        scanner.finish(.failure(DirectoryReadError(code: ENOENT)))
        await session.activeScan?.value

        #expect(session.outcome == nil)
        #expect(session.progress == nil)
        #expect(session.failure == ScanFailure(message: "No such file or directory"))
    }

    @Test func reportsFromTheScanBecomeTheProgressOnScreen() async throws {
        let session = session()
        session.scan(rootPath: "/")
        try await eventually { !scanner.calls.isEmpty }
        let report = ScanProgress(filesSeen: 120, bytesSeen: 4096, currentPath: "/Users")

        scanner.report(report)

        try await eventually { session.progress == report }
    }

    @Test func aReportThatArrivesAfterTheScanWasCancelledChangesNothing() async throws {
        let session = session()
        session.scan(rootPath: "/")
        try await eventually { !scanner.calls.isEmpty }

        session.cancel()
        scanner.report(ScanProgress(filesSeen: 1, bytesSeen: 1, currentPath: "/late"))
        await session.activeScan?.value

        #expect(session.progress == nil)
        #expect(session.outcome == nil)
    }

    // MARK: Cancelling

    @Test func cancellingTheFirstScanGoesBackToTheStartAtOnceWithoutAFailure() async {
        let session = session()
        session.scan(rootPath: "/")

        session.cancel()

        #expect(session.progress == nil)
        #expect(session.outcome == nil)
        #expect(session.failure == nil)
        await session.activeScan?.value
        #expect(scanner.cancelledCalls == 1)
        #expect(session.failure == nil)
    }

    @Test func aScanThatFinishesAfterBeingCancelledIsIgnored() async {
        let session = session()
        session.scan(rootPath: "/")

        session.cancel()
        scanner.finish(.success(first))
        await session.activeScan?.value

        #expect(session.outcome == nil)
    }

    @Test func cancellingWhenNothingIsRunningChangesNothing() async {
        let session = await sessionShowingFirst()

        session.cancel()

        #expect(session.outcome?.summary == first.summary)
    }

    // MARK: Rescanning

    @Test func rescanningRepeatsTheWholeScanAndKeepsTheOldResultMeanwhile() async {
        let session = await sessionShowingFirst()

        session.rescan()

        #expect(session.progress == ScanProgress(filesSeen: 0, bytesSeen: 0, currentPath: "/"))
        #expect(session.outcome?.summary == first.summary)
        scanner.finish(.success(second))
        await session.activeScan?.value
        #expect(session.outcome?.summary == second.summary)
        #expect(scanner.calls == [.scan(rootPath: "/"), .rescan(folder: [], rootPath: "/")])
    }

    @Test func rescanningAFolderAsksForThatFolderAndShowsItsPathWhileItRuns() async {
        let session = await sessionShowingFirst()

        session.rescan(folder: ["Users", "ada"])

        #expect(session.progress?.currentPath == "/Users/ada")
        scanner.finish(.success(second))
        await session.activeScan?.value
        #expect(session.outcome?.summary == second.summary)
        #expect(scanner.calls.last == .rescan(folder: ["Users", "ada"], rootPath: "/"))
    }

    @Test func cancellingARescanKeepsTheOldResult() async {
        let session = await sessionShowingFirst()
        session.rescan()

        session.cancel()
        await session.activeScan?.value

        #expect(session.outcome?.summary == first.summary)
        #expect(session.progress == nil)
        #expect(session.failure == nil)
    }

    @Test func aFailedRescanKeepsTheOldResultAndSaysWhy() async {
        let session = await sessionShowingFirst()

        session.rescan()
        scanner.finish(.failure(DirectoryReadError(code: EPERM)))
        await session.activeScan?.value

        #expect(session.outcome?.summary == first.summary)
        #expect(session.failure == ScanFailure(message: "Operation not permitted"))
    }

    @Test func rescanningWithNothingOnScreenDoesNothing() {
        let session = session()

        session.rescan()
        session.rescan(folder: ["Users"])

        #expect(session.progress == nil)
        #expect(scanner.calls == [])
    }

    @Test func startingAnotherScanReplacesTheOneInFlight() async {
        let session = session()
        session.scan(rootPath: "/first")
        let replaced = session.activeScan

        session.scan(rootPath: "/second")
        await replaced?.value

        #expect(session.progress?.currentPath == "/second")
        scanner.finish(.success(second))
        await session.activeScan?.value
        #expect(session.outcome?.summary == second.summary)
        #expect(scanner.cancelledCalls == 1)
    }

    // MARK: Leaving a result, dismissing a failure

    @Test func closingAResultGoesBackToTheStart() async {
        let session = await sessionShowingFirst()

        session.close()

        #expect(session.outcome == nil)
        #expect(session.failure == nil)
    }

    @Test func closingWhileAScanRunsDoesNothing() {
        let session = session()
        session.scan(rootPath: "/")

        session.close()

        #expect(session.progress != nil)
    }

    @Test func dismissingAFailureKeepsWhateverElseIsOnScreen() async {
        let session = await sessionShowingFirst()
        session.rescan()
        scanner.finish(.failure(DirectoryReadError(code: EPERM)))
        await session.activeScan?.value

        session.dismissFailure()

        #expect(session.failure == nil)
        #expect(session.outcome?.summary == first.summary)
    }

    @Test func dismissingAFailureAtTheStartClearsIt() async {
        let session = session()
        session.scan(rootPath: "/gone")
        scanner.finish(.failure(DirectoryReadError(code: ENOENT)))
        await session.activeScan?.value

        session.dismissFailure()

        #expect(session.failure == nil)
        #expect(session.outcome == nil)
    }

    // MARK: Scanning a folder picked by the user

    @Test func aPickedFolderIsScannedUnderItsRealPath() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ScanSessionTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory.appending(path: "real"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createSymbolicLink(
            at: directory.appending(path: "link"),
            withDestinationURL: directory.appending(path: "real")
        )
        let session = session()

        session.scan(folder: directory.appending(path: "link", directoryHint: .isDirectory))
        try await eventually { !scanner.calls.isEmpty }

        let expected = try #require(realpath(directory.path(percentEncoded: false), nil)).asStringAndFreed() + "/real"
        #expect(scanner.calls == [.scan(rootPath: expected)])
        #expect(!expected.contains("/link"))
        #expect(!expected.hasSuffix("/"))
    }

    @Test func aPickedFolderThatDoesNotExistIsAFailureAndNothingIsScanned() {
        let session = session()

        session.scan(folder: URL(filePath: "/nowhere-\(UUID())/Missing Folder"))

        #expect(session.failure == ScanFailure(message: "“Missing Folder” can’t be opened."))
        #expect(session.progress == nil)
        #expect(scanner.calls == [])
    }

    @Test func somethingPickedThatIsNotAFolderIsAFailureAndNothingIsScanned() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "ScanSessionTests-\(UUID()).txt")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let session = session()

        session.scan(folder: file)

        #expect(session.failure == ScanFailure(message: "“\(file.lastPathComponent)” is not a folder."))
        #expect(session.progress == nil)
        #expect(scanner.calls == [])
    }

    @Test func theStartupDisksCanonicalPathIsASingleSlash() {
        #expect(ScanRoot.canonicalPath(of: URL(filePath: "/")) == "/")
    }
}

private extension UnsafeMutablePointer<CChar> {
    func asStringAndFreed() -> String {
        defer { free(self) }
        return String(cString: self)
    }
}
