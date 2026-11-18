import Testing
@testable import WhatIsTakingUpSpace

struct ScanProgressTests {
    private func progress(seen: Int64, expected: Int64?) -> ScanProgress {
        ScanProgress(filesSeen: 1, bytesSeen: seen, currentPath: "/", expectedBytes: expected)
    }

    @Test func aScanThatDoesNotKnowHowMuchToExpectHasNoFraction() {
        #expect(progress(seen: 500, expected: nil).fraction == nil)
    }

    @Test func theFractionIsWhatWasSeenOfWhatIsExpected() {
        #expect(progress(seen: 0, expected: 2000).fraction == 0)
        #expect(progress(seen: 500, expected: 2000).fraction == 0.25)
        #expect(progress(seen: 2000, expected: 2000).fraction == 1)
    }

    @Test func aScanThatFindsMoreThanExpectedStaysAtTheEnd() {
        #expect(progress(seen: 2001, expected: 2000).fraction == 1)
    }

    @Test func expectingNothingGivesNoFraction() {
        #expect(progress(seen: 0, expected: 0).fraction == nil)
        #expect(progress(seen: 5, expected: 0).fraction == nil)
        #expect(progress(seen: 5, expected: -1).fraction == nil)
    }

    @Test func expectingASingleByteIsStillAnExpectation() {
        #expect(progress(seen: 0, expected: 1).fraction == 0)
        #expect(progress(seen: 1, expected: 1).fraction == 1)
    }

    @Test func aReportExpectsNothingUnlessTold() {
        #expect(ScanProgress(filesSeen: 0, bytesSeen: 0, currentPath: "/").expectedBytes == nil)
    }
}
