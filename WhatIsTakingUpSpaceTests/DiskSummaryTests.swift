import Testing
@testable import WhatIsTakingUpSpace

struct DiskSummaryTests {
    /// A 1000-byte volume with 400 bytes free, 150 of them only "available" once purgeable data goes.
    private let space = VolumeSpace(capacity: 1000, free: 400, availableForImportantUsage: 550)

    private func summary(found: Int64, wholeVolume: Bool = true) -> DiskSummary {
        DiskSummary(space: space, foundInFiles: found, coversWholeVolume: wholeVolume)
    }

    // MARK: Numbers

    @Test func usedIsCapacityMinusFree() {
        let summary = summary(found: 250)

        #expect(summary.capacity == 1000)
        #expect(summary.free == 400)
        #expect(summary.foundInFiles == 250)
        #expect(summary.used == 600)
    }

    @Test func unaccountedIsTheUsedSpaceTheScanDidNotFind() {
        #expect(summary(found: 250).unaccounted == 350)
        #expect(summary(found: 599).unaccounted == 1)
    }

    @Test func unaccountedIsZeroWhenTheScanFoundExactlyTheUsedSpace() {
        #expect(summary(found: 600).unaccounted == 0)
    }

    @Test func unaccountedIsClampedAtZeroWhenClonesMakeTheScanExceedUsedSpace() {
        #expect(summary(found: 601).unaccounted == 0)
        #expect(summary(found: 5000).unaccounted == 0)
    }

    @Test func unaccountedIsUnknownForAFolderScan() {
        #expect(summary(found: 250, wholeVolume: false).unaccounted == nil)
        #expect(summary(found: 5000, wholeVolume: false).unaccounted == nil)
    }

    @Test func purgeableIsWhatImportantUsageCouldReclaimBeyondFree() {
        #expect(summary(found: 250).purgeable == 150)
        #expect(purgeable(free: 400, importantUsage: 401) == 1)
    }

    @Test func purgeableIsZeroWhenImportantUsageEqualsFree() {
        #expect(purgeable(free: 400, importantUsage: 400) == 0)
    }

    @Test func purgeableIsClampedAtZeroWhenImportantUsageIsBelowFree() {
        #expect(purgeable(free: 400, importantUsage: 399) == 0)
        // What the system reports for a volume that has no such notion.
        #expect(purgeable(free: 400, importantUsage: 0) == 0)
    }

    private func purgeable(free: Int64, importantUsage: Int64) -> Int64 {
        let space = VolumeSpace(capacity: 1000, free: free, availableForImportantUsage: importantUsage)
        return DiskSummary(space: space, foundInFiles: 0, coversWholeVolume: true).purgeable
    }

    /// A file system may claim more free space than it has room for; `VolumeSpace` saturates such a report.
    @Test func unaccountedSurvivesAReportOfMoreFreeSpaceThanCapacity() {
        let space = VolumeSpace(capacity: 0, free: .max, availableForImportantUsage: .max)

        #expect(DiskSummary(space: space, foundInFiles: 2, coversWholeVolume: true).unaccounted == 0)
        #expect(DiskSummary(space: space, foundInFiles: .max, coversWholeVolume: true).unaccounted == 0)
    }

    @Test func anEmptyVolumeWhereNothingWasFoundHasNothingUnaccounted() {
        let empty = VolumeSpace(capacity: 1000, free: 1000, availableForImportantUsage: 1000)

        #expect(DiskSummary(space: empty, foundInFiles: 0, coversWholeVolume: true).unaccounted == 0)
    }

    @Test func summariesOfTheSameInputsAreEqual() {
        #expect(summary(found: 250) == summary(found: 250))
        #expect(summary(found: 250) != summary(found: 251))
        #expect(summary(found: 250) != summary(found: 250, wholeVolume: false))
    }

    // MARK: Segmented bar

    private typealias Fractions = DiskSummary.Fractions

    private func fractions(capacity: Int64, free: Int64, found: Int64, wholeVolume: Bool = true) -> Fractions {
        let space = VolumeSpace(capacity: capacity, free: free, availableForImportantUsage: free)
        return DiskSummary(space: space, foundInFiles: found, coversWholeVolume: wholeVolume).fractions
    }

    @Test func fractionsSplitTheCapacityIntoFoundUnaccountedAndFree() {
        // 250 found + 350 unaccounted + 400 free = 1000.
        #expect(summary(found: 250).fractions == Fractions(found: 0.25, unaccounted: 0.35, free: 0.4))
    }

    @Test func unaccountedSegmentVanishesWhenTheScanFoundExactlyTheUsedSpace() {
        #expect(summary(found: 600).fractions == Fractions(found: 0.6, unaccounted: 0, free: 0.4))
    }

    @Test func foundSegmentIsClampedToTheUsedSpace() {
        #expect(summary(found: 601).fractions == Fractions(found: 0.6, unaccounted: 0, free: 0.4))
        #expect(summary(found: 5000).fractions == Fractions(found: 0.6, unaccounted: 0, free: 0.4))
    }

    @Test func folderScanLeavesTheUnaccountedSegmentEmpty() {
        #expect(summary(found: 250, wholeVolume: false).fractions == Fractions(found: 0.25, unaccounted: 0, free: 0.4))
        #expect(summary(found: 5000, wholeVolume: false).fractions == Fractions(found: 0.6, unaccounted: 0, free: 0.4))
    }

    @Test func fractionsAreAllZeroWithoutACapacity() {
        let empty = Fractions(found: 0, unaccounted: 0, free: 0)

        #expect(fractions(capacity: 0, free: 0, found: 0) == empty)
        #expect(fractions(capacity: 0, free: 0, found: 10) == empty)
        #expect(fractions(capacity: 0, free: 10, found: 10, wholeVolume: false) == empty)
        #expect(fractions(capacity: -1000, free: -400, found: 250) == empty)
        #expect(fractions(capacity: -1, free: 0, found: 0) == empty)
    }

    @Test func smallestCapacityStillFillsTheBar() {
        #expect(fractions(capacity: 1, free: 0, found: 1) == Fractions(found: 1, unaccounted: 0, free: 0))
        #expect(fractions(capacity: 1, free: 0, found: 0) == Fractions(found: 0, unaccounted: 1, free: 0))
        #expect(fractions(capacity: 1, free: 1, found: 0) == Fractions(found: 0, unaccounted: 0, free: 1))
    }

    @Test func freeSegmentStaysWithinTheBarWhenTheReportIsInconsistent() {
        #expect(fractions(capacity: 1000, free: 1001, found: 250) == Fractions(found: 0, unaccounted: 0, free: 1))
        #expect(fractions(capacity: 1000, free: -1, found: 250) == Fractions(found: 0.25, unaccounted: 0.75, free: 0))
    }

    @Test func negativeFoundSizeTakesNoSpaceOnTheBar() {
        #expect(fractions(capacity: 1000, free: 400, found: -1) == Fractions(found: 0, unaccounted: 0.6, free: 0.4))
        #expect(fractions(capacity: 1000, free: 400, found: -1, wholeVolume: false) == Fractions(found: 0, unaccounted: 0, free: 0.4))
    }

    @Test func roundingNeverPushesTheSegmentsPastTheEndOfTheBar() {
        // As doubles, 9/28 + 18/28 + 1/28 is one ulp above 1.
        let fractions = fractions(capacity: 28, free: 1, found: 9)
        let naiveFree = 1.0 / 28.0

        #expect(fractions.found == 9.0 / 28.0)
        #expect(fractions.unaccounted == 18.0 / 28.0)
        #expect(fractions.found + fractions.unaccounted + naiveFree > 1)
        #expect(fractions.found + fractions.unaccounted + fractions.free <= 1)
        #expect(fractions.free <= naiveFree)
        #expect(fractions.free > naiveFree - 1e-15)
    }

    /// Every segment is a share of the bar and, drawn one after another, they end within it.
    private func fitsTheBar(_ fractions: Fractions) -> Bool {
        let segments = [fractions.found, fractions.unaccounted, fractions.free]
        return segments.allSatisfy((0...1).contains) && fractions.found + fractions.unaccounted + fractions.free <= 1
    }

    @Test func everySegmentIsAShareAndTogetherTheyNeverExceedTheBar() {
        var violations: [String] = []
        for capacity in Int64(1)...40 {
            for free in -1...capacity + 1 {
                for found in -1...capacity + 1 {
                    for wholeVolume in [true, false] {
                        let fractions = fractions(capacity: capacity, free: free, found: found, wholeVolume: wholeVolume)
                        let isFull = fractions.found + fractions.unaccounted + fractions.free > 1 - 1e-12
                        if !fitsTheBar(fractions) || (wholeVolume && !isFull) {
                            violations.append("capacity \(capacity) free \(free) found \(found) whole \(wholeVolume): \(fractions)")
                        }
                    }
                }
            }
        }

        #expect(violations.isEmpty, "\(violations.count) violations, first: \(violations.first ?? "")")
    }

    // MARK: Beyond the precision of a Double

    /// Above 2^53 bytes a Double no longer holds every byte count, so two rounded shares can already pass 1.
    @Test func segmentsStayWithinTheBarWhenByteCountsExceedDoublePrecision() {
        let capacity: Int64 = 9_546_415_112_830_057
        let fractions = fractions(capacity: capacity, free: 0, found: 74)

        #expect(fractions.found == 74 / Double(capacity))
        #expect(fractions.found + Double(capacity - 74) / Double(capacity) > 1)
        #expect(fractions.unaccounted == 1 - fractions.found)
        #expect(fractions.free == 0)
    }

    @Test func everySegmentIsAShareOnVolumesTooLargeForExactDoubles() {
        let capacities: [Int64] = [.max, .max - 1, (1 << 62) + 1, (1 << 60) + 12345, (1 << 53) + 1, 9_546_415_112_830_057]
        var violations: [String] = []
        for capacity in capacities {
            for free in [0, 1, 4096, 1 << 30, capacity / 3] {
                for found in stride(from: Int64(0), through: 20_000, by: 37) + [capacity / 3, capacity / 2, capacity] {
                    let fractions = fractions(capacity: capacity, free: free, found: found)
                    if !fitsTheBar(fractions) {
                        violations.append("capacity \(capacity) free \(free) found \(found): \(fractions)")
                    }
                }
            }
        }

        #expect(violations.isEmpty, "\(violations.count) violations, first: \(violations.first ?? "")")
    }
}
