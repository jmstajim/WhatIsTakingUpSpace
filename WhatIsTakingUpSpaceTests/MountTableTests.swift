import Darwin
import Foundation
import Testing
@testable import WhatIsTakingUpSpace

struct MountTableTests {
    /// A `statfs` record as the kernel fills it: fixed-size, NUL-padded C strings.
    private func record(on path: String, from source: String, type: String) -> statfs {
        var record = statfs()
        withUnsafeMutableBytes(of: &record.f_mntonname) { $0.copyBytes(from: path.utf8) }
        withUnsafeMutableBytes(of: &record.f_mntfromname) { $0.copyBytes(from: source.utf8) }
        withUnsafeMutableBytes(of: &record.f_fstypename) { $0.copyBytes(from: type.utf8) }
        return record
    }

    /// The oracle's own reading of a fixed-size C string field.
    private func cString<Field>(_ field: Field) -> String {
        withUnsafePointer(to: field) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<Field>.size) { String(cString: $0) }
        }
    }

    // MARK: One record

    @Test func mountTakesItsPathSourceAndTypeFromTheRecord() {
        let mount = Mount(record(on: "/System/Volumes/Data", from: "/dev/disk3s5", type: "apfs"))

        #expect(mount == Mount(path: "/System/Volumes/Data", source: "/dev/disk3s5", fileSystem: "apfs"))
    }

    @Test func namesOutsideASCIIAndSnapshotSourcesSurvive() {
        let mount = Mount(record(on: "/Volumes/ada’s Бэкап 💾",
                                 from: "com.apple.TimeMachine.2026-11-19-230809.local@/dev/disk3s5",
                                 type: "apfs"))

        #expect(mount.path == "/Volumes/ada’s Бэкап 💾")
        #expect(mount.source == "com.apple.TimeMachine.2026-11-19-230809.local@/dev/disk3s5")
    }

    @Test func nameFillingItsWholeFieldIsReadToTheEndOfTheField() {
        let sixteen = "0123456789abcdef"
        #expect(MemoryLayout.size(ofValue: statfs().f_fstypename) == 16)

        #expect(Mount(record(on: "/", from: "x", type: sixteen)).fileSystem == sixteen)
    }

    @Test func emptyFieldsBecomeEmptyStrings() {
        #expect(Mount(statfs()) == Mount(path: "", source: "", fileSystem: ""))
    }

    // MARK: The live table

    @Test func rootIsAnAPFSVolumeOnADiskDevice() throws {
        let root = try #require(MountTable.current().first { $0.path == "/" })

        #expect(root.fileSystem == "apfs")
        #expect(root.source.hasPrefix("/dev/disk"))
    }

    @Test func everyMountHasAPathAndNoPathRepeats() {
        let paths = MountTable.current().map(\.path)

        #expect(!paths.isEmpty)
        #expect(paths.allSatisfy { !$0.isEmpty })
        #expect(Set(paths).count == paths.count)
    }

    @Test func tableAgreesWithStatfsAboutEveryVolumeFoundationKnows() throws {
        let volumes = try #require(FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil))
        let table = MountTable.current()
        try #require(!volumes.isEmpty)

        for volume in volumes {
            var expected = statfs()
            try #require(statfs(volume.path, &expected) == 0, "statfs \(volume.path): errno \(errno)")
            let mount = Mount(path: cString(expected.f_mntonname), source: cString(expected.f_mntfromname),
                              fileSystem: cString(expected.f_fstypename))

            #expect(table.contains(mount), "\(volume.path)")
        }
    }
}
