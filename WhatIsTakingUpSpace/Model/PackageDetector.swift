import Foundation
import UniformTypeIdentifiers

/// Tells whether a directory is a package: something Finder shows as a single file.
/// Decides from the name alone, without touching the disk.
nonisolated struct PackageDetector: Sendable {
    /// `name` is the directory's last path component.
    func isPackage(name: String) -> Bool {
        let pathExtension = (name as NSString).pathExtension
        // The lookup must be told the item is a directory. Left to its default it assumes a plain
        // file, and then "app" resolves to a type that is not a package and "photoslibrary" to none.
        let type = UTType(filenameExtension: pathExtension, conformingTo: .directory)
        return type?.conforms(to: .package) ?? false
    }
}
