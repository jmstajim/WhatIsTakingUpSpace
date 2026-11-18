import Darwin

/// The file systems mounted right now.
nonisolated enum MountTable {
    /// Every mount the kernel lists, without waiting on file systems that are slow to answer.
    /// Empty when the table cannot be read.
    static func current() -> [Mount] {
        var records: UnsafeMutablePointer<statfs>?
        let count = getmntinfo_r_np(&records, MNT_NOWAIT)
        defer { free(records) }
        return UnsafeBufferPointer(start: records, count: Int(count)).map(Mount.init)
    }
}

nonisolated extension Mount {
    /// Reads the three names out of the kernel's fixed-size record.
    init(_ record: statfs) {
        self.init(path: Self.string(inField: record.f_mntonname),
                  source: Self.string(inField: record.f_mntfromname),
                  fileSystem: Self.string(inField: record.f_fstypename))
    }

    /// The C string held in a fixed-size `char` array: the bytes up to the first NUL, or the whole field.
    private static func string<Field>(inField field: Field) -> String {
        withUnsafeBytes(of: field) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}
