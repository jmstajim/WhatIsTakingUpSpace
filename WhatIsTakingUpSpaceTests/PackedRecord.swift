import Darwin

/// Test helper: the bytes getattrlistbulk(2) hands back for one directory entry, built by hand from the
/// layout in getattrlist(2) - length prefix, the set of returned attributes, each present attribute in
/// mask order on 4-byte boundaries, then the name the name reference points at.
/// A `nil` attribute is left out of the record and out of the returned set, as the kernel does.
struct PackedRecord {
    var error: UInt32?
    var name: String? = "entry"
    var device: Int32? = 7
    var objectType: UInt32? = VREG.rawValue
    var flags: UInt32? = 0
    var fileID: UInt64? = 1
    var mountStatus: UInt32?
    var linkCount: UInt32? = 1
    var allocatedSize: Int64? = 0
    /// Where the name reference points, relative to the reference itself. `nil` means "at the real name".
    var nameOffset: Int32?
    /// The length the name reference claims. `nil` means the real one, terminator included.
    var nameLength: UInt32?

    static func directory(name: String = "entry", mountStatus: UInt32 = 0) -> PackedRecord {
        PackedRecord(name: name, objectType: VDIR.rawValue, mountStatus: mountStatus,
                     linkCount: nil, allocatedSize: nil)
    }

    /// What the kernel packs when it could not read an entry's attributes: the error and the name only.
    static func unreadable(name: String, error: Int32) -> PackedRecord {
        PackedRecord(error: UInt32(error), name: name, device: nil, objectType: nil, flags: nil,
                     fileID: nil, mountStatus: nil, linkCount: nil, allocatedSize: nil)
    }

    var bytes: [UInt8] {
        let nameBytes = Array((name ?? "").utf8) + [0]
        let nameReferenceSize = name == nil ? 0 : 8
        var fields = ByteWriter()
        error.map { fields.put($0) }
        let nameReferenceAt = Self.headerSize + fields.bytes.count
        fields.bytes += [UInt8](repeating: 0, count: nameReferenceSize)
        device.map { fields.put($0) }
        objectType.map { fields.put($0) }
        flags.map { fields.put($0) }
        fileID.map { fields.put($0) }
        mountStatus.map { fields.put($0) }
        linkCount.map { fields.put($0) }
        allocatedSize.map { fields.put($0) }
        // The kernel leaves one unused 4-byte slot before the variable-length data (seen on macOS 27.2).
        fields.put(UInt32(0))
        let nameAt = Self.headerSize + fields.bytes.count

        if name != nil {
            var reference = ByteWriter()
            reference.put(nameOffset ?? Int32(nameAt - nameReferenceAt))
            reference.put(nameLength ?? UInt32(nameBytes.count))
            let slot = nameReferenceAt - Self.headerSize
            fields.bytes.replaceSubrange(slot..<slot + 8, with: reference.bytes)
            fields.bytes += nameBytes
        }
        fields.pad(to: 8, after: Self.headerSize)

        var record = ByteWriter()
        record.put(UInt32(Self.headerSize + fields.bytes.count))
        returnedAttributes.forEach { record.put($0) }
        return record.bytes + fields.bytes
    }

    /// Several records back to back, the way one getattrlistbulk call fills its buffer.
    static func batch(_ records: [PackedRecord]) -> [UInt8] {
        records.flatMap(\.bytes)
    }

    /// Length prefix plus `attribute_set_t`.
    private static let headerSize = 4 + 20

    /// `attribute_set_t`: common, volume, directory, file, fork.
    private var returnedAttributes: [UInt32] {
        var common = UInt32(ATTR_CMN_RETURNED_ATTRS)
        if error != nil { common |= UInt32(ATTR_CMN_ERROR) }
        if name != nil { common |= UInt32(ATTR_CMN_NAME) }
        if device != nil { common |= UInt32(ATTR_CMN_DEVID) }
        if objectType != nil { common |= UInt32(ATTR_CMN_OBJTYPE) }
        if flags != nil { common |= UInt32(ATTR_CMN_FLAGS) }
        if fileID != nil { common |= UInt32(ATTR_CMN_FILEID) }
        let directory = mountStatus == nil ? 0 : UInt32(ATTR_DIR_MOUNTSTATUS)
        var file: UInt32 = 0
        if linkCount != nil { file |= UInt32(ATTR_FILE_LINKCOUNT) }
        if allocatedSize != nil { file |= UInt32(ATTR_FILE_ALLOCSIZE) }
        return [common, 0, directory, file, 0]
    }
}

private struct ByteWriter {
    var bytes: [UInt8] = []

    mutating func put<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value) { bytes.append(contentsOf: $0) }
    }

    mutating func pad(to alignment: Int, after prefix: Int) {
        while (prefix + bytes.count) % alignment != 0 { bytes.append(0) }
    }
}
