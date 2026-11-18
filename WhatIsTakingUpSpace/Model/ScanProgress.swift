/// How far a running scan has got.
nonisolated struct ScanProgress: Equatable, Sendable {
    /// Files counted so far, including the small ones folded into their directory.
    var filesSeen: Int
    /// Bytes on disk of the files counted so far.
    var bytesSeen: Int64
    /// The directory that was read most recently.
    var currentPath: String
    /// A guess at what `bytesSeen` will reach: what the same place held last time, or the volume's
    /// used space. `nil` when there is nothing to go by.
    var expectedBytes: Int64? = nil

    /// How much of the scan is done, 0...1, as far as the guess goes; `nil` without one.
    /// A scan that finds more than was expected stays at 1 until it ends.
    var fraction: Double? {
        guard let expectedBytes, expectedBytes > 0 else { return nil }
        return min(1, Double(bytesSeen) / Double(expectedBytes))
    }
}
