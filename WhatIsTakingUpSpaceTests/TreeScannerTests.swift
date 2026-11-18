import Foundation
import Synchronization
import Testing
@testable import WhatIsTakingUpSpace

struct TreeScannerTests {
    /// Scans with a cutoff of 100 bytes and one read at a time unless a test says otherwise.
    private func scan(
        _ reader: FakeDirectoryReader,
        root: String = "/",
        policy: VolumePolicy = VolumePolicy(scope: .folder, rootPath: "/", mounts: []),
        parallelism: Int = 1,
        progressInterval: Int = 512,
        progress: @Sendable (ScanProgress) -> Void = { _ in }
    ) async throws -> FileTree {
        let scanner = TreeScanner(
            reader: reader,
            policy: policy,
            looseCutoff: 100,
            parallelism: parallelism,
            progressInterval: progressInterval
        )
        return try await scanner.scan(root: root, progress: progress)
    }

    // MARK: 1. Paths

    @Test func theRootIsNamedByItsPathAndChildrenAreReadBelowIt() async throws {
        let reader = FakeDirectoryReader(
            identities: ["/Volumes/Box": FileIdentity(device: 7, inode: 2)],
            listings: [
                "/Volumes/Box": [.dir("a", 10, device: 7)],
                "/Volumes/Box/a": [.dir("b", 11, device: 7)],
                "/Volumes/Box/a/b": [.file("movie", 500)],
            ]
        )

        let tree = try await scan(reader, root: "/Volumes/Box")

        #expect(tree.outline == FileTree(.dir("/Volumes/Box", [.dir("a", [.dir("b", [.file("movie", 500)])])])).outline)
        #expect(reader.listedPaths == ["/Volumes/Box", "/Volumes/Box/a", "/Volumes/Box/a/b"])
    }

    @Test func childrenOfTheSlashRootAreReadWithoutADoubledSlash() async throws {
        let reader = FakeDirectoryReader(listings: [
            "/": [.dir("a", 10)],
            "/a": [.dir("b", 11)],
            "/a/b": [],
        ])

        let tree = try await scan(reader)

        #expect(tree.outline == FileTree(.dir("/", [.dir("a", [.dir("b", [])])])).outline)
        #expect(reader.listedPaths == ["/", "/a", "/a/b"])
    }

    // MARK: 2. Nodes and loose files

    @Test func filesAtOrAboveTheCutoffAreNodesAndSmallerOnesAreFolded() async throws {
        let reader = FakeDirectoryReader(listings: [
            "/": [.file("below", 99), .file("at", 100), .file("above", 101), .file("tiny", 1)],
        ])

        let tree = try await scan(reader)

        #expect(tree.outline == FileTree(.dir("/", [
            .file("at", 100),
            .file("above", 101),
        ], loose: LooseFiles(count: 2, bytes: 100))).outline)
    }

    @Test func entriesThatAreNeitherFilesNorDirectoriesAreCountedLikeFiles() async throws {
        let reader = FakeDirectoryReader(listings: [
            "/": [.other("socket", 100), .other("symlink", 4)],
        ])

        let tree = try await scan(reader)

        #expect(tree.outline == FileTree(.dir("/", [
            .file("socket", 100),
        ], loose: LooseFiles(count: 1, bytes: 4))).outline)
    }

    @Test func theDefaultCutoffIsOneMillionBytes() async throws {
        let reader = FakeDirectoryReader(listings: [
            "/": [.file("just under", 999_999), .file("exactly", 1_000_000)],
        ])
        let scanner = TreeScanner(reader: reader, policy: VolumePolicy(scope: .folder, rootPath: "/", mounts: []))

        let tree = try await scanner.scan(root: "/") { _ in }

        #expect(tree.outline == FileTree(.dir("/", [
            .file("exactly", 1_000_000),
        ], loose: LooseFiles(count: 1, bytes: 999_999))).outline)
    }

    @Test func directoriesBecomeNodesEvenWhenEmptyOrSmall() async throws {
        let reader = FakeDirectoryReader(listings: [
            "/": [.dir("empty", 10), .dir("small", 11), .file("big", 300)],
            "/empty": [],
            "/small": [.file("note", 7)],
        ])

        let tree = try await scan(reader)

        #expect(tree.outline == FileTree(.dir("/", [
            .dir("empty", []),
            .dir("small", [], loose: LooseFiles(count: 1, bytes: 7)),
            .file("big", 300),
        ])).outline)
        #expect(tree.size(of: tree.root) == 307)
    }

    // MARK: 3. Hard links

    @Test func aFileWithSeveralLinksIsCountedOnlyWhereItIsFirstSeen() async throws {
        let reader = FakeDirectoryReader(listings: [
            "/": [
                .file("big", 500, inode: 77, links: 2),
                .file("small", 3, inode: 88, links: 3),
                .file("small again", 3, inode: 88, links: 3),
                .dir("d", 10),
            ],
            "/d": [
                .file("big again", 500, inode: 77, links: 2),
                .file("small once more", 3, inode: 88, links: 3),
                .file("own", 200, inode: 99, links: 2),
            ],
        ])

        let tree = try await scan(reader)

        #expect(tree.outline == FileTree(.dir("/", [
            .file("big", 500),
            .dir("d", [.file("own", 200)]),
        ], loose: LooseFiles(count: 1, bytes: 3))).outline)
        #expect(tree.size(of: tree.root) == 703)
    }

    @Test func filesWithASingleLinkAreCountedEvenWhenTheirIdentitiesCollide() async throws {
        let reader = FakeDirectoryReader(listings: [
            "/": [
                .file("a", 500, inode: 77),
                .file("b", 500, inode: 77),
                .file("c", 3, inode: 88),
                .file("d", 3, inode: 88),
            ],
        ])

        let tree = try await scan(reader)

        #expect(tree.outline == FileTree(.dir("/", [
            .file("a", 500),
            .file("b", 500),
        ], loose: LooseFiles(count: 2, bytes: 6))).outline)
    }

    @Test func aSingleLinkDoesNotClaimTheIdentityForLaterHardLinks() async throws {
        let reader = FakeDirectoryReader(listings: [
            "/": [.file("single", 500, inode: 77), .file("linked", 500, inode: 77, links: 2)],
        ])

        let tree = try await scan(reader)

        #expect(tree.outline == FileTree(.dir("/", [.file("single", 500), .file("linked", 500)])).outline)
    }

    @Test func onlyRegularFilesAreDeduplicatedByLinkCount() async throws {
        let reader = FakeDirectoryReader(listings: [
            "/": [.other("x", 500, inode: 77, links: 2), .other("y", 500, inode: 77, links: 2)],
        ])

        let tree = try await scan(reader)

        #expect(tree.outline == FileTree(.dir("/", [.file("x", 500), .file("y", 500)])).outline)
    }

    // MARK: 4. Directory aliases

    /// Which of two names for one directory is kept is whichever is opened first; the other is
    /// opened, recognised, and goes no further.
    @Test func aDirectoryThatWasAlreadyReadIsLeftOutAndNothingBelowItIsRead() async throws {
        let reader = FakeDirectoryReader(listings: [
            "/": [.dir("first", 10), .dir("alias", 10)],
            "/first": [.dir("sub", 11), .file("movie", 500)],
            "/alias": [.dir("sub", 11), .file("movie", 500)],
            "/first/sub": [.file("clip", 300)],
            "/alias/sub": [.file("clip", 300)],
        ])

        let tree = try await scan(reader)

        let kept = try #require(tree.children(of: tree.root).map(tree.name(of:)).first)
        #expect(tree.outline == FileTree(.dir("/", [
            .dir(kept, [.dir("sub", [.file("clip", 300)]), .file("movie", 500)]),
        ])).outline)
        #expect(Set(reader.listedPaths) == ["/", "/first", "/alias", "/\(kept)/sub"])
        #expect(reader.listedPaths.count == 4)
    }

    /// The real shape of a firmlink: the parent lists a placeholder, and only the directory's own
    /// listing says which directory it is.
    @Test func aDirectoryIsRecognisedByTheIdentityItReportsNotTheOneItsParentLists() async throws {
        let reader = FakeDirectoryReader(
            identities: [
                "/": FileIdentity(device: 1, inode: 2),
                "/link": FileIdentity(device: 1, inode: 500),
            ],
            listings: [
                // "link" is listed under a placeholder inode; opened, it is the directory "target" lists.
                "/": [.dir("target-holder", 20), .dir("link", 999_999)],
                "/link": [.file("movie", 500)],
                "/target-holder": [.dir("real", 500)],
                "/target-holder/real": [.file("movie", 500)],
            ]
        )

        let tree = try await scan(reader)

        let sightings = [tree.node(at: ["link"]), tree.node(at: ["target-holder", "real"])].compactMap(\.self)
        #expect(sightings.count == 1)
        #expect(tree.size(of: tree.root) == 500)
        #expect(tree.nodeCount == 4)
    }

    @Test func directoriesListedUnderOneIdentityButReportingDifferentOnesAreBothKept() async throws {
        let reader = FakeDirectoryReader(
            identities: [
                "/": FileIdentity(device: 1, inode: 2),
                "/a": FileIdentity(device: 1, inode: 100),
                "/b": FileIdentity(device: 1, inode: 200),
            ],
            listings: [
                "/": [.dir("a", 7), .dir("b", 7)],
                "/a": [.file("movie", 500)],
                "/b": [.file("game", 700)],
            ]
        )

        let tree = try await scan(reader)

        #expect(tree.outline == FileTree(.dir("/", [
            .dir("a", [.file("movie", 500)]),
            .dir("b", [.file("game", 700)]),
        ])).outline)
    }

    @Test func anAliasFoundElsewhereInTheTreeIsLeftOutToo() async throws {
        let reader = FakeDirectoryReader(listings: [
            "/": [.dir("a", 10), .dir("z", 20)],
            "/a": [.dir("shared", 30)],
            "/z": [.dir("shared", 30)],
            "/a/shared": [.file("movie", 500)],
            "/z/shared": [.file("movie", 500)],
        ])

        let tree = try await scan(reader)

        let sightings = [tree.node(at: ["a", "shared"]), tree.node(at: ["z", "shared"])].compactMap(\.self)
        #expect(sightings.count == 1)
        #expect(tree.size(of: tree.root) == 500)
        #expect(tree.nodeCount == 5)
    }

    @Test func theRootIsTheFirstDirectoryRead() async throws {
        let reader = FakeDirectoryReader(
            identities: ["/": FileIdentity(device: 1, inode: 2)],
            listings: [
                "/": [.dir("loop", 2), .file("movie", 500)],
                "/loop": [.dir("deeper", 3), .file("movie", 500)],
                "/loop/deeper": [],
            ]
        )

        let tree = try await scan(reader)

        #expect(tree.outline == FileTree(.dir("/", [.file("movie", 500)])).outline)
        #expect(reader.listedPaths == ["/", "/loop"])
    }

    // MARK: 5. Volume boundaries that are not admitted

    @Test func aMountPointTheListingReportsIsMarkedAsAnotherVolumeAndNeverTouched() async throws {
        let reader = FakeDirectoryReader(listings: [
            "/": [.dir("home", 50, mountPoint: true), .dir("plain", 51)],
            "/home": [.file("movie", 500)],
            "/plain": [.file("movie", 500)],
        ])

        let tree = try await scan(reader)

        #expect(tree.outline == FileTree(.dir("/", [
            .dir("home", [], flags: .otherVolume),
            .dir("plain", [.file("movie", 500)]),
        ])).outline)
        #expect(reader.listedPaths == ["/", "/plain"])
    }

    @Test func aPathInTheMountTableIsABoundaryEvenWhenTheListingDoesNotSaySo() async throws {
        let reader = FakeDirectoryReader(listings: [
            "/": [.dir("Volumes", 50)],
            "/Volumes": [.dir("GameBox", 51)],
            "/Volumes/GameBox": [.file("game", 500)],
        ])
        let policy = Self.wholeDisk(mounts: [Mount(path: "/Volumes/GameBox", source: "/dev/disk7s1", fileSystem: "apfs")])

        let tree = try await scan(reader, policy: policy)

        #expect(tree.outline == FileTree(.dir("/", [
            .dir("Volumes", [.dir("GameBox", [], flags: .otherVolume)]),
        ])).outline)
        #expect(reader.listedPaths == ["/", "/Volumes"])
    }

    @Test func aChildOnAnotherDeviceThanItsParentIsABoundary() async throws {
        let reader = FakeDirectoryReader(listings: [
            "/": [.dir("elsewhere", 50, device: 2), .dir("here", 51, device: 1)],
            "/elsewhere": [.file("movie", 500)],
            "/here": [.file("movie", 500)],
        ])

        let tree = try await scan(reader)

        #expect(tree.outline == FileTree(.dir("/", [
            .dir("elsewhere", [], flags: .otherVolume),
            .dir("here", [.file("movie", 500)]),
        ])).outline)
        #expect(reader.listedPaths == ["/", "/here"])
    }

    @Test func aFolderScanEntersNoOtherVolumeEvenOfItsOwnContainer() async throws {
        let reader = FakeDirectoryReader(
            identities: ["/": FileIdentity(device: 1, inode: 2), "/Data": FileIdentity(device: 1, inode: 9999)],
            listings: [
                "/": [.dir("Data", 5, mountPoint: true)],
                "/Data": [.file("movie", 500)],
            ]
        )
        let policy = VolumePolicy(scope: .folder, rootPath: "/", mounts: [
            Mount(path: "/", source: "/dev/disk3s1s1", fileSystem: "apfs"),
            Mount(path: "/Data", source: "/dev/disk3s5", fileSystem: "apfs"),
        ])

        let tree = try await scan(reader, policy: policy)

        #expect(tree.outline == FileTree(.dir("/", [.dir("Data", [], flags: .otherVolume)])).outline)
        #expect(reader.listedPaths == ["/"])
    }

    // MARK: 5. Admitted volumes

    /// The layout of a real startup disk: `/Users` is a firmlink to the same directory that the
    /// Data volume lists as `/System/Volumes/Data/Users`. The root lists the firmlink under a
    /// placeholder inode; only opening `/Users` shows it is the Data volume's inode 18416.
    @Test(arguments: [1, 8])
    func theDataVolumeDoesNotRepeatWhatFirmlinksAlreadyShowed(parallelism: Int) async throws {
        let expected = FileTree(.dir("/", [
            .dir("Users", [.dir("ada", [.file("movie", 5000)], loose: LooseFiles(count: 1, bytes: 7))]),
            .dir("System", [.dir("Volumes", [
                .dir("Data", [.dir(".Spotlight-V100", [.file("index", 3000)])]),
                .dir("VM", [.file("swapfile", 2000)]),
            ])]),
        ])).outline

        for _ in 0..<(parallelism == 1 ? 1 : 200) {
            let reader = FakeDirectoryReader(
                identities: [
                    "/": FileIdentity(device: 1, inode: 2),
                    "/Users": FileIdentity(device: 1, inode: 18416),
                    "/System/Volumes/Data": FileIdentity(device: 1, inode: 9999),
                    "/System/Volumes/VM": FileIdentity(device: 2, inode: 2),
                ],
                listings: [
                    "/": [.dir("Users", 1_152_921_500_312_611_921), .dir("System", 3)],
                    "/Users": [.dir("ada", 500)],
                    "/Users/ada": [.file("movie", 5000), .file("note", 7)],
                    "/System": [.dir("Volumes", 4)],
                    "/System/Volumes": [.dir("Data", 5, mountPoint: true), .dir("VM", 6, mountPoint: true)],
                    "/System/Volumes/Data": [.dir("Users", 18416), .dir(".Spotlight-V100", 700)],
                    "/System/Volumes/Data/.Spotlight-V100": [.file("index", 3000)],
                    "/System/Volumes/Data/Users": [.dir("ada", 500)],
                    "/System/Volumes/Data/Users/ada": [.file("movie", 5000), .file("note", 7)],
                    "/System/Volumes/VM": [.file("swapfile", 2000)],
                ]
            )

            let tree = try await scan(reader, policy: Self.startupDisk, parallelism: parallelism)

            #expect(tree.outline == expected)
            #expect(tree.size(of: tree.root) == 10007)
            #expect(reader.listedPaths.filter { $0 == "/Users" }.count == 1)
            // The Data volume's copy is opened once, recognised, and nothing below it is read.
            #expect(reader.listedPaths.filter { $0 == "/System/Volumes/Data/Users" }.count == 1)
            #expect(!reader.listedPaths.contains("/System/Volumes/Data/Users/ada"))
            #expect(reader.listedPaths.count == 9)
        }
    }

    /// `/usr/local` is a firmlink two levels down: without deferral a depth-first walk reaches it
    /// through the Data volume before it reaches it from the root.
    @Test(arguments: [1, 8])
    func anAdmittedVolumeIsReadOnlyAfterEverythingOutsideItHasBeenRead(parallelism: Int) async throws {
        let policy = Self.wholeDisk(mounts: [Self.volume(at: "/Data")])
        let expected = FileTree(.dir("/", [
            .dir("usr", [.dir("local", [.file("brew", 4000)])]),
            .dir("Data", [.dir("usr", [.file("own", 300)])]),
        ])).outline

        for _ in 0..<(parallelism == 1 ? 1 : 100) {
            let reader = FakeDirectoryReader(
                identities: [
                    "/": FileIdentity(device: 1, inode: 2),
                    "/usr/local": FileIdentity(device: 1, inode: 31),
                    "/Data": FileIdentity(device: 1, inode: 9999),
                ],
                listings: [
                    "/": [.dir("usr", 30), .dir("Data", 5, mountPoint: true)],
                    // A firmlink: listed under a placeholder, it is inode 31 of the Data volume.
                    "/usr": [.dir("local", 888_888)],
                    "/usr/local": [.file("brew", 4000)],
                    "/Data": [.dir("usr", 40)],
                    "/Data/usr": [.dir("local", 31), .file("own", 300)],
                    "/Data/usr/local": [.file("brew", 4000)],
                ]
            )

            let tree = try await scan(reader, policy: policy, parallelism: parallelism)

            #expect(tree.outline == expected)
            #expect(reader.listedPaths == ["/", "/usr", "/usr/local", "/Data", "/Data/usr", "/Data/usr/local"])
        }
    }

    @Test func aVolumeFoundInsideAnAdmittedVolumeWaitsForTheRestOfThatVolume() async throws {
        let reader = FakeDirectoryReader(
            identities: [
                "/": FileIdentity(device: 1, inode: 2),
                "/Data": FileIdentity(device: 2, inode: 2),
                "/Data/Inner": FileIdentity(device: 3, inode: 2),
            ],
            listings: [
                "/": [.dir("Data", 5, mountPoint: true)],
                "/Data": [.dir("deep", 40, device: 2), .dir("Inner", 41, device: 2, mountPoint: true)],
                "/Data/deep": [.dir("deeper", 42, device: 2)],
                "/Data/deep/deeper": [.file("movie", 500)],
                "/Data/Inner": [.file("game", 700)],
            ]
        )
        let policy = Self.wholeDisk(mounts: [Self.volume(at: "/Data"), Self.volume(at: "/Data/Inner")])

        let tree = try await scan(reader, policy: policy)

        #expect(tree.outline == FileTree(.dir("/", [.dir("Data", [
            .dir("deep", [.dir("deeper", [.file("movie", 500)])]),
            .dir("Inner", [.file("game", 700)]),
        ])])).outline)
        #expect(reader.listedPaths == ["/", "/Data", "/Data/deep", "/Data/deep/deeper", "/Data/Inner"])
    }

    @Test func insideAnAdmittedVolumeTheBoundaryIsJudgedAgainstThatVolumesOwnDevice() async throws {
        let reader = FakeDirectoryReader(
            identities: [
                "/": FileIdentity(device: 1, inode: 2),
                "/VM": FileIdentity(device: 2, inode: 2),
            ],
            listings: [
                "/": [.dir("VM", 6, device: 1, mountPoint: true)],
                "/VM": [.dir("same", 60, device: 2), .dir("foreign", 61, device: 1)],
                "/VM/same": [.file("swapfile", 2000)],
                "/VM/foreign": [.file("movie", 500)],
            ]
        )

        let tree = try await scan(reader, policy: Self.wholeDisk(mounts: [Self.volume(at: "/VM")]))

        #expect(tree.outline == FileTree(.dir("/", [.dir("VM", [
            .dir("same", [.file("swapfile", 2000)]),
            .dir("foreign", [], flags: .otherVolume),
        ])])).outline)
        #expect(reader.listedPaths == ["/", "/VM", "/VM/same"])
    }

    @Test func anAdmittedVolumeIsVisitedUnderItsRealIdentityNotTheListedOne() async throws {
        let reader = FakeDirectoryReader(
            identities: [
                "/": FileIdentity(device: 1, inode: 2),
                "/VM": FileIdentity(device: 2, inode: 2),
            ],
            listings: [
                // The listing describes the directory the volume covers: device 1, inode 6.
                "/": [.dir("plain", 6), .dir("VM", 6, mountPoint: true)],
                "/plain": [.file("movie", 500)],
                "/VM": [.dir("itself", 2, device: 2), .file("swapfile", 2000)],
                "/VM/itself": [.file("swapfile", 2000)],
            ]
        )

        let tree = try await scan(reader, policy: Self.wholeDisk(mounts: [Self.volume(at: "/VM")]))

        // "plain" really is device 1 inode 6 and is kept; the volume's root is device 2 inode 2,
        // so the directory inside it that reports the same is the volume itself over again.
        #expect(tree.outline == FileTree(.dir("/", [
            .dir("plain", [.file("movie", 500)]),
            .dir("VM", [.file("swapfile", 2000)]),
        ])).outline)
        #expect(reader.listedPaths == ["/", "/plain", "/VM", "/VM/itself"])
    }

    @Test func anAdmittedVolumeWhoseRootWasAlreadyReadIsLeftOut() async throws {
        let reader = FakeDirectoryReader(
            identities: [
                "/": FileIdentity(device: 1, inode: 2),
                "/Again": FileIdentity(device: 1, inode: 2),
                "/Data": FileIdentity(device: 1, inode: 9999),
                "/DataTwice": FileIdentity(device: 1, inode: 9999),
            ],
            listings: [
                "/": [
                    .dir("Again", 5, mountPoint: true),
                    .dir("Data", 6, mountPoint: true),
                    .dir("DataTwice", 7, mountPoint: true),
                ],
                "/Again": [.dir("sub", 70), .file("movie", 500)],
                "/Again/sub": [],
                "/Data": [.file("movie", 500)],
                "/DataTwice": [.file("movie", 500)],
            ]
        )
        let policy = Self.wholeDisk(mounts: ["/Again", "/Data", "/DataTwice"].map(Self.volume(at:)))

        let tree = try await scan(reader, policy: policy)

        // "Again" is the root over again; "Data" and "DataTwice" are one volume mounted twice.
        let kept = tree.children(of: tree.root).map(tree.name(of:))
        #expect(kept == ["Data"] || kept == ["DataTwice"])
        #expect(tree.size(of: tree.root) == 500)
        #expect(tree.nodeCount == 3)
        #expect(Set(reader.listedPaths) == ["/", "/Again", "/Data", "/DataTwice"])
    }

    // MARK: 6. Dataless directories

    @Test func aDatalessDirectoryIsMarkedAndNeverRead() async throws {
        let reader = FakeDirectoryReader(listings: [
            "/": [.dir("iCloud", 50, dataless: true), .dir("local", 51)],
            "/iCloud": [.file("movie", 500)],
            "/local": [.file("movie", 500)],
        ])

        let tree = try await scan(reader)

        #expect(tree.outline == FileTree(.dir("/", [
            .dir("iCloud", [], flags: .dataless),
            .dir("local", [.file("movie", 500)]),
        ])).outline)
        #expect(reader.listedPaths == ["/", "/local"])
    }

    // MARK: 7. Unreadable directories

    @Test func aDirectoryThatCannotBeReadIsMarkedAndTheScanGoesOn() async throws {
        let reader = FakeDirectoryReader(
            listings: [
                "/": [.dir("secret", 50), .dir("open", 51)],
                "/open": [.file("movie", 500)],
            ],
            failures: ["/secret": Denied()]
        )

        let tree = try await scan(reader)

        #expect(tree.outline == FileTree(.dir("/", [
            .dir("secret", [], flags: .unreadable),
            .dir("open", [.file("movie", 500)]),
        ])).outline)
        #expect(Set(reader.listedPaths) == ["/", "/secret", "/open"])
    }

    @Test func aRootThatCannotBeListedFailsTheScan() async {
        let reader = FakeDirectoryReader(listings: [:], failures: ["/": Denied()])

        await #expect(throws: Denied()) {
            try await scan(reader)
        }
    }

    // MARK: 8. Cancellation

    @Test func aScanInAnAlreadyCancelledTaskThrowsWithoutReadingAnything() async {
        let reader = FakeDirectoryReader(listings: ["/": [.file("movie", 500)]])

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await scan(reader)
        }

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(reader.listedPaths == [])
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingARunningScanStopsItBeforeTheNextDirectory() async throws {
        let reader = FakeDirectoryReader(
            listings: [
                "/": [.dir("a", 10)],
                "/a": [.dir("b", 11)],
                "/a/b": [.file("movie", 500)],
            ],
            whileListing: { path, _ in
                // "/a" is being read at the moment the scan is cancelled.
                if path == "/a" { wait(upTo: .seconds(20)) { Task.isCancelled } }
            }
        )

        let task = Task { try await scan(reader) }
        while !reader.listedPaths.contains("/a") {
            try await Task.sleep(for: .milliseconds(1))
        }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(reader.listedPaths == ["/", "/a"])
    }

    // MARK: 9. Progress

    /// Five directories in a chain, so one read at a time visits them in a known order.
    private static let chain: [String: [DirectoryEntry]] = [
        "/": [.file("big", 500), .file("small", 3), .dir("a", 10)],
        "/a": [.file("medium", 200), .dir("b", 11)],
        "/a/b": [.dir("c", 12), .file("note", 7)],
        "/a/b/c": [.dir("d", 13)],
        "/a/b/c/d": [.file("huge", 1000)],
    ]

    @Test func progressIsReportedEveryIntervalDirectoriesAndOnceAtTheEnd() async throws {
        let log = ProgressLog()

        _ = try await scan(FakeDirectoryReader(listings: Self.chain), progressInterval: 2, progress: log.record)

        #expect(log.reports == [
            ScanProgress(filesSeen: 3, bytesSeen: 703, currentPath: "/a"),
            ScanProgress(filesSeen: 4, bytesSeen: 710, currentPath: "/a/b/c"),
            ScanProgress(filesSeen: 5, bytesSeen: 1710, currentPath: "/a/b/c/d"),
        ])
    }

    @Test(arguments: [(interval: 1, reports: 6), (2, 3), (4, 2), (5, 2), (6, 1), (0, 6), (-3, 6)])
    func theNumberOfReportsFollowsTheInterval(interval: Int, reports: Int) async throws {
        let log = ProgressLog()

        _ = try await scan(FakeDirectoryReader(listings: Self.chain), progressInterval: interval, progress: log.record)

        #expect(log.reports.count == reports)
        #expect(log.reports.last == ScanProgress(filesSeen: 5, bytesSeen: 1710, currentPath: "/a/b/c/d"))
    }

    @Test func theFinalReportCountsExactlyWhatTheTreeHolds() async throws {
        let reader = FakeDirectoryReader(
            listings: [
                "/": [
                    .file("big", 500, inode: 77, links: 2),
                    .file("small", 3),
                    .other("link", 4),
                    .dir("first", 10),
                    .dir("alias", 10),
                    .dir("secret", 11),
                    .dir("elsewhere", 12, device: 2),
                ],
                "/first": [.file("big again", 500, inode: 77, links: 2), .file("own", 200)],
            ],
            failures: ["/secret": Denied()]
        )
        let log = ProgressLog()

        let tree = try await scan(reader, progress: log.record)

        #expect(log.reports.count == 1)
        #expect(log.reports.last?.filesSeen == 4)
        #expect(log.reports.last?.bytesSeen == 707)
        #expect(log.reports.last?.bytesSeen == tree.size(of: tree.root))
    }

    @Test func progressNeverGoesBackwardsWhenDirectoriesAreReadInParallel() async throws {
        let reader = FakeDirectoryReader(listings: Self.wideTree(fanout: 4, depth: 3))
        let log = ProgressLog()

        let tree = try await scan(reader, parallelism: 8, progressInterval: 1, progress: log.record)

        let reports = log.reports
        #expect(reports.count == 86)
        #expect(zip(reports, reports.dropFirst()).allSatisfy { earlier, later in
            earlier.filesSeen <= later.filesSeen && earlier.bytesSeen <= later.bytesSeen
        })
        #expect(reports.last?.filesSeen == 170)
        #expect(reports.last?.bytesSeen == tree.size(of: tree.root))
        #expect(Set(reports.map(\.currentPath)).isSubset(of: Set(reader.listedPaths)))
    }

    // MARK: 10. Concurrency

    @Test func exactlyAsManyDirectoriesAreReadAtOnceAsParallelismAllows() async throws {
        let listings = Self.wideTree(fanout: 4, depth: 3)
        let reader = FakeDirectoryReader(listings: listings, whileListing: { _, reader in
            // Hold every read until three overlap, then a little longer so that a fourth would show.
            wait(upTo: .milliseconds(100)) { reader.readsInFlight >= 3 }
            usleep(2000)
        })

        let tree = try await scan(reader, parallelism: 3)

        #expect(reader.peakReadsInFlight == 3)
        #expect(tree.outline == (try await scan(FakeDirectoryReader(listings: listings))).outline)
    }

    @Test func noMoreReadsAreHandedOutThanParallelismAllows() throws {
        var assembly = ScanAssembly(
            rootPath: "/",
            classifier: ListingClassifier(
                policy: VolumePolicy(scope: .folder, rootPath: "/", mounts: []),
                looseCutoff: 100
            ),
            parallelism: 2,
            progressInterval: 512
        )
        let rootRead = assembly.nextRead()
        let root = try #require(rootRead)
        _ = try assembly.accept(DirectoryRead(directory: root, listing: .success(DirectoryListing(
            identity: FileIdentity(device: 1, inode: 2),
            entries: [.dir("a", 10), .dir("b", 11), .dir("c", 12), .dir("d", 13)]
        ))))

        let atFirst = [assembly.nextRead(), assembly.nextRead(), assembly.nextRead()]
        #expect(atFirst.map { $0 != nil } == [true, true, false])

        let returned = try #require(atFirst[0])
        _ = try assembly.accept(DirectoryRead(directory: returned, listing: .success(DirectoryListing(
            identity: FileIdentity(device: 1, inode: 10),
            entries: []
        ))))
        let afterOneReturned = [assembly.nextRead(), assembly.nextRead()]
        #expect(afterOneReturned.map { $0 != nil } == [true, false])

        let paths = (atFirst + afterOneReturned).compactMap { $0?.path }
        #expect(Set(paths).count == 3)
        #expect(Set(paths).isSubset(of: ["/a", "/b", "/c", "/d"]))
    }

    @Test(arguments: [0, -1])
    func aParallelismBelowOneStillReadsOneDirectoryAtATime(parallelism: Int) async throws {
        let reader = FakeDirectoryReader(listings: Self.chain)

        let tree = try await scan(reader, parallelism: parallelism)

        #expect(tree.size(of: tree.root) == 1710)
        #expect(reader.listedPaths == ["/", "/a", "/a/b", "/a/b/c", "/a/b/c/d"])
        #expect(reader.peakReadsInFlight == 1)
    }

    @Test func anAdmittedVolumeIsNotEnteredWhileAReadOutsideItIsStillInFlight() async throws {
        let reader = FakeDirectoryReader(
            identities: ["/": FileIdentity(device: 1, inode: 2), "/Data": FileIdentity(device: 1, inode: 9999)],
            listings: [
                "/": [.dir("Data", 5, mountPoint: true), .dir("slow", 20)],
                "/slow": [.dir("shared", 30)],
                "/slow/shared": [.file("movie", 500)],
                "/Data": [.dir("shared", 30)],
                "/Data/shared": [.file("movie", 500)],
            ],
            whileListing: { path, reader in
                // Nothing else is ready while "/slow" is read: a scan that does not wait for it
                // would take the idle moment to enter the volume and find "shared" there first.
                if path == "/slow" { wait(upTo: .milliseconds(150)) { reader.listedPaths.contains("/Data") } }
            }
        )

        let tree = try await scan(reader, policy: Self.wholeDisk(mounts: [Self.volume(at: "/Data")]), parallelism: 2)

        #expect(tree.outline == FileTree(.dir("/", [
            .dir("Data", []),
            .dir("slow", [.dir("shared", [.file("movie", 500)])]),
        ])).outline)
        // "/Data/shared" is opened last, recognised as the directory "/slow" already showed, and dropped.
        #expect(reader.listedPaths == ["/", "/slow", "/slow/shared", "/Data", "/Data/shared"])
    }

    @Test func parallelScansOfTheSameDiskProduceTheSameTree() async throws {
        let listings = Self.wideTree(fanout: 4, depth: 3)
        let expected = try await scan(FakeDirectoryReader(listings: listings)).outline

        for _ in 0..<20 {
            let tree = try await scan(FakeDirectoryReader(listings: listings), parallelism: 8)

            #expect(tree.outline == expected)
        }
    }

    @Test func aHardLinkSeenFromParallelReadsIsStillCountedOnce() async throws {
        var listings = Self.wideTree(fanout: 4, depth: 3)
        for path in listings.keys {
            listings[path]?.append(.file("shared big", 400, inode: 77, links: 85))
            listings[path]?.append(.file("shared small", 9, inode: 88, links: 85))
        }

        for _ in 0..<20 {
            let tree = try await scan(FakeDirectoryReader(listings: listings), parallelism: 8)

            #expect(tree.size(of: tree.root) == 85 * 155 + 409)
            #expect(tree.nodeCount == 85 + 85 + 1)
        }
    }

    // MARK: Review additions

    @Test func hardLinksWithTheSameInodeOnDifferentVolumesAreDifferentFiles() async throws {
        func link(_ name: String, device: Int32) -> DirectoryEntry {
            DirectoryEntry(
                name: name,
                kind: .file,
                identity: FileIdentity(device: device, inode: 77),
                allocatedSize: 500,
                linkCount: 2
            )
        }
        let reader = FakeDirectoryReader(listings: [
            "/": [link("here", device: 1), link("elsewhere", device: 2), link("here again", device: 1)],
        ])

        let tree = try await scan(reader)

        #expect(tree.outline == FileTree(.dir("/", [.file("here", 500), .file("elsewhere", 500)])).outline)
    }

    /// A dataless directory is not opened, whatever kind of volume boundary it also is.
    @Test func aDatalessDirectoryIsMarkedDatalessEvenWhenItIsAlsoAVolumeBoundary() async throws {
        let reader = FakeDirectoryReader(
            identities: ["/": FileIdentity(device: 1, inode: 2), "/Data": FileIdentity(device: 1, inode: 9999)],
            listings: [
                "/": [
                    .dir("mounted", 50, mountPoint: true, dataless: true),
                    .dir("elsewhere", 51, device: 2, dataless: true),
                    .dir("listed", 52, dataless: true),
                    .dir("Data", 5, mountPoint: true, dataless: true),
                ],
                "/Data": [.file("movie", 500)],
            ]
        )
        let policy = Self.wholeDisk(mounts: [
            Self.volume(at: "/Data"),
            Mount(path: "/listed", source: "/dev/disk7s1", fileSystem: "apfs"),
        ])

        let tree = try await scan(reader, policy: policy)

        #expect(tree.outline == FileTree(.dir("/", [
            .dir("mounted", [], flags: .dataless),
            .dir("elsewhere", [], flags: .dataless),
            .dir("listed", [], flags: .dataless),
            .dir("Data", [], flags: .dataless),
        ])).outline)
        #expect(reader.listedPaths == ["/"])
    }

    @Test func aVolumeKnownOnlyFromTheMountTableIsDeferredAndEnteredUnderItsRealIdentity() async throws {
        let reader = FakeDirectoryReader(
            identities: [
                "/": FileIdentity(device: 1, inode: 2),
                "/Volumes/Recovery": FileIdentity(device: 3, inode: 2),
            ],
            listings: [
                "/": [.dir("Volumes", 50)],
                // Nothing in the listing gives the volume away: same device, no mount flag.
                "/Volumes": [.dir("plain", 52), .dir("Recovery", 51)],
                "/Volumes/plain": [.dir("deeper", 53)],
                "/Volumes/plain/deeper": [],
                "/Volumes/Recovery": [.dir("own", 60, device: 3), .dir("foreign", 61, device: 1)],
                "/Volumes/Recovery/own": [.file("os", 900)],
                "/Volumes/Recovery/foreign": [.file("movie", 500)],
            ]
        )
        let policy = Self.wholeDisk(mounts: [Self.volume(at: "/Volumes/Recovery")])

        let tree = try await scan(reader, policy: policy)

        #expect(tree.outline == FileTree(.dir("/", [.dir("Volumes", [
            .dir("plain", [.dir("deeper", [])]),
            .dir("Recovery", [.dir("own", [.file("os", 900)]), .dir("foreign", [], flags: .otherVolume)]),
        ])])).outline)
        #expect(reader.listedPaths == [
            "/", "/Volumes", "/Volumes/plain", "/Volumes/plain/deeper", "/Volumes/Recovery", "/Volumes/Recovery/own",
        ])
    }

    @Test func anAdmittedVolumeThatCannotBeListedIsMarkedUnreadableAndTheScanGoesOn() async throws {
        let reader = FakeDirectoryReader(
            identities: [
                "/": FileIdentity(device: 1, inode: 2),
                "/Data": FileIdentity(device: 1, inode: 9999),
                "/VM": FileIdentity(device: 2, inode: 2),
            ],
            listings: [
                "/": [.dir("Data", 5, mountPoint: true), .dir("VM", 6, mountPoint: true), .file("movie", 500)],
                "/VM": [.file("swapfile", 2000)],
            ],
            failures: ["/Data": Denied()]
        )
        let policy = Self.wholeDisk(mounts: [Self.volume(at: "/Data"), Self.volume(at: "/VM")])

        let tree = try await scan(reader, policy: policy)

        #expect(tree.outline == FileTree(.dir("/", [
            .dir("Data", [], flags: .unreadable),
            .dir("VM", [.file("swapfile", 2000)]),
            .file("movie", 500),
        ])).outline)
        #expect(Set(reader.listedPaths) == ["/", "/Data", "/VM"])
    }

    @Test(.timeLimit(.minutes(1)))
    func nothingIsReportedOnceTheScanIsCancelled() async throws {
        let reader = FakeDirectoryReader(listings: Self.chain, whileListing: { path, _ in
            // "/a" is being read at the moment the scan is cancelled.
            if path == "/a" { wait(upTo: .seconds(20)) { Task.isCancelled } }
        })
        let log = ProgressLog()

        let task = Task { try await scan(reader, progressInterval: 1, progress: log.record) }
        while !reader.listedPaths.contains("/a") {
            try await Task.sleep(for: .milliseconds(1))
        }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(log.reports.map(\.currentPath) == ["/"])
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingAParallelScanStartsNoFurtherReads() async throws {
        let reader = FakeDirectoryReader(
            listings: Self.wideTree(fanout: 4, depth: 3),
            whileListing: { path, _ in
                // Everything below the first level ("/d0/d1" and deeper) hangs until the scan is cancelled.
                if path.utf8.count > 3 { wait(upTo: .seconds(20)) { Task.isCancelled } }
            }
        )

        let task = Task { try await scan(reader, parallelism: 8) }
        while reader.readsInFlight < 8 {
            try await Task.sleep(for: .milliseconds(1))
        }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        // The root, its four directories and the eight reads that were in flight.
        #expect(reader.listedPaths.count == 13)
    }

    /// The callback runs on the scanning task, so it can cancel the scan it reports on.
    @Test(arguments: ["/a", "/a/b/c/d"])
    func aScanCancelledFromItsOwnProgressReportReadsNothingMoreAndThrows(lastPath: String) async throws {
        let reader = FakeDirectoryReader(listings: Self.chain)
        let log = ProgressLog()

        let task = Task {
            try await scan(reader, progressInterval: 1) { report in
                log.record(report)
                if report.currentPath == lastPath { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(reader.listedPaths.last == lastPath)
        #expect(log.reports.last?.currentPath == lastPath)
        #expect(log.reports.count == reader.listedPaths.count)
    }

    /// Depth-first is what keeps the backlog of directories waiting to be read small: breadth-first
    /// would hold a whole level of a million-directory disk in memory.
    @Test func aSubtreeIsReadToTheBottomBeforeItsSiblingIsStarted() async throws {
        let reader = FakeDirectoryReader(listings: [
            "/": [.dir("a", 10), .dir("b", 20)],
            "/a": [.dir("deep", 11)],
            "/a/deep": [.dir("deeper", 12)],
            "/a/deep/deeper": [],
            "/b": [.dir("deep", 21)],
            "/b/deep": [.dir("deeper", 22)],
            "/b/deep/deeper": [],
        ])

        _ = try await scan(reader)

        let listed = reader.listedPaths
        let first = try #require(listed.dropFirst().first)
        #expect(listed.count == 7)
        #expect(listed.prefix(4) == ["/", first, first + "/deep", first + "/deep/deeper"])
    }
}

/// Collects progress reports from whatever task the scanner calls back on.
private final class ProgressLog: Sendable {
    private let collected = Mutex<[ScanProgress]>([])

    var reports: [ScanProgress] { collected.withLock(\.self) }

    func record(_ report: ScanProgress) {
        collected.withLock { $0.append(report) }
    }
}

/// Blocks the calling thread until `condition` holds or `timeout` has passed.
private func wait(upTo timeout: Duration, until condition: () -> Bool) {
    let deadline = ContinuousClock.now + timeout
    while !condition() && ContinuousClock.now < deadline {
        usleep(200)
    }
}

private struct Denied: Error, Equatable {}

private extension TreeScannerTests {
    /// A whole-disk scan of a startup disk in container disk3 with these further mounts.
    static func wholeDisk(mounts: [Mount]) -> VolumePolicy {
        let root = Mount(path: "/", source: "/dev/disk3s1s1", fileSystem: "apfs")
        return VolumePolicy(scope: .wholeDisk, rootPath: "/", mounts: [root] + mounts)
    }

    /// Another volume of the startup disk's container.
    static func volume(at path: String) -> Mount {
        Mount(path: path, source: "/dev/disk3s5", fileSystem: "apfs")
    }

    /// A tree of `(fanout^(depth+1) - 1) / (fanout - 1)` directories, each holding one file of
    /// 150 bytes, one loose file of 5 bytes and, above the last level, `fanout` subdirectories.
    static func wideTree(fanout: Int, depth: Int) -> [String: [DirectoryEntry]] {
        var listings: [String: [DirectoryEntry]] = [:]
        var level = ["/"]
        for remaining in (0...depth).reversed() {
            var nextLevel: [String] = []
            for path in level {
                let names = remaining > 0 ? (0..<fanout).map { "d\($0)" } : []
                let firstInode = UInt64(100 + listings.count * fanout)
                listings[path] = [.file("big", 150), .file("small", 5)]
                    + names.enumerated().map { .dir($0.element, firstInode + UInt64($0.offset)) }
                nextLevel += names.map { path == "/" ? "/" + $0 : path + "/" + $0 }
            }
            level = nextLevel
        }
        return listings
    }

    static let startupDisk = wholeDisk(mounts: [
        Mount(path: "/System/Volumes/VM", source: "/dev/disk3s6", fileSystem: "apfs"),
        Mount(path: "/System/Volumes/Data", source: "/dev/disk3s5", fileSystem: "apfs"),
    ])
}

// MARK: - Helpers

private extension FileTree {
    /// One line per node, sorted by path, so that trees assembled in different orders compare equal.
    var outline: [String] {
        var lines: [String] = []
        var unvisited = [root]
        while let id = unvisited.popLast() {
            let loose = loose(of: id)
            lines.append(
                "\(path(of: id)) \(kind(of: id)) size=\(size(of: id)) "
                    + "loose=\(loose.count)/\(loose.bytes) flags=\(flags(of: id).rawValue)"
            )
            unvisited.append(contentsOf: children(of: id))
        }
        return lines.sorted()
    }
}
