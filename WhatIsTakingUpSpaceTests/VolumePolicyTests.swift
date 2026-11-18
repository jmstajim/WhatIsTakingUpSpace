import Testing
@testable import WhatIsTakingUpSpace

struct VolumePolicyTests {
    /// The mount table of the machine this app was written on.
    private static let snapshotPath =
        "/Volumes/com.apple.TimeMachine.localsnapshots/Backups.backupdb/Mac/2026-11-19-230809/Data"

    private static let realMounts = [
        Mount(path: "/", source: "/dev/disk3s1s1", fileSystem: "apfs"),
        Mount(path: "/dev", source: "devfs", fileSystem: "devfs"),
        Mount(path: "/System/Volumes/VM", source: "/dev/disk3s6", fileSystem: "apfs"),
        Mount(path: "/System/Volumes/Preboot", source: "/dev/disk3s2", fileSystem: "apfs"),
        Mount(path: "/System/Volumes/Update", source: "/dev/disk3s4", fileSystem: "apfs"),
        Mount(path: "/System/Volumes/xarts", source: "/dev/disk1s2", fileSystem: "apfs"),
        Mount(path: "/System/Volumes/iSCPreboot", source: "/dev/disk1s1", fileSystem: "apfs"),
        Mount(path: "/System/Volumes/Hardware", source: "/dev/disk1s3", fileSystem: "apfs"),
        Mount(path: "/System/Volumes/Data", source: "/dev/disk3s5", fileSystem: "apfs"),
        Mount(path: "/System/Volumes/Data/home", source: "map auto_home", fileSystem: "autofs"),
        Mount(path: "/Volumes/Recovery", source: "/dev/disk3s3", fileSystem: "apfs"),
        Mount(path: "/Library/Developer/CoreSimulator/Volumes/iOS_21F79", source: "/dev/disk13s1", fileSystem: "apfs"),
        Mount(path: "/Volumes/GameBox", source: "/dev/disk7s1", fileSystem: "apfs"),
        Mount(path: "/Volumes/TimeBox", source: "/dev/disk7s2", fileSystem: "apfs"),
        Mount(
            path: snapshotPath,
            source: "com.apple.TimeMachine.2026-11-19-230809.local@/dev/disk3s5",
            fileSystem: "apfs"
        ),
    ]

    private func admittedPaths(scope: ScanScope, rootPath: String, mounts: [Mount] = realMounts) -> [String] {
        let policy = VolumePolicy(scope: scope, rootPath: rootPath, mounts: mounts)
        return mounts.map(\.path).filter(policy.admits(mountPointAt:))
    }

    // MARK: isMountPoint

    @Test func aPathInTheMountTableIsAMountPoint() {
        let policy = VolumePolicy(scope: .folder, rootPath: "/", mounts: Self.realMounts)

        #expect(policy.isMountPoint("/System/Volumes/Data"))
        #expect(policy.isMountPoint("/Volumes/GameBox"))
        #expect(policy.isMountPoint("/dev"))
    }

    @Test func onlyTheExactMountPathIsAMountPoint() {
        let policy = VolumePolicy(scope: .wholeDisk, rootPath: "/", mounts: Self.realMounts)

        #expect(!policy.isMountPoint("/System/Volumes"))
        #expect(!policy.isMountPoint("/System/Volumes/Data/Users"))
        #expect(!policy.isMountPoint("/Volumes/Game"))
        #expect(!policy.isMountPoint("/Users"))
    }

    // MARK: admits

    @Test func wholeDiskScanOfTheStartupDiskAdmitsTheOtherVolumesOfItsContainer() {
        #expect(admittedPaths(scope: .wholeDisk, rootPath: "/") == [
            "/System/Volumes/VM",
            "/System/Volumes/Preboot",
            "/System/Volumes/Update",
            "/System/Volumes/Data",
            "/Volumes/Recovery",
        ])
    }

    @Test func folderScanAdmitsNothing() {
        #expect(admittedPaths(scope: .folder, rootPath: "/") == [])
    }

    @Test func aPathThatIsNotAMountPointIsNotAdmitted() {
        let policy = VolumePolicy(scope: .wholeDisk, rootPath: "/", mounts: Self.realMounts)

        #expect(!policy.admits(mountPointAt: "/Users"))
        #expect(!policy.admits(mountPointAt: "/System/Volumes/Data/Users"))
        #expect(!policy.admits(mountPointAt: "/System/Volumes"))
    }

    @Test func aSnapshotOfTheSameContainerIsNotAdmitted() {
        let policy = VolumePolicy(scope: .wholeDisk, rootPath: "/", mounts: Self.realMounts)

        #expect(!policy.admits(mountPointAt: Self.snapshotPath))
    }

    @Test func aDeviceOfTheSameContainerWithAnotherFileSystemIsNotAdmitted() {
        let mounts = [
            Mount(path: "/", source: "/dev/disk3s1s1", fileSystem: "apfs"),
            Mount(path: "/Volumes/Old", source: "/dev/disk3s9", fileSystem: "hfs"),
        ]

        #expect(admittedPaths(scope: .wholeDisk, rootPath: "/", mounts: mounts) == [])
    }

    @Test func theContainerIsTheWholeDiskNumberNotItsFirstDigit() {
        let mounts = [
            Mount(path: "/", source: "/dev/disk3s1s1", fileSystem: "apfs"),
            Mount(path: "/Volumes/Thirty", source: "/dev/disk31s1", fileSystem: "apfs"),
            Mount(path: "/Volumes/Same", source: "/dev/disk3s7", fileSystem: "apfs"),
        ]

        #expect(admittedPaths(scope: .wholeDisk, rootPath: "/", mounts: mounts) == ["/Volumes/Same"])
    }

    @Test func aSourceWithoutADiskNumberBelongsToNoContainer() {
        let mounts = [
            Mount(path: "/", source: "/dev/disk", fileSystem: "apfs"),
            Mount(path: "/Volumes/Odd", source: "/dev/disk", fileSystem: "apfs"),
        ]

        #expect(admittedPaths(scope: .wholeDisk, rootPath: "/", mounts: mounts) == [])
    }

    @Test func onlyADeviceNodeNamesAContainer() {
        let mounts = [
            Mount(path: "/", source: "/dev/disk3s1s1", fileSystem: "apfs"),
            // Nine characters, then "3": the digit sits where a device node has its disk number.
            Mount(path: "/Volumes/Share", source: "server:/v3s5", fileSystem: "apfs"),
        ]

        #expect(admittedPaths(scope: .wholeDisk, rootPath: "/", mounts: mounts) == [])
    }

    @Test func theRootBelongsToTheMountWithTheLongestPathAboveIt() {
        // GameBox and TimeBox share container disk7; the startup container is disk3.
        #expect(admittedPaths(scope: .wholeDisk, rootPath: "/Volumes/GameBox/Saves") == ["/Volumes/TimeBox"])
    }

    @Test func aRootThatIsItselfAMountPointBelongsToThatMount() {
        #expect(admittedPaths(scope: .wholeDisk, rootPath: "/Volumes/GameBox") == ["/Volumes/TimeBox"])
    }

    @Test func aMountWhoseNameIsOnlyATextPrefixOfTheRootDoesNotHoldIt() {
        let mounts = [
            Mount(path: "/", source: "/dev/disk3s1s1", fileSystem: "apfs"),
            Mount(path: "/System/Volumes/Data", source: "/dev/disk3s5", fileSystem: "apfs"),
            Mount(path: "/Volumes/Game", source: "/dev/disk9s1", fileSystem: "apfs"),
            Mount(path: "/Volumes/Other", source: "/dev/disk9s2", fileSystem: "apfs"),
        ]

        // "/Volumes/GameBox" is a plain folder of the startup disk here, not part of "/Volumes/Game".
        #expect(admittedPaths(scope: .wholeDisk, rootPath: "/Volumes/GameBox/x", mounts: mounts)
            == ["/System/Volumes/Data"])
    }

    @Test func aRootOnAVolumeThatIsNotAPFSAdmitsNothing() {
        let mounts = [
            Mount(path: "/", source: "/dev/disk3s1s1", fileSystem: "apfs"),
            Mount(path: "/Volumes/Stick", source: "/dev/disk3s8", fileSystem: "exfat"),
            Mount(path: "/Volumes/Same", source: "/dev/disk3s7", fileSystem: "apfs"),
        ]

        #expect(admittedPaths(scope: .wholeDisk, rootPath: "/Volumes/Stick/photos", mounts: mounts) == [])
    }

    @Test func aWholeDiskScanStartedOnTheDataVolumeAdmitsTheRestOfTheContainer() {
        // The Data volume holds the root, so it is where the scan already is; "/" is its sibling.
        #expect(admittedPaths(scope: .wholeDisk, rootPath: "/System/Volumes/Data/Users/ada") == [
            "/",
            "/System/Volumes/VM",
            "/System/Volumes/Preboot",
            "/System/Volumes/Update",
            "/Volumes/Recovery",
        ])
    }

    @Test func aRootOnAnAutomountedMapAdmitsNothing() {
        #expect(admittedPaths(scope: .wholeDisk, rootPath: "/System/Volumes/Data/home/ada") == [])
    }

    @Test func aRootInsideASnapshotAdmitsNothing() {
        #expect(admittedPaths(scope: .wholeDisk, rootPath: Self.snapshotPath + "/Users") == [])
    }

    @Test func aPathBelowAnAdmittedMountIsNotItselfAdmitted() {
        let policy = VolumePolicy(scope: .wholeDisk, rootPath: "/", mounts: Self.realMounts)

        #expect(!policy.admits(mountPointAt: "/System/Volumes/Data/"))
        #expect(!policy.admits(mountPointAt: "/System/Volumes/Data/.Spotlight-V100"))
        #expect(!policy.isMountPoint("/System/Volumes/Data/"))
        #expect(!policy.isMountPoint(""))
    }

    // MARK: touchesAdmittedVolume

    @Test func aPathAtInsideOrAboveAnAdmittedVolumeTouchesIt() {
        let policy = VolumePolicy(scope: .wholeDisk, rootPath: "/", mounts: Self.realMounts)

        #expect(policy.touchesAdmittedVolume("/System/Volumes/Data"))
        #expect(policy.touchesAdmittedVolume("/System/Volumes/Data/.Spotlight-V100/Store"))
        #expect(policy.touchesAdmittedVolume("/System/Volumes"))
        #expect(policy.touchesAdmittedVolume("/System"))
        #expect(policy.touchesAdmittedVolume("/Volumes"))
        #expect(policy.touchesAdmittedVolume("/"))
    }

    @Test func aPathClearOfEveryAdmittedVolumeDoesNotTouchOne() {
        let policy = VolumePolicy(scope: .wholeDisk, rootPath: "/", mounts: Self.realMounts)

        #expect(!policy.touchesAdmittedVolume("/Users/ada/Downloads"))
        #expect(!policy.touchesAdmittedVolume("/Applications"))
        // Only whole path components count, and a volume that is not admitted does not either.
        #expect(!policy.touchesAdmittedVolume("/System/Volumes/DataSet"))
        #expect(!policy.touchesAdmittedVolume("/Sys"))
        #expect(!policy.touchesAdmittedVolume("/Volumes/GameBox/Steam"))
    }

    @Test func aFolderScanAdmitsNothingSoNothingTouchesAnAdmittedVolume() {
        let policy = VolumePolicy(scope: .folder, rootPath: "/Users/ada", mounts: Self.realMounts)

        #expect(!policy.touchesAdmittedVolume("/System/Volumes/Data"))
        #expect(!policy.touchesAdmittedVolume("/Users/ada"))
    }

    @Test func aRootOutsideEveryMountAdmitsNothing() {
        let mounts = [Mount(path: "/Volumes/A", source: "/dev/disk3s1", fileSystem: "apfs"),
                      Mount(path: "/Volumes/B", source: "/dev/disk3s2", fileSystem: "apfs")]

        #expect(admittedPaths(scope: .wholeDisk, rootPath: "/elsewhere", mounts: mounts) == [])
    }
}
