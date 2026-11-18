import Foundation
import System
import Testing
@testable import WhatIsTakingUpSpace

struct VolumeSpaceTests {
    // MARK: Interpreting the report

    @Test func bytesAreBlockCountsTimesTheBlockSize() {
        let space = VolumeSpace(blockSize: 4096, totalBlocks: 1000, freeBlocks: 250, importantUsage: 2_000_000)

        #expect(space == VolumeSpace(capacity: 4_096_000, free: 1_024_000, availableForImportantUsage: 2_000_000))
    }

    @Test func importantUsageFallsBackToFreeWhenTheSystemDoesNotReportIt() {
        let space = VolumeSpace(blockSize: 512, totalBlocks: 100, freeBlocks: 40, importantUsage: nil)

        #expect(space == VolumeSpace(capacity: 51_200, free: 20_480, availableForImportantUsage: 20_480))
    }

    @Test func aReportedImportantUsageOfZeroIsKept() {
        let space = VolumeSpace(blockSize: 512, totalBlocks: 100, freeBlocks: 40, importantUsage: 0)

        #expect(space.availableForImportantUsage == 0)
    }

    @Test func absurdBlockCountsSaturateInsteadOfOverflowing() {
        let beyondUInt64 = VolumeSpace(blockSize: 4096, totalBlocks: .max, freeBlocks: .max / 2, importantUsage: nil)
        // 2^63 blocks of 2 bytes is 2^64 bytes, which wraps around to exactly zero.
        let wrappingToZero = VolumeSpace(blockSize: 2, totalBlocks: 1 << 63, freeBlocks: 7, importantUsage: nil)
        let beyondInt64 = VolumeSpace(blockSize: 1, totalBlocks: UInt64(Int64.max) + 1, freeBlocks: 7, importantUsage: nil)
        let largestExact = VolumeSpace(blockSize: 1, totalBlocks: UInt64(Int64.max), freeBlocks: 7, importantUsage: nil)

        #expect(beyondUInt64.capacity == .max)
        #expect(beyondUInt64.free == .max)
        #expect(wrappingToZero.capacity == .max)
        #expect(wrappingToZero.free == 14)
        #expect(beyondInt64.capacity == .max)
        #expect(beyondInt64.free == 7)
        #expect(largestExact.capacity == .max)
    }

    // MARK: Reading

    @Test func rootVolumeReportIsConsistent() throws {
        let space = try VolumeSpace.read(forPath: "/")

        #expect(space.capacity > 0)
        #expect(space.free >= 0)
        #expect(space.free <= space.capacity)
        #expect(space.availableForImportantUsage >= 0)
    }

    @Test func rootVolumeAgreesWithWhatFoundationReports() throws {
        let values = try URL(fileURLWithPath: "/").resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ])
        let total = Int64(try #require(values.volumeTotalCapacity))
        let available = Int64(try #require(values.volumeAvailableCapacity))
        let important = try #require(values.volumeAvailableCapacityForImportantUsage)

        let space = try VolumeSpace.read(forPath: "/")

        // Other processes write while the test runs, so the free numbers drift between the two reads.
        let tolerance = total / 100
        #expect(abs(space.capacity - total) <= tolerance)
        #expect(abs(space.free - available) <= tolerance)
        #expect(abs(space.availableForImportantUsage - important) <= tolerance)
    }

    @Test func aFolderReportsTheVolumeItLivesOn() throws {
        #expect(try VolumeSpace.read(forPath: "/usr/bin").capacity == VolumeSpace.read(forPath: "/").capacity)
    }

    @Test func readingAMissingPathThrows() {
        let missing = NSTemporaryDirectory() + "no-such-volume-\(UUID().uuidString)/inside"

        #expect(throws: Errno.noSuchFileOrDirectory) {
            try VolumeSpace.read(forPath: missing)
        }
    }

    @Test func readingAnEmptyPathThrows() {
        #expect(throws: Errno.noSuchFileOrDirectory) {
            try VolumeSpace.read(forPath: "")
        }
    }
}
