import Testing
@testable import WhatIsTakingUpSpace

struct FindingsReportTests {
    private typealias Entry = FindingsReport.Entry
    private typealias Item = FindingsReport.Item
    private typealias Remainder = FindingsReport.Remainder

    /// With a threshold of 1000: Caches answers for 1700 of its own, big.dmg and Xcode.app for themselves.
    private let tree = FileTree(.dir("/", [
        .dir("Library", [
            .dir("Caches", [
                .dir("render", [.file("frames.bin", 900)]),
                .file("index.db", 500),
                .dir("Fonts.app", [.file("glyphs", 200)]),
                .dir("empty", []),
                .file("big.dmg", 1000),
            ], loose: LooseFiles(count: 40, bytes: 100)),
            .dir("Mail", [], flags: .unreadable),
        ]),
        .dir("Applications", [
            .dir("Xcode.app", [.file("Xcode", 3000)]),
        ]),
        .dir("Secrets", [], flags: .unreadable),
    ]))

    private let summary = DiskSummary(
        space: VolumeSpace(capacity: 10_000, free: 2000, availableForImportantUsage: 2500),
        foundInFiles: 5700,
        coversWholeVolume: true
    )

    private func isPackage(_ name: String) -> Bool { name.hasSuffix(".app") }

    private func report(
        of tree: FileTree? = nil,
        threshold: Int64 = 1000,
        limits: FindingsReport.Limits = .standard
    ) -> FindingsReport {
        let tree = tree ?? self.tree
        return tree.findingsReport(
            summary: summary,
            unreadable: tree.nodes(flagged: .unreadable),
            threshold: threshold,
            limits: limits,
            isPackage: isPackage
        )
    }

    @Test func carriesWhatWasScannedAndHow() {
        let report = report()

        #expect(report.rootPath == "/")
        #expect(report.summary == summary)
        #expect(report.threshold == 1000)
    }

    @Test func entriesAreTheCulpritsLargestOwnSizeFirst() {
        let entries = report().entries

        #expect(entries.map(\.path) == ["/Applications/Xcode.app", "/Library/Caches", "/Library/Caches/big.dmg"])
        #expect(entries.map(\.kind) == [.package, .folder, .file])
        #expect(entries.map(\.ownSize) == [3000, 1700, 1000])
        #expect(entries.map(\.totalSize) == [3000, 2700, 1000])
    }

    @Test func aFolderListsWhatMakesUpItsOwnSizeLargestFirst() throws {
        let caches = try #require(report().entries.first { $0.path == "/Library/Caches" })

        #expect(caches.items == [
            Item(name: "render", kind: .folder, size: 900),
            Item(name: "index.db", kind: .file, size: 500),
            Item(name: "Fonts.app", kind: .package, size: 200),
        ])
        #expect(caches.looseFiles == LooseFiles(count: 40, bytes: 100))
        #expect(caches.otherItems == .none)
    }

    @Test func somethingThatReachesTheThresholdIsAnEntryNotAnItem() throws {
        let caches = try #require(report().entries.first { $0.path == "/Library/Caches" })

        #expect(!caches.items.map(\.name).contains("big.dmg"))
    }

    @Test func somethingThatTakesNoSpaceIsNotAnItem() throws {
        let caches = try #require(report().entries.first { $0.path == "/Library/Caches" })

        #expect(!caches.items.map(\.name).contains("empty"))
    }

    @Test func evenASingleByteIsAnItem() throws {
        let box = FileTree(.dir("/box", [.file("a", 40), .file("b", 30), .file("dot", 1)]))

        let entry = try #require(report(of: box, threshold: 50).entries.first)

        #expect(entry.path == "/box")
        #expect(entry.items.map(\.name) == ["a", "b", "dot"])
    }

    @Test func filesAndPackagesListNothingInside() throws {
        let report = report()
        let xcode = try #require(report.entries.first { $0.path == "/Applications/Xcode.app" })
        let image = try #require(report.entries.first { $0.path == "/Library/Caches/big.dmg" })

        #expect(xcode == Entry(path: "/Applications/Xcode.app", kind: .package, ownSize: 3000, totalSize: 3000))
        #expect(image == Entry(path: "/Library/Caches/big.dmg", kind: .file, ownSize: 1000, totalSize: 1000))
    }

    @Test func itemsBeyondTheLimitAreSummedUp() throws {
        let report = report(limits: FindingsReport.Limits(entries: 10, itemsPerEntry: 1, unreadable: 10))
        let caches = try #require(report.entries.first { $0.path == "/Library/Caches" })

        #expect(caches.items.map(\.name) == ["render"])
        #expect(caches.otherItems == Remainder(count: 2, bytes: 700))
        #expect(caches.looseFiles == LooseFiles(count: 40, bytes: 100))
    }

    @Test func entriesBeyondTheLimitAreSummedUpByOwnSize() {
        let report = report(limits: FindingsReport.Limits(entries: 1, itemsPerEntry: 10, unreadable: 10))

        #expect(report.entries.map(\.path) == ["/Applications/Xcode.app"])
        #expect(report.otherEntries == Remainder(count: 2, bytes: 2700))
    }

    @Test func nothingIsLeftOutWhenEverythingFits() {
        let report = report()

        #expect(report.otherEntries == .none)
        #expect(report.otherUnreadable == 0)
    }

    @Test func foldersWithoutAccessAreNamedByPath() {
        #expect(report().unreadable == ["/Library/Mail", "/Secrets"])
    }

    @Test func foldersWithoutAccessBeyondTheLimitAreCounted() {
        let report = report(limits: FindingsReport.Limits(entries: 10, itemsPerEntry: 10, unreadable: 1))

        #expect(report.unreadable == ["/Library/Mail"])
        #expect(report.otherUnreadable == 1)
    }

    @Test func aThresholdNothingReachesGivesNoEntries() {
        let report = report(threshold: 1_000_000)

        #expect(report.entries.isEmpty)
        #expect(report.otherEntries == .none)
    }

    @Test func aThresholdOfZeroIsTakenLikeTheCulpritsTakeIt() {
        let flat = FileTree(.dir("/box", [.file("a", 5), .dir("hollow", [])]))

        let report = report(of: flat, threshold: 0)

        #expect(report.entries == [Entry(path: "/box/a", kind: .file, ownSize: 5, totalSize: 5)])
    }
}
