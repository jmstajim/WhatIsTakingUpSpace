/// How full a volume is, in bytes, as the operating system reports it.
nonisolated struct VolumeSpace: Equatable, Sendable {
    var capacity: Int64
    var free: Int64
    /// What the system can hand out once it has dropped purgeable data.
    var availableForImportantUsage: Int64
}

nonisolated extension VolumeSpace {
    /// Turns the raw report into bytes.
    /// - Parameter importantUsage: `nil` when the system does not report it; `free` stands in then.
    init(blockSize: UInt32, totalBlocks: UInt64, freeBlocks: UInt64, importantUsage: Int64?) {
        let free = Self.bytes(blocks: freeBlocks, blockSize: blockSize)
        self.init(
            capacity: Self.bytes(blocks: totalBlocks, blockSize: blockSize),
            free: free,
            availableForImportantUsage: importantUsage ?? free
        )
    }

    /// A file system may report any block count; the result saturates rather than trapping.
    private static func bytes(blocks: UInt64, blockSize: UInt32) -> Int64 {
        let (bytes, overflow) = blocks.multipliedReportingOverflow(by: UInt64(blockSize))
        return overflow ? .max : Int64(clamping: bytes)
    }
}
