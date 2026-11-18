import Foundation
import Testing
@testable import WhatIsTakingUpSpace

/// Pins what this macOS reports. The verdicts for developer types (`.xcodeproj`, `.xcarchive`,
/// `.playground`) come from the type declarations Xcode registers, so they hold on a machine with Xcode.
struct PackageDetectorTests {
    private let detector = PackageDetector()

    @Test(arguments: [
        "Xcode.app",
        "Photos Library.photoslibrary",
        "Plugin.bundle",
        "Release 1.2.xcarchive",
        "WhatIsTakingUpSpace.xcodeproj",
        "Sketches.playground",
        "Letter.rtfd",
    ])
    func directoryFinderShowsAsASingleFileIsAPackage(name: String) {
        #expect(detector.isPackage(name: name))
    }

    @Test(arguments: [
        "Documents",
        "node_modules",
        ".git",
        "archive.zip",
        "My.Folder.With.Dots",
        "AppKit.framework",
    ])
    func directoryFinderOpensAsAFolderIsNotAPackage(name: String) {
        #expect(!detector.isPackage(name: name))
    }

    @Test func extensionIsMatchedWithoutRegardToCase() {
        #expect(detector.isPackage(name: "SHOUTING.APP"))
    }

    @Test func onlyTheLastExtensionCounts() {
        #expect(detector.isPackage(name: "report.final.rtfd"))
        #expect(!detector.isPackage(name: "Xcode.app.bak"))
    }

    @Test func nameThatOnlyLooksLikeAnExtensionIsNotAPackage() {
        #expect(!detector.isPackage(name: ".app"))
        #expect(!detector.isPackage(name: "Xcode.app."))
        #expect(!detector.isPackage(name: "Xcode.app "))
    }

    /// The goal is Finder parity, so the name-only verdict is checked against what the system
    /// says about a real, empty directory of that name.
    @Test(arguments: [
        "Xcode.app", "Photos Library.photoslibrary", "Documents", "node_modules", ".git", "archive.zip",
        "My.Folder.With.Dots", "AppKit.framework", "Plugin.bundle", "Release 1.2.xcarchive",
        "WhatIsTakingUpSpace.xcodeproj", "Sketches.playground", "Letter.rtfd", "Backup 2026-11-19 22.30.15",
        // Name shapes: case, hidden, several dots, and names that only look like they have an extension.
        "SHOUTING.APP", ".hidden.app", " .app", "report.final.rtfd", "Xcode.app.bak", ".app", "..app", "Xcode.app.",
        "Xcode.app ", "Xcode. app", "名前.app",
        // Other places where a lot of space tends to sit.
        "Music Library.musiclibrary", "TV Library.tvlibrary", "Backups.sparsebundle", "Installer.pkg",
        "en.lproj", "Assets.xcassets", "Sim.simruntime",
    ])
    func verdictMatchesWhatTheSystemSaysAboutARealDirectory(name: String) throws {
        #expect(try detector.isPackage(name: name) == systemTreatsAsPackage(directoryNamed: name))
    }

    /// Safari's partial download is a package only through a legacy document claim that declares
    /// no type, so a lookup by type cannot see it.
    @Test func legacyPackageWithoutADeclaredTypeIsMissed() throws {
        let systemVerdict = try systemTreatsAsPackage(directoryNamed: "movie.mp4.download")

        withKnownIssue("A name-only type lookup cannot see packages that declare no type") {
            #expect(detector.isPackage(name: "movie.mp4.download") == systemVerdict)
        }
    }

    private func systemTreatsAsPackage(directoryNamed name: String) throws -> Bool {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("PackageDetectorTests-\(UUID().uuidString)", isDirectory: true)
        let directory = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        return try #require(try directory.resourceValues(forKeys: [.isPackageKey]).isPackage)
    }
}
