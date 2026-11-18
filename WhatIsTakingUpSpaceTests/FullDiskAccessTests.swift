import AppKit
import Foundation
import Testing
@testable import WhatIsTakingUpSpace

struct FullDiskAccessTests {
    // MARK: What is probed

    @Test func probesTheSystemAndUserPrivacyDatabasesAndSafariData() {
        #expect(FullDiskAccess.probePaths(inHome: "/Users/someone") == [
            "/Library/Application Support/com.apple.TCC/TCC.db",
            "/Users/someone/Library/Application Support/com.apple.TCC/TCC.db",
            "/Users/someone/Library/Safari/CloudTabs.db",
        ])
    }

    @Test func probeListIsRootedInTheRealHomeDirectory() throws {
        let account = try #require(getpwuid(getuid()))
        let home = String(cString: try #require(account.pointee.pw_dir))

        #expect(FullDiskAccess.probePaths == FullDiskAccess.probePaths(inHome: home))
    }

    // MARK: Status

    @Test func notGrantedWhenNoProbeFileCanBeRead() {
        #expect(FullDiskAccess.status(canRead: { _ in false }) == .notGranted)
    }

    @Test(arguments: 0..<3)
    func grantedWhenAnySingleProbeFileCanBeRead(position: Int) throws {
        let readable = try probePath(at: position)

        #expect(FullDiskAccess.status(canRead: { $0 == readable }) == .granted)
    }

    @Test func probesEveryDocumentedPathInOrderWhenNoneCanBeRead() {
        var probed: [String] = []

        _ = FullDiskAccess.status(canRead: { path in
            probed.append(path)
            return false
        })

        #expect(probed.count == 3)
        #expect(probed == FullDiskAccess.probePaths)
    }

    @Test(arguments: 0..<3)
    func stopsProbingAtTheFirstReadableFile(position: Int) throws {
        let readable = try probePath(at: position)
        var probed: [String] = []

        let status = FullDiskAccess.status(canRead: { path in
            probed.append(path)
            return path == readable
        })

        #expect(status == .granted)
        #expect(probed == Array(FullDiskAccess.probePaths.prefix(position + 1)))
    }

    private func probePath(at position: Int) throws -> String {
        try #require(FullDiskAccess.probePaths.indices.contains(position))
        return FullDiskAccess.probePaths[position]
    }

    // MARK: The real probe

    @Test func aReadableFileCanBeOpened() throws {
        try withTemporaryFile { path in
            #expect(FullDiskAccess.canOpenForReading(path))
        }
    }

    @Test func aMissingFileCannotBeOpened() throws {
        try withTemporaryFile { path in
            #expect(!FullDiskAccess.canOpenForReading(path + ".missing"))
        }
    }

    @Test(.enabled(if: getuid() != 0, "The superuser can open any file"))
    func aFileWithoutReadPermissionCannotBeOpened() throws {
        try withTemporaryFile { path in
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)

            #expect(!FullDiskAccess.canOpenForReading(path))
        }
    }

    /// Opens the same file more times than the process may hold descriptors.
    @Test(.enabled(if: descriptorLimit < 100_000, "The descriptor limit is too high to exhaust in a test"))
    func probingDoesNotLeakFileDescriptors() throws {
        try withTemporaryFile { path in
            for _ in 0...Self.descriptorLimit {
                _ = FullDiskAccess.canOpenForReading(path)
            }

            #expect(FullDiskAccess.canOpenForReading(path))
        }
    }

    private static var descriptorLimit: rlim_t {
        var limit = rlimit()
        return getrlimit(RLIMIT_NOFILE, &limit) == 0 ? limit.rlim_cur : .max
    }

    private func withTemporaryFile(_ body: (String) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FullDiskAccessTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("probe.db")
        try Data("x".utf8).write(to: file)

        try body(file.path)
    }

    // MARK: Settings link

    @Test func settingsLinkPointsAtTheFullDiskAccessPane() {
        #expect(FullDiskAccess.settingsURL.absoluteString
            == "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")
    }

    /// Only asks Launch Services who would open the link. Nothing is launched.
    @Test func settingsLinkIsHandledBySystemSettings() throws {
        let handler = try #require(NSWorkspace.shared.urlForApplication(toOpen: FullDiskAccess.settingsURL))

        #expect(Bundle(url: handler)?.bundleIdentifier == "com.apple.systempreferences")
    }
}
