import Foundation
import Testing
@testable import WhatIsTakingUpSpace

struct FindingsReportMarkdownTests {
    private typealias Entry = FindingsReport.Entry
    private typealias Item = FindingsReport.Item
    private typealias Remainder = FindingsReport.Remainder

    private static let gigabyte: Int64 = 1_000_000_000

    private let wholeDisk = DiskSummary(
        space: VolumeSpace(capacity: 994 * gigabyte, free: 18 * gigabyte, availableForImportantUsage: 70 * gigabyte),
        foundInFiles: 925 * gigabyte,
        coversWholeVolume: true
    )

    private func report(
        rootPath: String = "/",
        summary: DiskSummary? = nil,
        threshold: Int64 = gigabyte,
        entries: [Entry] = [],
        otherEntries: Remainder = .none,
        unreadable: [String] = [],
        otherUnreadable: Int = 0
    ) -> FindingsReport {
        FindingsReport(
            rootPath: rootPath,
            summary: summary ?? wholeDisk,
            threshold: threshold,
            entries: entries,
            otherEntries: otherEntries,
            unreadable: unreadable,
            otherUnreadable: otherUnreadable
        )
    }

    private func markdown(_ report: FindingsReport, timeZone: TimeZone = .gmt) throws -> String {
        let date = try Date("2026-11-19T22:30:00Z", strategy: .iso8601)
        return report.markdown(madeAt: date, in: timeZone, on: "macOS 27.2")
    }

    private func lines(_ report: FindingsReport) throws -> [String] {
        try markdown(report).components(separatedBy: "\n")
    }

    @Test func theWholeReportReadsLikeThis() throws {
        let report = report(
            entries: [
                Entry(
                    path: "/private/var/path_manager",
                    kind: .folder,
                    ownSize: 331 * Self.gigabyte,
                    totalSize: 331 * Self.gigabyte,
                    items: [
                        Item(name: "xrtmp__a", kind: .folder, size: 900_000_000),
                        Item(name: "trace.bin", kind: .file, size: 500_000_000),
                        Item(name: "Viewer.app", kind: .package, size: 200_000_000),
                    ],
                    otherItems: Remainder(count: 76, bytes: 329 * Self.gigabyte),
                    looseFiles: LooseFiles(count: 48_210, bytes: 400_000_000)
                ),
                Entry(
                    path: "/Users/ada/Library",
                    kind: .folder,
                    ownSize: 1_700_000_000,
                    totalSize: 12 * Self.gigabyte
                ),
                Entry(path: "/Applications/Xcode.app", kind: .package, ownSize: 3 * Self.gigabyte, totalSize: 3 * Self.gigabyte),
                Entry(path: "/Users/ada/Downloads/big.dmg", kind: .file, ownSize: Self.gigabyte, totalSize: Self.gigabyte),
            ],
            otherEntries: Remainder(count: 12, bytes: 20 * Self.gigabyte),
            unreadable: ["/Library/Mail", "/Secrets"],
            otherUnreadable: 3
        )

        #expect(try markdown(report) == """
        # Disk usage report for `/`

        Made by What Is Taking Up Space on 2026-11-19 at 22:30, macOS 27.2.
        Sizes are space taken on disk, in decimal units (1 GB is 1000 MB). Nothing here was checked for being safe to delete.

        ## Disk

        - Found in files: 925 GB
        - Not found in files: 51 GB (local snapshots, purgeable data, folders without access)
        - Volume capacity: 994 GB
        - Volume used: 976 GB
        - Volume free: 18 GB
        - Purgeable, freed by the system on demand: 52 GB

        ## Largest items, 1 GB and above

        The items do not overlap. A folder's own size leaves out anything directly inside it that reaches 1 GB, because that has an item of its own. Under a folder is the largest of what makes up its own size.

        ### 1. `/private/var/path_manager`

        Folder, 331 GB.

        - 900 MB: `xrtmp__a` (folder)
        - 500 MB: `trace.bin` (file)
        - 200 MB: `Viewer.app` (package)
        - 329 GB: 76 more items
        - 400 MB: 48,210 files under 1 MB each

        ### 2. `/Users/ada/Library`

        Folder, 1.7 GB of its own, 12 GB in total.

        ### 3. `/Applications/Xcode.app`

        Package, 3 GB.

        ### 4. `/Users/ada/Downloads/big.dmg`

        File, 1 GB.

        Not listed: 12 smaller items, 20 GB of own size together.

        ## Folders without access

        What is inside them is not counted in this report.

        - `/Library/Mail`
        - `/Secrets`
        - and 3 more

        """)
    }

    @Test func aFolderScanSaysNothingAboutSpaceNotFound() throws {
        var summary = wholeDisk
        summary.coversWholeVolume = false

        let lines = try lines(report(rootPath: "/Users/ada/Downloads", summary: summary))

        #expect(lines.first == "# Disk usage report for `/Users/ada/Downloads`")
        #expect(lines.contains("- Found in files: 925 GB"))
        #expect(!lines.contains { $0.hasPrefix("- Not found in files") })
        #expect(lines.contains("- Volume capacity: 994 GB"))
    }

    @Test func theTimeIsToldInTheGivenTimeZone() throws {
        let threeHoursAhead = try #require(TimeZone(secondsFromGMT: 3 * 3600))

        let text = try markdown(report(), timeZone: threeHoursAhead)

        #expect(text.contains("on 2026-11-20 at 01:30, macOS 27.2."))
    }

    @Test func theThresholdIsNamedWhereverItMatters() throws {
        let lines = try lines(report(
            threshold: 100_000_000,
            entries: [Entry(path: "/a", kind: .file, ownSize: 200_000_000, totalSize: 200_000_000)]
        ))

        #expect(lines.contains("## Largest items, 100 MB and above"))
        #expect(lines.contains { $0.contains("that reaches 100 MB, because") })
    }

    @Test func whenNothingReachesTheThresholdItSaysSo() throws {
        let lines = try lines(report())

        #expect(lines.contains("Nothing in the scan reaches 1 GB."))
        #expect(!lines.contains { $0.hasPrefix("The items do not overlap") })
        #expect(!lines.contains { $0.hasPrefix("Not listed") })
    }

    @Test func aFolderWithNothingToListHasNoList() throws {
        let lines = try lines(report(entries: [
            Entry(path: "/a", kind: .folder, ownSize: 2 * Self.gigabyte, totalSize: 2 * Self.gigabyte),
        ]))

        #expect(!lines.contains { $0.contains("more item") })
        #expect(!lines.contains { $0.contains("under 1 MB") })
        #expect(lines.suffix(4) == ["### 1. `/a`", "", "Folder, 2 GB.", ""])
    }

    @Test func ownAndTotalSizesThatReadTheSameAreToldOnce() throws {
        let lines = try lines(report(entries: [
            Entry(path: "/a", kind: .folder, ownSize: 2 * Self.gigabyte, totalSize: 2 * Self.gigabyte + 300_000),
        ]))

        #expect(lines.contains("Folder, 2 GB."))
    }

    @Test func oneOfSomethingIsWordedInTheSingular() throws {
        let lines = try lines(report(
            entries: [Entry(
                path: "/a",
                kind: .folder,
                ownSize: 2 * Self.gigabyte,
                totalSize: 2 * Self.gigabyte,
                otherItems: Remainder(count: 1, bytes: 5_000_000),
                looseFiles: LooseFiles(count: 1, bytes: 300_000)
            )],
            otherEntries: Remainder(count: 1, bytes: 3 * Self.gigabyte)
        ))

        #expect(lines.contains("- 5 MB: 1 more item"))
        #expect(lines.contains("- 300 kB: 1 file under 1 MB"))
        #expect(lines.contains("Not listed: 1 smaller item, 3 GB of own size."))
    }

    @Test func withoutUnreadableFoldersThereIsNoSuchSection() throws {
        let lines = try lines(report())

        #expect(!lines.contains("## Folders without access"))
    }

    @Test func aShortListOfUnreadableFoldersHasNoAndMoreLine() throws {
        let lines = try lines(report(unreadable: ["/Secrets"]))

        #expect(lines.suffix(2) == ["- `/Secrets`", ""])
    }

    @Test func evenOneUnreadableFolderLeftOutIsMentioned() throws {
        let lines = try lines(report(unreadable: ["/Secrets"], otherUnreadable: 1))

        #expect(lines.suffix(3) == ["- `/Secrets`", "- and 1 more", ""])
    }

    @Test func aVolumeFullerThanTheSystemAdmitsHasNothingPurgeable() throws {
        var summary = wholeDisk
        summary.space.availableForImportantUsage = 18 * Self.gigabyte

        let lines = try lines(report(summary: summary))

        #expect(lines.contains("- Purgeable, freed by the system on demand: 0 bytes"))
    }
}
