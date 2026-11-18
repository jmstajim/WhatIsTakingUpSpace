import Foundation

/// Tells whether the app has been given Full Disk Access.
///
/// macOS has no API for this. The answer is a heuristic and only advisory: the app is taken to have
/// access when it can open a file that nothing but Full Disk Access unlocks.
nonisolated enum FullDiskAccess {
    nonisolated enum Status: Equatable, Sendable {
        case granted
        case notGranted
    }

    /// Files only Full Disk Access unlocks, in the order they are tried. Any one of them may be absent
    /// on a given Mac, which is why there are several.
    static let probePaths = probePaths(inHome: NSHomeDirectoryForUser(NSUserName()) ?? NSHomeDirectory())

    static func probePaths(inHome home: String) -> [String] {
        [
            "/Library/Application Support/com.apple.TCC/TCC.db",
            home + "/Library/Application Support/com.apple.TCC/TCC.db",
            home + "/Library/Safari/CloudTabs.db",
        ]
    }

    /// Granted as soon as one probe file can be read. A missing file counts as not readable.
    static func status(canRead: (String) -> Bool = canOpenForReading) -> Status {
        probePaths.contains(where: canRead) ? .granted : .notGranted
    }

    static func canOpenForReading(_ path: String) -> Bool {
        let descriptor = open(path, O_RDONLY)
        guard descriptor != -1 else { return false }
        close(descriptor)
        return true
    }

    /// Opens System Settings > Privacy & Security > Full Disk Access.
    /// The string is a constant known to parse, so the unwrap cannot fail at run time.
    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
    )!
}
