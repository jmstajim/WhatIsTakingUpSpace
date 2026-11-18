import Synchronization
@testable import WhatIsTakingUpSpace

/// An in-memory file system for scanner tests: directory path -> listing, or an error.
/// Remembers, thread-safely, everything it was asked for.
final class FakeDirectoryReader: DirectoryReader {
    struct NoSuchDirectory: Error, Equatable {
        let path: String
    }

    private struct Activity {
        var listed: [String] = []
        var readsInFlight = 0
        var peakReadsInFlight = 0
    }

    private let identities: [String: FileIdentity]
    private let listings: [String: [DirectoryEntry]]
    private let failures: [String: any Error]
    private let whileListing: @Sendable (String, FakeDirectoryReader) -> Void
    private let activity = Mutex(Activity())

    /// - Parameters:
    ///   - identities: the identity a directory reports once opened, for the paths where that differs
    ///     from what the parent lists (a firmlink, a mount point) and for the scan root. Any other
    ///     directory reports the identity its parent's listing gives it.
    ///   - listings: the entries of each directory; any other path throws `NoSuchDirectory`.
    ///   - failures: paths whose listing throws the given error instead.
    ///   - whileListing: runs inside every `listing(ofDirectoryAt:)` call, while the read counts as in flight.
    init(
        identities: [String: FileIdentity] = ["/": FileIdentity(device: 1, inode: 2)],
        listings: [String: [DirectoryEntry]],
        failures: [String: any Error] = [:],
        whileListing: @escaping @Sendable (String, FakeDirectoryReader) -> Void = { _, _ in }
    ) {
        self.identities = identities
        self.listings = listings
        self.failures = failures
        self.whileListing = whileListing
    }

    /// Every path whose entries were requested, in the order the requests arrived.
    var listedPaths: [String] { activity.withLock(\.listed) }
    var readsInFlight: Int { activity.withLock(\.readsInFlight) }
    var peakReadsInFlight: Int { activity.withLock(\.peakReadsInFlight) }

    func listing(ofDirectoryAt path: String) throws -> DirectoryListing {
        activity.withLock {
            $0.listed.append(path)
            $0.readsInFlight += 1
            $0.peakReadsInFlight = max($0.peakReadsInFlight, $0.readsInFlight)
        }
        defer { activity.withLock { $0.readsInFlight -= 1 } }
        whileListing(path, self)
        if let failure = failures[path] { throw failure }
        guard let entries = listings[path], let identity = identities[path] ?? listedIdentity(of: path)
        else { throw NoSuchDirectory(path: path) }
        return DirectoryListing(identity: identity, entries: entries)
    }

    /// What the parent's listing says about the directory at `path`.
    private func listedIdentity(of path: String) -> FileIdentity? {
        guard let slash = path.lastIndex(of: "/") else { return nil }
        let parent = slash == path.startIndex ? "/" : String(path[..<slash])
        let name = path[path.index(after: slash)...]
        return listings[parent]?.first { $0.name == name }?.identity
    }
}

/// Listing entries for scanner tests.
extension DirectoryEntry {
    static func dir(
        _ name: String,
        _ inode: UInt64,
        device: Int32 = 1,
        mountPoint: Bool = false,
        dataless: Bool = false
    ) -> DirectoryEntry {
        DirectoryEntry(
            name: name,
            kind: .directory,
            identity: FileIdentity(device: device, inode: inode),
            isMountPoint: mountPoint,
            isDataless: dataless
        )
    }

    /// Files share inode 0 unless a test cares: a file with a single link is never deduplicated.
    static func file(_ name: String, _ size: Int64, inode: UInt64 = 0, links: Int = 1) -> DirectoryEntry {
        DirectoryEntry(
            name: name,
            kind: .file,
            identity: FileIdentity(device: 1, inode: inode),
            allocatedSize: size,
            linkCount: links
        )
    }

    /// A symlink, socket or the like.
    static func other(_ name: String, _ size: Int64, inode: UInt64 = 0, links: Int = 1) -> DirectoryEntry {
        var entry = file(name, size, inode: inode, links: links)
        entry.kind = .other
        return entry
    }
}
