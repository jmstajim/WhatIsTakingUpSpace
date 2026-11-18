/// The numbers shown above the scan results.
///
/// Part of the used space is invisible to a file scan: APFS local snapshots, purgeable data, other
/// volumes of the same container, folders the app may not read. `unaccounted` says how much.
nonisolated struct DiskSummary: Equatable, Sendable {
    var space: VolumeSpace
    /// Bytes on disk of everything the scan saw.
    var foundInFiles: Int64
    /// False when only a folder was scanned; then the scan says nothing about the rest of the volume.
    var coversWholeVolume: Bool

    var capacity: Int64 { space.capacity }
    var free: Int64 { space.free }
    var used: Int64 { capacity - free }

    /// Used space the scan did not find. Unknown for a folder scan.
    ///
    /// Never negative: the scan counts an APFS clone once per copy, so it can find more than is used.
    /// `used` is floored first because a report of more free space than capacity makes it negative,
    /// by up to `Int64.max`, and subtracting from that would overflow.
    var unaccounted: Int64? { coversWholeVolume ? max(0, max(0, used) - foundInFiles) : nil }

    /// Space the system would free on demand, on top of what is free already.
    var purgeable: Int64 { max(0, space.availableForImportantUsage - free) }
}

nonisolated extension DiskSummary {
    /// Shares of the capacity for a segmented bar, drawn in this order.
    /// Each lies within 0...1 and `found + unaccounted + free` never exceeds 1.
    nonisolated struct Fractions: Equatable, Sendable {
        var found: Double
        var unaccounted: Double
        var free: Double

        static let zero = Fractions(found: 0, unaccounted: 0, free: 0)
    }

    var fractions: Fractions {
        guard capacity > 0 else { return .zero }
        let freeBytes = min(max(free, 0), capacity)
        let usedBytes = capacity - freeBytes
        let foundBytes = min(max(foundInFiles, 0), usedBytes)
        let unaccountedBytes = coversWholeVolume ? usedBytes - foundBytes : 0

        // The byte counts add up to at most the capacity, but their rounded quotients can add up to
        // one ulp above 1: three of them on any volume (9/28 + 18/28 + 1/28 does), two of them once the
        // counts pass 2^53 and no longer convert exactly. So each segment takes no more than what the
        // ones before it leave.
        let found = share(of: foundBytes)
        let unaccounted = min(share(of: unaccountedBytes), 1 - found)
        let free = min(share(of: freeBytes), 1 - (found + unaccounted))
        return Fractions(found: found, unaccounted: unaccounted, free: free)
    }

    private func share(of bytes: Int64) -> Double {
        Double(bytes) / Double(capacity)
    }
}
