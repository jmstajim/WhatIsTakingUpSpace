import Foundation
import Testing
@testable import WhatIsTakingUpSpace

/// A scan of this Mac's real startup disk. Slow and machine-dependent, so it runs only on request:
/// `TEST_RUNNER_WITS_REAL_SCAN=1 xcodebuild test …`.
///
/// Home folders are not entered: reading Documents, Desktop or Downloads makes macOS ask the
/// user for permission, and a test must not put dialogs on screen.
struct RealDiskScanTests {
    private static let requested = ProcessInfo.processInfo.environment["WITS_REAL_SCAN"] != nil

    /// Lists everything as it is, except that the home folders appear empty.
    private struct WithoutHomeFolders: DirectoryReader {
        let reader = BulkDirectoryReader()

        func listing(ofDirectoryAt path: String) throws -> DirectoryListing {
            var listing = try reader.listing(ofDirectoryAt: path)
            if path == "/Users" || path == "/System/Volumes/Data/Users" { listing.entries = [] }
            return listing
        }
    }

    @Test(.enabled(if: requested), .timeLimit(.minutes(15)))
    func startupDiskIsScannedOnceThroughItsFirmlinks() async throws {
        let scanner = DiskScanner(reader: WithoutHomeFolders())
        let clock = ContinuousClock()
        var outcome: ScanOutcome?

        let elapsed = try await clock.measure {
            outcome = try await scanner.scan(rootPath: "/") { _ in }
        }

        let tree = try #require(outcome).tree
        let data = try #require(tree.node(at: ["System", "Volumes", "Data"]))
        let underData = Set(tree.children(of: data).map(tree.name(of:)))
        print("REAL SCAN: \(elapsed) for \(tree.nodeCount) nodes, \(tree.size(of: tree.root)) bytes found")
        for child in tree.contents(of: tree.root).children.prefix(12) {
            print("REAL SCAN: /\(tree.name(of: child)) = \(tree.size(of: child))")
        }
        print("REAL SCAN: under /System/Volumes/Data: \(underData.sorted())")
        for name in ["Applications", "Library", "private", "usr"] {
            let node = try #require(tree.node(at: [name]))
            print("REAL SCAN: check /\(name) = \(tree.size(of: node) / 1024) KiB")
        }

        for culprit in tree.culprits(threshold: 2_000_000_000, isPackage: PackageDetector().isPackage(name:)).prefix(40) {
            print("REAL SCAN: culprit \(culprit.ownSize / 1_000_000) MB (of \(culprit.totalSize / 1_000_000)) \(culprit.kind) \(tree.path(of: culprit.node))")
        }

        // What a firmlink already showed is not repeated under the Data volume.
        #expect(underData.isDisjoint(with: ["Applications", "Library", "Users", "private", "Volumes", "opt", "cores"]))
        #expect(tree.node(at: ["Applications"]).map(tree.size(of:)) ?? 0 > 0)
        #expect(tree.node(at: ["Users"]) != nil)
        #expect(tree.node(at: ["System", "Volumes", "VM"]).map(tree.flags(of:)) == [])
        // The other volumes of the startup disk's container are entered; every other disk is left alone.
        let mounts = MountTable.current()
        let policy = VolumePolicy(scope: .wholeDisk, rootPath: "/", mounts: mounts)
        let volumes = try #require(tree.node(at: ["Volumes"]))
        for child in tree.children(of: volumes) where policy.isMountPoint(tree.path(of: child)) {
            let path = tree.path(of: child)
            print("REAL SCAN: volume \(path) flags=\(tree.flags(of: child).rawValue) size=\(tree.size(of: child))")
            #expect(tree.flags(of: child).contains(.otherVolume) == !policy.admits(mountPointAt: path), "\(path)")
        }
    }
}
