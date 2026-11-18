import Testing
import UniformTypeIdentifiers
@testable import WhatIsTakingUpSpace

struct ItemTypeTests {
    @Test func aDirectoryWithAPlainNameIsAFolder() {
        #expect(ItemType.named("Downloads", isDirectory: true) == .folder)
        #expect(ItemType.named("/Users/ada/Downloads", isDirectory: true) == .folder)
    }

    @Test func aDirectoryNamedLikeAPackageIsThatKindOfPackage() {
        #expect(ItemType.named("Xcode.app", isDirectory: true) == .applicationBundle)
        #expect(ItemType.named("/Applications/Xcode.app", isDirectory: true).conforms(to: .package))
    }

    @Test func aDirectoryWhoseExtensionMeansNothingIsAFolder() {
        #expect(ItemType.named("backup.2024", isDirectory: true) == .folder)
        #expect(ItemType.named("archive.zip", isDirectory: true) == .folder)
    }

    @Test func aFileIsWhatItsExtensionSays() {
        #expect(ItemType.named("archive.zip", isDirectory: false) == .zip)
        #expect(ItemType.named("/Users/ada/notes.txt", isDirectory: false) == .plainText)
    }

    @Test func aFileNamedLikeAnAppIsNotAnApp() {
        #expect(!ItemType.named("Xcode.app", isDirectory: false).conforms(to: .package))
    }

    @Test func aFileWithNoExtensionIsJustData() {
        #expect(ItemType.named("kernel", isDirectory: false) == .data)
    }
}
