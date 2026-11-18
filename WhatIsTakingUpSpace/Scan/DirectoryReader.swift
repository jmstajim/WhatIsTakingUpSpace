import Foundation

/// What makes two paths the same file-system object: the volume's device number and the inode.
nonisolated struct FileIdentity: Hashable, Sendable {
    var device: Int32
    var inode: UInt64
}

/// One item of a directory listing, as the file system reports it. Nothing here is interpreted yet:
/// deciding what to descend into, what to count once and what to fold is the scanner's job.
nonisolated struct DirectoryEntry: Equatable, Sendable {
    nonisolated enum Kind: Equatable, Sendable {
        case directory
        /// A regular file.
        case file
        /// A symlink, socket, device and so on. Never followed or opened.
        case other
    }

    var name: String
    var kind: Kind
    /// For a file: the file itself. For a directory this is only what the parent says about the
    /// name, and it is not always the directory found there: a firmlink (`/Users` on a startup
    /// disk) and a mount point are listed with a placeholder's identity. The identity of the
    /// directory actually reached is `DirectoryListing.identity` of its own listing.
    var identity: FileIdentity
    /// Bytes allocated on disk. Zero for directories.
    var allocatedSize: Int64 = 0
    /// Number of hard links. Above one, the same bytes are reachable under several names.
    var linkCount: Int = 1
    /// The file system says another volume is mounted on this directory (or will be, on access).
    var isMountPoint: Bool = false
    /// The directory's contents live in the cloud; listing it would start a download.
    var isDataless: Bool = false
}

/// The contents of one directory, and which directory it turned out to be.
nonisolated struct DirectoryListing: Equatable, Sendable {
    /// Identity of the directory that was opened. Two paths that lead to the same directory
    /// give the same identity here, whatever their parents list for them.
    var identity: FileIdentity
    var entries: [DirectoryEntry]
}

/// Reads directories one level at a time. The only door between the scanner and the operating system.
nonisolated protocol DirectoryReader: Sendable {
    /// Lists the directory at `path` without descending and without following symlinks.
    /// Throws when the directory cannot be opened or read.
    func listing(ofDirectoryAt path: String) throws -> DirectoryListing
}
