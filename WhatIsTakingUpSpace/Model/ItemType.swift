import UniformTypeIdentifiers

/// What kind of thing a name stands for, told from the name alone. It picks the icon of an item
/// that is no longer on disk to show its own.
nonisolated enum ItemType {
    /// `name` is the last path component, or a whole path. A directory is a plain folder unless its
    /// name makes it a package; a file with no telling extension is just data.
    static func named(_ name: String, isDirectory: Bool) -> UTType {
        let named = UTType(
            filenameExtension: (name as NSString).pathExtension,
            conformingTo: isDirectory ? .directory : .data
        )
        guard isDirectory else { return named ?? .data }
        return named.flatMap { $0.conforms(to: .package) ? $0 : nil } ?? .folder
    }
}
