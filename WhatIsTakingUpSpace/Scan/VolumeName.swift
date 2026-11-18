import Foundation

nonisolated enum VolumeName {
    /// The name Finder shows for the volume that holds `path`, e.g. "Macintosh HD".
    static func ofVolume(holding path: String) -> String? {
        try? URL(filePath: path).resourceValues(forKeys: [.volumeNameKey]).volumeName
    }
}
