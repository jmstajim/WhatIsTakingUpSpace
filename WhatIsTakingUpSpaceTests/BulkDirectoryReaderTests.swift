import Darwin
import Foundation
import Synchronization
import Testing
@testable import WhatIsTakingUpSpace

/// Decoding of packed getattrlistbulk records, on hand-built bytes: the cases a test cannot create on disk.
struct AttributeRecordTests {
    private func decode(_ record: PackedRecord) -> DirectoryEntry? {
        record.bytes.withUnsafeBytes { AttributeRecord.entry(from: $0) }
    }

    @Test func regularFileRecordBecomesAFileEntry() {
        let record = PackedRecord(name: "movie.mov", device: 0x0100_0012, objectType: VREG.rawValue,
                                  flags: 0, fileID: 0x1_2345_6789, linkCount: 3,
                                  allocatedSize: 5_000_000_000)

        #expect(decode(record) == DirectoryEntry(
            name: "movie.mov", kind: .file,
            identity: FileIdentity(device: 0x0100_0012, inode: 0x1_2345_6789),
            allocatedSize: 5_000_000_000, linkCount: 3, isMountPoint: false, isDataless: false))
    }

    @Test func directoryRecordBecomesADirectoryEntryWithNoSize() {
        var record = PackedRecord.directory(name: "Фото и видео")
        record.device = 5
        record.fileID = 77

        #expect(decode(record) == DirectoryEntry(
            name: "Фото и видео", kind: .directory, identity: FileIdentity(device: 5, inode: 77),
            allocatedSize: 0, linkCount: 1, isMountPoint: false, isDataless: false))
    }

    @Test func directoryNeverReportsASizeEvenWhenTheRecordCarriesOne() {
        var record = PackedRecord.directory()
        record.allocatedSize = 4096

        #expect(decode(record)?.allocatedSize == 0)
    }

    @Test(arguments: [VLNK, VNON, VBLK, VCHR, VSOCK, VFIFO, VBAD, VSTR, VCPLX].map(\.rawValue) + [99])
    func everyTypeButFileAndDirectoryIsOther(objectType: UInt32) {
        let record = PackedRecord(objectType: objectType, allocatedSize: 4096)

        #expect(decode(record)?.kind == .other)
        #expect(decode(record)?.allocatedSize == 4096)
    }

    @Test func recordWithoutAnObjectTypeIsOther() {
        #expect(decode(PackedRecord(objectType: nil))?.kind == .other)
    }

    @Test(arguments: [
        (UInt32(0), false),
        (UInt32(DIR_MNTSTATUS_MNTPOINT), true),
        (UInt32(DIR_MNTSTATUS_TRIGGER), true),
        (UInt32(DIR_MNTSTATUS_MNTPOINT | DIR_MNTSTATUS_TRIGGER), true),
        (~UInt32(DIR_MNTSTATUS_MNTPOINT | DIR_MNTSTATUS_TRIGGER), false),
    ])
    func mountPointIsADirectoryWithAMountOrATriggerOnIt(mountStatus: UInt32, expected: Bool) {
        #expect(decode(.directory(mountStatus: mountStatus))?.isMountPoint == expected)
    }

    @Test(arguments: [
        (UInt32(0), false),
        (UInt32(SF_DATALESS), true),
        (UInt32(SF_DATALESS) | UInt32(UF_HIDDEN), true),
        (~UInt32(SF_DATALESS), false),
    ])
    func datalessComesFromTheFileFlags(flags: UInt32, expected: Bool) {
        var directory = PackedRecord.directory()
        directory.flags = flags

        #expect(decode(directory)?.isDataless == expected)
        #expect(decode(PackedRecord(flags: flags))?.isDataless == expected)
    }

    @Test func absentAttributesFallBackToNeutralValues() {
        let record = PackedRecord(name: "bare", device: nil, objectType: VREG.rawValue, flags: nil,
                                  fileID: nil, linkCount: nil, allocatedSize: nil)

        #expect(decode(record) == DirectoryEntry(
            name: "bare", kind: .file, identity: FileIdentity(device: 0, inode: 0),
            allocatedSize: 0, linkCount: 1, isMountPoint: false, isDataless: false))
    }

    @Test func eachAttributeIsFoundWhenTheOnesBeforeItAreAbsent() {
        let onlyInode = PackedRecord(device: nil, objectType: nil, flags: nil, fileID: 42,
                                     linkCount: nil, allocatedSize: nil)
        let onlySize = PackedRecord(device: nil, objectType: nil, flags: nil, fileID: nil,
                                    linkCount: nil, allocatedSize: 8192)
        let onlyLinks = PackedRecord(device: nil, objectType: nil, flags: nil, fileID: nil,
                                     linkCount: 2, allocatedSize: nil)
        let onlyDevice = PackedRecord(device: 9, objectType: nil, flags: nil, fileID: nil,
                                      linkCount: nil, allocatedSize: nil)

        #expect(decode(onlyInode)?.identity == FileIdentity(device: 0, inode: 42))
        #expect(decode(onlySize)?.allocatedSize == 8192)
        #expect(decode(onlyLinks)?.linkCount == 2)
        #expect(decode(onlyDevice)?.identity == FileIdentity(device: 9, inode: 0))
    }

    // MARK: Entries the kernel could not read

    @Test func unreadableEntryIsReturnedWithItsNameAndNothingElse() {
        #expect(decode(.unreadable(name: "locked", error: EACCES)) == DirectoryEntry(
            name: "locked", kind: .other, identity: FileIdentity(device: 0, inode: 0),
            allocatedSize: 0, linkCount: 1, isMountPoint: false, isDataless: false))
    }

    @Test func errorCodeInFrontDoesNotShiftTheAttributesBehindIt() {
        var record = PackedRecord(name: "a.bin", device: 3, fileID: 9, linkCount: 2, allocatedSize: 4096)
        let plain = decode(record)
        record.error = UInt32(EIO)

        #expect(decode(record) == plain)
        #expect(plain?.identity == FileIdentity(device: 3, inode: 9))
    }

    @Test func recordWithoutANameIsDropped() {
        #expect(decode(PackedRecord(name: nil)) == nil)
        #expect(decode(PackedRecord(error: UInt32(EIO), name: nil)) == nil)
    }

    @Test func attributesOfANamelessRecordAreNotMistakenForAName() {
        // Read as a name reference, device 4 and type 5 would point at five bytes inside the record.
        #expect(decode(PackedRecord(name: nil, device: 4, objectType: VLNK.rawValue)) == nil)
    }

    @Test func recordWithAnEmptyNameIsDropped() {
        #expect(decode(PackedRecord(name: "")) == nil)
        #expect(decode(PackedRecord(name: "abc", nameLength: 0)) == nil)
    }

    // MARK: Damaged records

    @Test func nameEndingExactlyAtTheEndOfTheRecordIsRead() {
        let record = PackedRecord(name: "abc")

        // 68 bytes of fixed fields, then "abc" and its terminator: no padding after the name.
        #expect(record.bytes.count == 72)
        #expect(decode(record)?.name == "abc")
    }

    @Test func nameReachingPastTheEndOfTheRecordIsDropped() {
        #expect(decode(PackedRecord(name: "abc", nameLength: 5)) == nil)
        #expect(decode(PackedRecord(name: "abc", nameOffset: 4096)) == nil)
    }

    @Test func nameStartingBeforeTheRecordIsDropped() {
        #expect(decode(PackedRecord(name: "abc", nameOffset: -4096)) == nil)
        #expect(decode(PackedRecord(name: "abc", nameOffset: -25)) == nil)
    }

    @Test func nameMayStartAtTheVeryFirstByteOfTheRecord() {
        // The reference sits 24 bytes in; pointing it back at the length prefix (72 = "H") reads that byte.
        #expect(decode(PackedRecord(name: "abc", nameOffset: -24, nameLength: 2))?.name == "H")
    }

    @Test(arguments: [0, 3, 4, 23, 24, 31])
    func recordCutShortBeforeItsNameIsDropped(length: Int) {
        let cut = Array(PackedRecord(name: "abc").bytes.prefix(length))

        #expect(cut.withUnsafeBytes { AttributeRecord.entry(from: $0) } == nil)
    }

    // MARK: A buffer of several records

    private func names(in batch: [UInt8], count: Int) -> [String] {
        var entries = [DirectoryEntry(name: "already there", kind: .other,
                                      identity: FileIdentity(device: 0, inode: 0))]
        batch.withUnsafeBytes { AttributeRecord.appendEntries(in: $0, count: count, to: &entries) }
        return entries.map(\.name)
    }

    private let three = [PackedRecord(name: "a"), .directory(name: "a much longer name"),
                         PackedRecord(name: "c", objectType: VLNK.rawValue)]

    @Test func batchYieldsItsRecordsInOrderAfterWhatWasAlreadyRead() {
        var entries: [DirectoryEntry] = []
        PackedRecord.batch(three).withUnsafeBytes {
            AttributeRecord.appendEntries(in: $0, count: 3, to: &entries)
        }

        #expect(entries.map(\.name) == ["a", "a much longer name", "c"])
        #expect(entries.map(\.kind) == [.file, .directory, .other])
        #expect(names(in: PackedRecord.batch(three), count: 3)
            == ["already there", "a", "a much longer name", "c"])
    }

    @Test func onlyTheRecordsTheKernelCountedAreRead() {
        // Whatever lies behind them in the buffer is left over from an earlier, fuller batch.
        #expect(names(in: PackedRecord.batch(three), count: 2) == ["already there", "a", "a much longer name"])
        #expect(names(in: PackedRecord.batch(three), count: 0) == ["already there"])
    }

    @Test func recordWithoutANameIsSkippedAndTheOnesBehindItAreStillRead() {
        let batch = PackedRecord.batch([three[0], PackedRecord(name: nil), three[2]])

        #expect(names(in: batch, count: 3) == ["already there", "a", "c"])
    }

    @Test(arguments: [1, 3, 4, 30])
    func batchCutShortYieldsOnlyItsCompleteRecords(missing: Int) {
        let batch = PackedRecord.batch(three)

        #expect(names(in: Array(batch.dropLast(missing)), count: 3)
            == ["already there", "a", "a much longer name"])
    }

    @Test func emptyBufferYieldsNothingWhateverTheCount() {
        #expect(names(in: [], count: 3) == ["already there"])
    }

    @Test func recordClaimingNoLengthYieldsNothing() {
        #expect(names(in: [0, 0, 0, 0] + PackedRecord.batch(three), count: 3) == ["already there"])
    }

    // MARK: The request

    @Test func requestAsksForExactlyTheAttributesTheDecoderReads() {
        // Mask values straight from <sys/attr.h>: returned attrs, error, file id, flags, type, device, name;
        // mount status for directories; link count and allocated size for files.
        let request = AttributeRecord.request

        #expect(request.bitmapcount == 5)
        #expect(request.commonattr == 0xA204_000B)
        #expect(request.volattr == 0)
        #expect(request.dirattr == 0x0000_0004)
        #expect(request.fileattr == 0x0000_0005)
        #expect(request.forkattr == 0)
    }
}

/// A scratch directory that exists for the length of one test.
private func withTemporaryDirectory(_ body: (String) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("BulkDirectoryReaderTests-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(atPath: directory) }
    try body(directory)
}

/// The oracle: what lstat(2) says about a path.
private func status(of path: String) throws -> stat {
    var status = stat()
    try #require(lstat(path, &status) == 0, "lstat \(path): errno \(errno)")
    return status
}

/// Creates an empty file under exactly these name bytes. Foundation would decompose "é" on the way down.
private func createEmptyFile(at path: String) throws {
    let descriptor = open(path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
    try #require(descriptor >= 0, "create \(path): errno \(errno)")
    close(descriptor)
}

private func identity(from status: stat) -> FileIdentity {
    FileIdentity(device: status.st_dev, inode: status.st_ino)
}

/// The oracle: the entry a listing should hold for something lstat(2) describes this way.
private func expectedEntry(named name: String, describedBy status: stat) -> DirectoryEntry {
    let type = status.st_mode & S_IFMT
    let kind: DirectoryEntry.Kind = type == S_IFDIR ? .directory : type == S_IFREG ? .file : .other
    return DirectoryEntry(
        name: name, kind: kind, identity: identity(from: status),
        allocatedSize: kind == .directory ? 0 : Int64(status.st_blocks) * 512,
        linkCount: kind == .directory ? 1 : Int(status.st_nlink),
        isMountPoint: false, isDataless: false)
}

/// Nests directories under `root` until the innermost one's path is longer than PATH_MAX, hands that path
/// to `body`, then removes them again. Works through descriptors: no call takes such a path whole.
private func withDirectoryBeyondPathMax(under root: String, _ body: (String) throws -> Void) throws {
    let component = String(repeating: "d", count: 200)
    var parents: [Int32] = []
    defer {
        for parent in parents.reversed() {
            unlinkat(parent, component, AT_REMOVEDIR)
            close(parent)
        }
    }
    var path = root
    while path.utf8.count <= Int(PATH_MAX) {
        let parent = parents.last.map { openat($0, component, O_RDONLY | O_DIRECTORY) }
            ?? open(root, O_RDONLY | O_DIRECTORY)
        try #require(parent >= 0, "open level \(parents.count): errno \(errno)")
        parents.append(parent)
        try #require(mkdirat(parent, component, 0o700) == 0, "mkdirat: errno \(errno)")
        path += "/" + component
    }
    try body(path)
}

/// The reader against a real directory, checked against lstat and Foundation.
struct BulkDirectoryReaderTests {
    private let reader = BulkDirectoryReader()

    private func entriesByName(at directory: String) throws -> [String: DirectoryEntry] {
        let entries = try reader.entries(ofDirectoryAt: directory)
        return Dictionary(entries.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }

    @Test(arguments: [0, 1, 4096, 1_500_000])
    func regularFileReportsItsAllocatedSizeAndIdentity(size: Int) throws {
        try withTemporaryDirectory { directory in
            let path = directory + "/data.bin"
            let data = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 8) })
            try data.write(to: URL(fileURLWithPath: path))

            let entries = try reader.entries(ofDirectoryAt: directory)

            let expected = try status(of: path)
            let foundation = try URL(fileURLWithPath: path)
                .resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize
            #expect(entries == [DirectoryEntry(
                name: "data.bin", kind: .file, identity: identity(from: expected),
                allocatedSize: Int64(expected.st_blocks) * 512, linkCount: 1,
                isMountPoint: false, isDataless: false)])
            #expect(entries.first.map { Int($0.allocatedSize) } == foundation)
            #expect(size == 0 || (entries.first?.allocatedSize ?? 0) >= Int64(size))
        }
    }

    @Test func subdirectoryIsADirectoryWithNoSizeOfItsOwn() throws {
        try withTemporaryDirectory { directory in
            let path = directory + "/sub"
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
            try Data(count: 10_000).write(to: URL(fileURLWithPath: path + "/inside.bin"))

            let entries = try reader.entries(ofDirectoryAt: directory)

            let own = try status(of: path)
            #expect(entries == [DirectoryEntry(
                name: "sub", kind: .directory, identity: identity(from: own),
                allocatedSize: 0, linkCount: 1, isMountPoint: false, isDataless: false)])
        }
    }

    @Test func hardLinksShareAnIdentityAndReportTheirLinkCount() throws {
        try withTemporaryDirectory { directory in
            try Data(count: 5000).write(to: URL(fileURLWithPath: directory + "/first"))
            try FileManager.default.linkItem(atPath: directory + "/first", toPath: directory + "/second")
            try Data(count: 5000).write(to: URL(fileURLWithPath: directory + "/alone"))

            let entries = try entriesByName(at: directory)
            let first = try #require(entries["first"])
            let second = try #require(entries["second"])

            #expect(first.linkCount == 2)
            #expect(second.linkCount == 2)
            #expect(first.identity == second.identity)
            let own = try status(of: directory + "/first")
            #expect(first.identity == identity(from: own))
            #expect(entries["alone"]?.linkCount == 1)
            #expect(entries["alone"]?.identity != first.identity)
        }
    }

    @Test func symlinksAreReportedAsThemselvesAndNotFollowed() throws {
        try withTemporaryDirectory { directory in
            try FileManager.default.createDirectory(atPath: directory + "/dir", withIntermediateDirectories: false)
            try Data(count: 100_000).write(to: URL(fileURLWithPath: directory + "/file"))
            try FileManager.default.createSymbolicLink(atPath: directory + "/to-dir", withDestinationPath: "dir")
            try FileManager.default.createSymbolicLink(atPath: directory + "/to-file", withDestinationPath: "file")

            let entries = try entriesByName(at: directory)

            for link in ["to-dir", "to-file"] {
                let own = try status(of: directory + "/" + link)
                #expect(entries[link] == DirectoryEntry(
                    name: link, kind: .other, identity: identity(from: own),
                    allocatedSize: Int64(own.st_blocks) * 512, linkCount: 1,
                    isMountPoint: false, isDataless: false))
            }
            #expect(entries["to-file"]?.identity != entries["file"]?.identity)
            #expect(entries["to-dir"]?.identity != entries["dir"]?.identity)
        }
    }

    @Test func namesComeBackByteForByte() throws {
        let names = ["Фото и видео", "🎬 кино 👨‍👩‍👧", "name with  spaces ", String(repeating: "x", count: 250),
                     ".hidden", "\u{E9}-precomposed", "e\u{301}-decomposed", "Йод"]
        try withTemporaryDirectory { directory in
            for name in names {
                try createEmptyFile(at: directory + "/" + name)
            }

            let listed = try reader.entries(ofDirectoryAt: directory).map { Array($0.name.utf8) }

            #expect(listed.sorted { $0.lexicographicallyPrecedes($1) }
                == names.map { Array($0.utf8) }.sorted { $0.lexicographicallyPrecedes($1) })
        }
    }

    @Test func largeDirectoryIsListedCompletelyAndWithoutRepeats() throws {
        let names = (0..<5000).map { "file-\($0)-with-a-reasonably-long-name.dat" }
        try withTemporaryDirectory { directory in
            for name in names {
                try createEmptyFile(at: directory + "/" + name)
            }

            let listed = try reader.entries(ofDirectoryAt: directory)

            #expect(listed.map(\.name).sorted() == names.sorted())
            #expect(Set(listed.map(\.identity)).count == 5000)
            #expect(listed.allSatisfy { $0.kind == .file })
        }
    }

    @Test func everyEntryOfALargeMixedDirectoryAgreesWithLstat() throws {
        // Five kinds of entry and names of every length up to 245 bytes: records of many sizes,
        // so the batches break at places a directory of look-alike files never reaches.
        try withTemporaryDirectory { directory in
            var names: [String] = []
            for index in 0..<1500 {
                let name = "\(index)-" + String(repeating: "n", count: index % 241)
                let path = directory + "/" + name
                switch index % 5 {
                case 0: try createEmptyFile(at: path)
                case 1: try Data(count: index * 13).write(to: URL(fileURLWithPath: path))
                case 2: try #require(mkdir(path, 0o700) == 0)
                case 3: try #require(symlink("0-", path) == 0)
                default: try #require(mkfifo(path, 0o600) == 0)
                }
                names.append(name)
            }

            let listed = try reader.entries(ofDirectoryAt: directory)

            let expected = try names.map { try expectedEntry(named: $0, describedBy: status(of: directory + "/" + $0)) }
            #expect(listed.count == 1500)
            #expect(listed.sorted { $0.name < $1.name } == expected.sorted { $0.name < $1.name })
            #expect(Set(listed.map(\.kind)) == [.file, .directory, .other])
        }
    }

    @Test func sparseFileReportsWhatItOccupiesNotItsLength() throws {
        try withTemporaryDirectory { directory in
            let path = directory + "/sparse.bin"
            try createEmptyFile(at: path)
            try #require(truncate(path, 50_000_000) == 0)

            let entries = try reader.entries(ofDirectoryAt: directory)

            let own = try status(of: path)
            try #require(own.st_size == 50_000_000)
            #expect(entries.map(\.allocatedSize) == [Int64(own.st_blocks) * 512])
            #expect((entries.first?.allocatedSize ?? .max) < 50_000_000)
        }
    }

    @Test func readersOnSeveralThreadsDoNotDisturbOneAnother() throws {
        let names = (0..<1500).map { "file-\($0)-with-a-reasonably-long-name.dat" }
        try withTemporaryDirectory { directory in
            for name in names {
                try createEmptyFile(at: directory + "/" + name)
            }
            let expected = names.sorted()
            let reader = reader
            let wrongListings = Mutex(0)

            DispatchQueue.concurrentPerform(iterations: 8) { _ in
                for _ in 0..<25 {
                    let listed = try? reader.entries(ofDirectoryAt: directory).map(\.name).sorted()
                    if listed != expected { wrongListings.withLock { $0 += 1 } }
                }
            }

            #expect(wrongListings.withLock { $0 } == 0)
        }
    }

    @Test func emptyDirectoryHasNoEntriesNotEvenDotAndDotDot() throws {
        try withTemporaryDirectory { directory in
            let entries = try reader.entries(ofDirectoryAt: directory)

            #expect(entries == [])
        }
    }

    @Test func dotAndDotDotAreNotListed() throws {
        try withTemporaryDirectory { directory in
            try FileManager.default.createDirectory(atPath: directory + "/sub", withIntermediateDirectories: false)
            try Data().write(to: URL(fileURLWithPath: directory + "/file"))

            let entries = try reader.entries(ofDirectoryAt: directory)

            #expect(entries.map(\.name).sorted() == ["file", "sub"])
        }
    }

    // MARK: Failures

    /// A directory holding one file, with the given permission bits for the length of `body`.
    private func withDirectory(mode: mode_t, _ body: (String) throws -> Void) throws {
        try withTemporaryDirectory { parent in
            let directory = parent + "/restricted"
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)
            try createEmptyFile(at: directory + "/inside")
            try #require(chmod(directory, mode) == 0)
            defer { chmod(directory, 0o700) }
            try body(directory)
        }
    }

    @Test(.enabled(if: getuid() != 0, "root is not held back by permission bits"))
    func directoryWithoutAnyPermissionFailsWithAPermissionError() throws {
        try withDirectory(mode: 0o000) { directory in
            let error = #expect(throws: DirectoryReadError.self) {
                try reader.entries(ofDirectoryAt: directory)
            }

            #expect(error == DirectoryReadError(code: EACCES))
            #expect(error?.isPermissionDenied == true)
        }
    }

    @Test(.enabled(if: getuid() != 0, "root is not held back by permission bits"))
    func directoryThatOpensButCannotBeSearchedFailsWithAPermissionError() throws {
        // Read without search permission: open(2) succeeds and getattrlistbulk(2) is the call that fails.
        try withDirectory(mode: 0o400) { directory in
            #expect(throws: DirectoryReadError(code: EACCES)) {
                try reader.entries(ofDirectoryAt: directory)
            }
        }
    }

    @Test func missingDirectoryFailsWithNoSuchFile() throws {
        try withTemporaryDirectory { directory in
            let error = #expect(throws: DirectoryReadError.self) {
                try reader.entries(ofDirectoryAt: directory + "/missing")
            }

            #expect(error == DirectoryReadError(code: ENOENT))
            #expect(error?.isPermissionDenied == false)
        }
    }

    @Test func regularFileIsNotADirectory() throws {
        try withTemporaryDirectory { directory in
            try createEmptyFile(at: directory + "/file")

            #expect(throws: DirectoryReadError(code: ENOTDIR)) {
                try reader.entries(ofDirectoryAt: directory + "/file")
            }
        }
    }

    @Test func fifoIsRefusedWithoutWaitingForSomeoneToWriteToIt() throws {
        // Opened as an ordinary file, a FIFO with no writer blocks the caller for good. Should the reader
        // ever block here, the rescuer opens the writing end after a while, so the test fails instead of hanging.
        try withTemporaryDirectory { directory in
            let pipe = directory + "/pipe"
            try #require(mkfifo(pipe, 0o600) == 0)
            let wasRescued = Mutex(false)
            let rescuer = DispatchWorkItem {
                wasRescued.withLock { $0 = true }
                close(open(pipe, O_WRONLY | O_NONBLOCK))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: rescuer)
            defer { rescuer.cancel() }

            #expect(throws: DirectoryReadError(code: ENOTDIR)) {
                try reader.entries(ofDirectoryAt: pipe)
            }
            #expect(!wasRescued.withLock { $0 })
        }
    }

    @Test func symlinkToADirectoryIsNotFollowed() throws {
        try withTemporaryDirectory { directory in
            try FileManager.default.createDirectory(atPath: directory + "/real", withIntermediateDirectories: false)
            try createEmptyFile(at: directory + "/real/inside")
            try FileManager.default.createSymbolicLink(atPath: directory + "/link", withDestinationPath: "real")

            // With O_DIRECTORY and O_NOFOLLOW together macOS answers ENOTDIR, not ELOOP: the link is no directory.
            #expect(throws: DirectoryReadError(code: ENOTDIR)) {
                try reader.entries(ofDirectoryAt: directory + "/link")
            }
        }
    }

    @Test func directoryWhosePathIsLongerThanPathMaxCannotBeReached() throws {
        // A limit of handing the reader whole paths, pinned so that lifting it is a deliberate change.
        try withTemporaryDirectory { root in
            try withDirectoryBeyondPathMax(under: root) { path in
                let error = #expect(throws: DirectoryReadError.self) {
                    try reader.entries(ofDirectoryAt: path)
                }

                #expect(error == DirectoryReadError(code: ENAMETOOLONG))
                #expect(error?.isPermissionDenied == false)
            }
        }
    }

    /// The number the next opened descriptor gets: the lowest one free. It climbs when descriptors leak.
    private func lowestFreeDescriptor() throws -> Int32 {
        let descriptor = open("/dev/null", O_RDONLY)
        try #require(descriptor >= 0)
        close(descriptor)
        return descriptor
    }

    @Test func descriptorIsClosedAfterEveryRead() throws {
        try withTemporaryDirectory { directory in
            try createEmptyFile(at: directory + "/file")
            let before = try lowestFreeDescriptor()

            for _ in 0..<2000 { _ = try reader.entries(ofDirectoryAt: directory) }

            // Other tests running in this process open a few descriptors of their own, never thousands.
            #expect(try lowestFreeDescriptor() < before + 500)
        }
    }

    @Test func descriptorIsClosedWhenReadingFailsAfterTheOpen() throws {
        try withDirectory(mode: 0o400) { directory in
            let before = try lowestFreeDescriptor()

            for _ in 0..<2000 { _ = try? reader.entries(ofDirectoryAt: directory) }

            #expect(try lowestFreeDescriptor() < before + 500)
        }
    }

    @Test(arguments: [(EPERM, true), (EACCES, true), (0, false), (ENOENT, false), (ENOMEM, false),
                      (EFAULT, false), (ELOOP, false), (ENOTDIR, false), (EIO, false)])
    func onlyEPERMAndEACCESArePermissionErrors(code: Int32, expected: Bool) {
        #expect(DirectoryReadError(code: code).isPermissionDenied == expected)
    }

    // MARK: Identity of the directory itself

    @Test func identityOfADirectoryIsItsDeviceAndInode() throws {
        try withTemporaryDirectory { directory in
            let own = try status(of: directory)

            let found = try reader.identity(ofDirectoryAt: directory)

            #expect(found == identity(from: own))
            #expect(found.inode != 0)
        }
    }

    @Test func twoDirectoriesReportDifferentIdentities() throws {
        try withTemporaryDirectory { directory in
            try FileManager.default.createDirectory(atPath: directory + "/a", withIntermediateDirectories: false)
            try FileManager.default.createDirectory(atPath: directory + "/b", withIntermediateDirectories: false)

            let a = try reader.listing(ofDirectoryAt: directory + "/a").identity
            let b = try reader.listing(ofDirectoryAt: directory + "/b").identity

            #expect(a != b)
            #expect(a == identity(from: try status(of: directory + "/a")))
            #expect(b == identity(from: try status(of: directory + "/b")))
        }
    }

    @Test func identityOfAnOrdinaryDirectoryMatchesWhatItsParentListsForIt() throws {
        try withTemporaryDirectory { directory in
            try FileManager.default.createDirectory(atPath: directory + "/sub", withIntermediateDirectories: false)

            let listed = try reader.entries(ofDirectoryAt: directory).first?.identity
            let own = try reader.identity(ofDirectoryAt: directory + "/sub")

            #expect(listed == own)
        }
    }
}

/// The two halves of a listing, for tests that look at one of them.
private extension DirectoryReader {
    func entries(ofDirectoryAt path: String) throws -> [DirectoryEntry] {
        try listing(ofDirectoryAt: path).entries
    }

    func identity(ofDirectoryAt path: String) throws -> FileIdentity {
        try listing(ofDirectoryAt: path).identity
    }
}

/// How often the signal handler in `materializationIsOffWhileTheReaderIsInsideADirectory` found the thread
/// it interrupted forbidden to materialize. A signal handler can capture nothing, so it counts in a global.
private let interruptionsWithMaterializationOff = Atomic(0)

/// Reading must never pull a cloud-only file or folder down: the calling thread's I/O policy says so.
struct DatalessMaterializationTests {
    private static let off = IOPOL_MATERIALIZE_DATALESS_FILES_OFF
    private static let on = IOPOL_MATERIALIZE_DATALESS_FILES_ON

    private func threadPolicy() -> Int32 {
        getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
    }

    /// Runs `body` on a thread that explicitly allows materialization, then puts the thread back.
    private func allowingMaterialization(_ body: () throws -> Void) throws {
        let original = threadPolicy()
        try #require(original != Self.off)
        try #require(setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, Self.on) == 0)
        defer { setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, original) }
        try body()
    }

    @Test func materializationIsOffDuringTheWorkAndBackAfterwards() throws {
        try allowingMaterialization {
            let during = try DatalessFiles.withoutMaterializing { threadPolicy() }

            #expect(during == Self.off)
            #expect(threadPolicy() == Self.on)
        }
    }

    @Test func threadWithoutAPolicyOfItsOwnGetsThatBackToo() throws {
        let before = threadPolicy()
        try #require(before == IOPOL_MATERIALIZE_DATALESS_FILES_DEFAULT)

        let during = try DatalessFiles.withoutMaterializing { threadPolicy() }

        #expect(during == Self.off)
        #expect(threadPolicy() == before)
    }

    @Test func policyComesBackWhenTheWorkFails() throws {
        try allowingMaterialization {
            #expect(throws: DirectoryReadError(code: EIO)) {
                try DatalessFiles.withoutMaterializing { throw DirectoryReadError(code: EIO) }
            }
            #expect(threadPolicy() == Self.on)
        }
    }

    @Test func materializationIsOffWhileTheReaderIsInsideADirectory() throws {
        // A test cannot create a dataless file to see whether it gets downloaded. Instead a thread that does
        // nothing but read a directory is interrupted over and over and asked for its policy at that moment.
        try withTemporaryDirectory { directory in
            for index in 0..<2000 {
                try createEmptyFile(at: directory + "/file-\(index)")
            }
            interruptionsWithMaterializationOff.store(0, ordering: .relaxed)
            let previousHandler = signal(SIGUSR1) { _ in
                if getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
                    == IOPOL_MATERIALIZE_DATALESS_FILES_OFF {
                    interruptionsWithMaterializationOff.add(1, ordering: .relaxed)
                }
            }
            defer { signal(SIGUSR1, previousHandler) }
            let readingThread = Mutex<(thread: pthread_t, policyOutsideTheReader: Int32)?>(nil)
            let keepsReading = Atomic(true)
            let started = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)

            Thread.detachNewThread {
                // A thread started from a dispatch worker inherits its mask, and that mask holds signals back.
                var interruption = sigset_t()
                sigemptyset(&interruption)
                sigaddset(&interruption, SIGUSR1)
                pthread_sigmask(SIG_UNBLOCK, &interruption, nil)
                readingThread.withLock { $0 = (pthread_self(), threadPolicy()) }
                started.signal()
                while keepsReading.load(ordering: .relaxed) {
                    _ = try? BulkDirectoryReader().entries(ofDirectoryAt: directory)
                }
                finished.signal()
            }
            started.wait()
            let reading = readingThread.withLock { $0 }
            for _ in 0..<300 {
                _ = reading.map { pthread_kill($0.thread, SIGUSR1) }
                usleep(200)
            }
            keepsReading.store(false, ordering: .relaxed)
            finished.wait()

            #expect(reading?.policyOutsideTheReader == IOPOL_MATERIALIZE_DATALESS_FILES_DEFAULT)
            #expect(interruptionsWithMaterializationOff.load(ordering: .relaxed) > 0)
        }
    }

    @Test func readerLeavesTheThreadsPolicyAsItFoundIt() throws {
        try allowingMaterialization {
            _ = try BulkDirectoryReader().entries(ofDirectoryAt: NSTemporaryDirectory())
            #expect(threadPolicy() == Self.on)

            #expect(throws: DirectoryReadError.self) {
                try BulkDirectoryReader().entries(ofDirectoryAt: NSTemporaryDirectory() + "/missing-\(UUID())")
            }
            #expect(threadPolicy() == Self.on)
        }
    }
}

/// Read-only checks against this Mac's own volume layout. Each is skipped where the path does not exist.
struct SystemLayoutTests {
    private let reader = BulkDirectoryReader()

    private static func exists(_ paths: String...) -> Bool {
        paths.allSatisfy(FileManager.default.fileExists(atPath:))
    }

    /// The oracle: a path is a mount point when the file system it lives on is mounted exactly there.
    private func isMounted(at path: String) throws -> Bool {
        var volume = statfs()
        try #require(statfs(path, &volume) == 0, "statfs \(path): errno \(errno)")
        return withUnsafePointer(to: volume.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        } == path
    }

    @Test(.enabled(if: exists("/System/Volumes/Data", "/System/Volumes/VM")))
    func dataAndVMVolumesAreListedAsMountPoints() throws {
        let entries = try reader.entries(ofDirectoryAt: "/System/Volumes")
        let data = try #require(entries.first { $0.name == "Data" })
        let vm = try #require(entries.first { $0.name == "VM" })

        #expect(data.kind == .directory)
        #expect(data.isMountPoint)
        #expect(vm.kind == .directory)
        #expect(vm.isMountPoint)
    }

    @Test(.enabled(if: exists("/System/Volumes")))
    func mountPointFlagAgreesWithStatfsForEverythingUnderSystemVolumes() throws {
        let entries = try reader.entries(ofDirectoryAt: "/System/Volumes")
        try #require(!entries.isEmpty)

        for entry in entries where entry.kind == .directory {
            let mounted = try isMounted(at: "/System/Volumes/" + entry.name)
            #expect(entry.isMountPoint == mounted, "\(entry.name)")
        }
    }

    @Test(.enabled(if: exists("/Users", "/System/Volumes/Data/Users")))
    func usersFirmlinkAndItsTargetOnTheDataVolumeAreTheSameDirectory() throws {
        let throughFirmlink = try reader.identity(ofDirectoryAt: "/Users")
        let onDataVolume = try reader.identity(ofDirectoryAt: "/System/Volumes/Data/Users")

        #expect(throughFirmlink == onDataVolume)
    }

    /// Why the scanner cannot tell an alias from its parent's listing: the root lists the
    /// firmlink under a placeholder, not under the identity of the directory it leads to.
    @Test(.enabled(if: exists("/Users", "/System/Volumes/Data/Users")))
    func rootListsTheUsersFirmlinkUnderAnIdentityThatIsNotTheDirectorysOwn() throws {
        let listed = try #require(try reader.entries(ofDirectoryAt: "/").first { $0.name == "Users" }).identity
        let listedOnDataVolume = try #require(
            try reader.entries(ofDirectoryAt: "/System/Volumes/Data").first { $0.name == "Users" }
        ).identity
        let own = try reader.identity(ofDirectoryAt: "/Users")

        #expect(listed != own)
        #expect(listedOnDataVolume == own)
    }

    @Test(.enabled(if: exists("/System/Volumes/VM")))
    func aMountedVolumeReportsItsOwnDeviceNotTheOneItsMountPointIsListedWith() throws {
        let listed = try #require(try reader.entries(ofDirectoryAt: "/System/Volumes").first { $0.name == "VM" }).identity
        let own = try reader.identity(ofDirectoryAt: "/System/Volumes/VM")
        var status = stat()
        try #require(lstat("/System/Volumes/VM", &status) == 0)

        #expect(own == FileIdentity(device: status.st_dev, inode: status.st_ino))
        #expect(listed.device != own.device)
    }

    @Test(.enabled(if: exists("/Users")))
    func rootListsUsersAsAnOrdinaryDirectory() throws {
        let users = try #require(try reader.entries(ofDirectoryAt: "/").first { $0.name == "Users" })

        #expect(users.kind == .directory)
        #expect(!users.isMountPoint)
        #expect(!users.isDataless)
    }
}
