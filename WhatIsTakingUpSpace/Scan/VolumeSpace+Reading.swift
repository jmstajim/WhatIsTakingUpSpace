import Foundation
import System

nonisolated extension VolumeSpace {
    /// Reads the space of the volume that holds `path`. Throws `Errno` when the path cannot be examined.
    ///
    /// Capacity and free space come from `statfs`: `f_blocks` and `f_bfree` are counted in `f_bsize` units
    /// and are what `df` prints. `f_bfree` rather than `f_bavail`, because "used" must not include blocks
    /// that are free but reserved for the superuser.
    static func read(forPath path: String) throws -> VolumeSpace {
        var report = statfs()
        guard statfs(path, &report) == 0 else { throw Errno(rawValue: errno) }
        return VolumeSpace(
            blockSize: report.f_bsize,
            totalBlocks: report.f_blocks,
            freeBlocks: report.f_bfree,
            importantUsage: importantUsage(forPath: path)
        )
    }

    /// `nil` when the volume has no such value or it cannot be read; the caller falls back to free space.
    private static func importantUsage(forPath path: String) -> Int64? {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
