import Foundation

/// A directory could not be opened or read.
nonisolated struct DirectoryReadError: Error, Equatable {
    /// The `errno` the failed system call left.
    var code: Int32

    /// The directory exists but this process is not allowed to list it.
    var isPermissionDenied: Bool { code == EPERM || code == EACCES }
}

nonisolated extension DirectoryReadError: LocalizedError {
    /// The system's own words for the error code, e.g. "Operation not permitted".
    var errorDescription: String? { String(cString: strerror(code)) }
}

/// Lists directories with getattrlistbulk(2): one open and a few calls per directory, every entry's
/// attributes included, no system call per entry. Failures are thrown as `DirectoryReadError`.
nonisolated struct BulkDirectoryReader: DirectoryReader {
    /// A `path` whose last component is a symlink is refused, not followed.
    func listing(ofDirectoryAt path: String) throws -> DirectoryListing {
        try DatalessFiles.withoutMaterializing { try Self.listing(ofDirectoryAt: path) }
    }

    /// Room for several hundred entries per call; the longest possible record is under 1 KB.
    private static let bufferSize = 64 * 1024

    private static func listing(ofDirectoryAt path: String) throws -> DirectoryListing {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw DirectoryReadError(code: errno) }
        defer { close(descriptor) }
        let identity = try identity(ofDirectory: descriptor)
        let entries = try withUnsafeTemporaryAllocation(byteCount: bufferSize, alignment: 8) { buffer in
            try entries(ofDirectory: descriptor, readingThrough: buffer)
        }
        return DirectoryListing(identity: identity, entries: entries)
    }

    /// Asked of the open descriptor, not of the path: behind a firmlink or a mount point this is
    /// the directory that was reached, which the parent's listing does not describe.
    private static func identity(ofDirectory descriptor: Int32) throws -> FileIdentity {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw DirectoryReadError(code: errno) }
        return FileIdentity(device: status.st_dev, inode: status.st_ino)
    }

    private static func entries(ofDirectory descriptor: Int32,
                                readingThrough buffer: UnsafeMutableRawBufferPointer) throws -> [DirectoryEntry] {
        var request = AttributeRecord.request
        var entries: [DirectoryEntry] = []
        while true {
            let count = getattrlistbulk(descriptor, &request, buffer.baseAddress, buffer.count, 0)
            guard count >= 0 else { throw DirectoryReadError(code: errno) }
            guard count > 0 else { return entries }
            AttributeRecord.appendEntries(in: UnsafeRawBufferPointer(buffer), count: Int(count), to: &entries)
        }
    }
}

/// Files and folders whose contents live in the cloud ("dataless"). Touching one normally makes the
/// system download it; a disk-usage scan must never do that.
nonisolated enum DatalessFiles {
    /// Runs `body` with the calling thread forbidden to materialize dataless files, then gives the
    /// thread its previous policy back. `body` must stay on the calling thread.
    static func withoutMaterializing<Result>(_ body: () throws -> Result) throws -> Result {
        let policy = IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES
        let previous = getiopolicy_np(policy, IOPOL_SCOPE_THREAD)
        guard previous >= 0,
              setiopolicy_np(policy, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0
        else { throw DirectoryReadError(code: errno) }
        defer { setiopolicy_np(policy, IOPOL_SCOPE_THREAD, previous) }
        return try body()
    }
}

/// One directory entry as getattrlistbulk(2) packs it: a length prefix, the set of attributes that follow
/// (`ATTR_CMN_RETURNED_ATTRS`), the attributes themselves in mask order on 4-byte boundaries, then the name.
/// Without `FSOPT_PACK_INVAL_ATTRS` the kernel packs exactly the attributes named in the returned set,
/// so the set alone tells where every field is.
nonisolated enum AttributeRecord {
    /// What to ask getattrlistbulk for: every attribute `Fields` knows how to read, and no other.
    static var request: attrlist {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_ERROR)
            | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_DEVID) | attrgroup_t(ATTR_CMN_OBJTYPE)
            | attrgroup_t(ATTR_CMN_FLAGS) | attrgroup_t(ATTR_CMN_FILEID)
        request.dirattr = attrgroup_t(ATTR_DIR_MOUNTSTATUS)
        request.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_ALLOCSIZE)
        return request
    }

    /// Decodes the `count` records one getattrlistbulk call left at the front of `batch`.
    /// Stops early at a record that does not fit in the buffer.
    static func appendEntries(in batch: UnsafeRawBufferPointer, count: Int, to entries: inout [DirectoryEntry]) {
        var cursor = Cursor(bytes: batch, offset: 0)
        for _ in 0..<count {
            guard let record = cursor.nextRecord() else { return }
            if let entry = entry(from: record) { entries.append(entry) }
        }
    }

    /// Decodes one record. `nil` when the record carries no name: there is nothing to call the entry.
    static func entry(from record: UnsafeRawBufferPointer) -> DirectoryEntry? {
        Fields(record: record).flatMap(entry(from:))
    }

    private static func entry(from fields: Fields) -> DirectoryEntry? {
        guard let name = fields.name else { return nil }
        let kind = kind(ofObjectType: fields.objectType)
        return DirectoryEntry(
            name: name,
            kind: kind,
            identity: FileIdentity(device: fields.device, inode: fields.fileID),
            allocatedSize: kind == .directory ? 0 : fields.allocatedSize,
            linkCount: Int(fields.linkCount),
            isMountPoint: fields.mountStatus.hasAny(of: DIR_MNTSTATUS_MNTPOINT | DIR_MNTSTATUS_TRIGGER),
            isDataless: fields.flags.hasAny(of: SF_DATALESS))
    }

    private static func kind(ofObjectType objectType: UInt32) -> DirectoryEntry.Kind {
        switch objectType {
        case VDIR.rawValue: .directory
        case VREG.rawValue: .file
        default: .other
        }
    }
}

/// The attributes of one record. An attribute the kernel left out holds its neutral value: no name,
/// no type (`VNON`), one link, zero for the rest.
nonisolated private struct Fields {
    var name: String?
    var device: Int32
    var objectType: UInt32
    var flags: UInt32
    var fileID: UInt64
    var mountStatus: UInt32
    var linkCount: UInt32
    var allocatedSize: Int64

    init?(record: UnsafeRawBufferPointer) {
        var cursor = Cursor(bytes: record, offset: MemoryLayout<UInt32>.size)
        guard let returned = cursor.next(attribute_set_t.self) else { return nil }
        let common = returned.commonattr, directory = returned.dirattr, file = returned.fileattr

        // An entry the kernel could not read comes with its error code and name only; the code is not kept.
        let _: UInt32 = cursor.next(if: common.hasAny(of: ATTR_CMN_ERROR), else: 0)
        name = cursor.nextName(if: common.hasAny(of: ATTR_CMN_NAME))
        device = cursor.next(if: common.hasAny(of: ATTR_CMN_DEVID), else: 0)
        objectType = cursor.next(if: common.hasAny(of: ATTR_CMN_OBJTYPE), else: VNON.rawValue)
        flags = cursor.next(if: common.hasAny(of: ATTR_CMN_FLAGS), else: 0)
        fileID = cursor.next(if: common.hasAny(of: ATTR_CMN_FILEID), else: 0)
        mountStatus = cursor.next(if: directory.hasAny(of: ATTR_DIR_MOUNTSTATUS), else: 0)
        linkCount = cursor.next(if: file.hasAny(of: ATTR_FILE_LINKCOUNT), else: 1)
        allocatedSize = cursor.next(if: file.hasAny(of: ATTR_FILE_ALLOCSIZE), else: 0)
    }
}

nonisolated private extension UInt32 {
    /// Whether any of the given C flag bits is set.
    func hasAny(of bits: Int32) -> Bool {
        self & UInt32(bits) != 0
    }
}

/// Reads consecutive unaligned fields out of a record.
nonisolated private struct Cursor {
    let bytes: UnsafeRawBufferPointer
    var offset: Int

    /// The next field, or `nil` when the record ends before it does.
    mutating func next<Field: BitwiseCopyable>(_ type: Field.Type) -> Field? {
        let field = slice(at: offset, count: MemoryLayout<Field>.size)
        offset += MemoryLayout<Field>.size
        return field?.loadUnaligned(as: Field.self)
    }

    /// The next field when the record has it; otherwise `absent`, and the cursor stays where it is.
    mutating func next<Field: BitwiseCopyable>(if present: Bool, else absent: Field) -> Field {
        guard present, let field = next(Field.self) else { return absent }
        return field
    }

    /// The name is stored out of line: an `attrreference_t` gives its offset from the reference itself
    /// and its length including the terminating NUL. An empty name counts as no name.
    mutating func nextName(if present: Bool) -> String? {
        let referenceOffset = offset
        guard present, let reference = next(attrreference_t.self),
              let terminated = slice(at: referenceOffset + Int(reference.attr_dataoffset),
                                     count: Int(reference.attr_length))
        else { return nil }
        let name = terminated.dropLast()
        return name.isEmpty ? nil : String(decoding: name, as: UTF8.self)
    }

    /// The next record of a batch, from its leading length to the start of the record behind it.
    mutating func nextRecord() -> UnsafeRawBufferPointer? {
        let start = offset
        guard let length = next(UInt32.self), let record = slice(at: start, count: Int(length))
        else { return nil }
        offset = start + Int(length)
        return record
    }

    /// `count` bytes starting at `start`, or `nil` unless all of them lie inside the record.
    private func slice(at start: Int, count: Int) -> UnsafeRawBufferPointer? {
        let range = start..<start + count
        guard range == range.clamped(to: bytes.indices) else { return nil }
        return UnsafeRawBufferPointer(rebasing: bytes[range])
    }
}
