import Foundation
import Testing
@testable import FennecCore

/// A stand-in for ~/Library/Mobile Documents with the iCloud Drive container, one visible app library and one hidden one.
private func makeMobileDocuments() throws -> TempDir {
    let dir = try TempDir()
    try dir.folder("com~apple~CloudDocs/Notes")
    try dir.folder("Numbers/Documents/Budgets")
    try dir.folder("Hidden/Documents")
    var values = URLResourceValues()
    values.isHidden = true
    var hidden = dir.url.appendingPathComponent("Hidden")
    try hidden.setResourceValues(values)
    return dir
}

struct ICloudDriveTests {
    @Test func appLibrariesListsVisibleContainersOnly() throws {
        let mobile = try makeMobileDocuments()

        let libraries = ICloudDrive.appLibraries(in: mobile.url)

        #expect(libraries.map(\.name) == ["Numbers"])
        #expect(libraries.first?.path == mobile.url.appendingPathComponent("Numbers/Documents").standardizedFileURL.path)
        #expect(libraries.first?.isBrowsable == true)
    }

    @Test func driveRootListingIncludesAppLibraries() throws {
        let mobile = try makeMobileDocuments()

        let root = try DirectoryLoader.loadSync(mobile.url.appendingPathComponent("com~apple~CloudDocs"))
        let other = try DirectoryLoader.loadSync(mobile.url.appendingPathComponent("com~apple~CloudDocs/Notes"))

        #expect(Set(root.map(\.name)) == ["Notes", "Numbers"])
        #expect(other.isEmpty)
    }

    @Test func findsTheLibraryAFolderIsIn() throws {
        let mobile = try makeMobileDocuments()
        let documents = mobile.url.appendingPathComponent("Numbers/Documents")

        let library = ICloudDrive.library(containing: documents.appendingPathComponent("Budgets"), in: mobile.url)

        #expect(library?.name == "Numbers")
        #expect(library?.url.standardizedFileURL.path == documents.standardizedFileURL.path)
        #expect(ICloudDrive.library(
            containing: mobile.url.appendingPathComponent("com~apple~CloudDocs/Notes"), in: mobile.url) == nil)
    }

    @Test func goingUpFromALibraryLandsOnTheDriveRoot() throws {
        let mobile = try makeMobileDocuments()
        let documents = mobile.url.appendingPathComponent("Numbers/Documents")

        let up = ICloudDrive.parent(of: documents, in: mobile.url)
        let upFromSub = ICloudDrive.parent(of: documents.appendingPathComponent("Budgets"), in: mobile.url)

        #expect(up.standardizedFileURL.path
            == mobile.url.appendingPathComponent("com~apple~CloudDocs").standardizedFileURL.path)
        #expect(upFromSub.standardizedFileURL.path == documents.standardizedFileURL.path)
    }
}
