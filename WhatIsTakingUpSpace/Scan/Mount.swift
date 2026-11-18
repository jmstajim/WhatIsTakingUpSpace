/// One mounted file system, as the mount table lists it.
nonisolated struct Mount: Equatable, Sendable {
    /// Where it is mounted, e.g. `/System/Volumes/Data`.
    var path: String
    /// What is mounted, e.g. `/dev/disk3s5`, or `com.apple.TimeMachine.…@/dev/disk3s5` for a snapshot.
    var source: String
    /// File system type name, e.g. `apfs`, `autofs`, `devfs`.
    var fileSystem: String
}
