import Foundation
import Testing
import UniformTypeIdentifiers
@testable import FennecCore

struct FileFormattingTests {
    @Test func kindFallsBackToExtensionForUnknownTypes() {
        let type = UTType(filenameExtension: "jsonl")?.identifier
        let entry = FileEntry(url: URL(filePath: "/x/events.jsonl"), typeIdentifier: type)
        #expect(FileFormatting.kind(for: entry) == "JSONL file")
    }

    @Test func kindWithoutExtensionOrTypeIsDocument() {
        let entry = FileEntry(url: URL(filePath: "/x/Makefile"))
        #expect(FileFormatting.kind(for: entry) == "Document")
    }

    @Test func kindUsesSystemDescriptionWhenAvailable() {
        let entry = FileEntry(url: URL(filePath: "/x/a.txt"), typeIdentifier: "public.plain-text")
        #expect(FileFormatting.kind(for: entry) == UTType.plainText.localizedDescription)
    }

    @Test func folderKindIsFolder() {
        let entry = FileEntry(url: URL(filePath: "/x/Sub"), isDirectory: true)
        #expect(FileFormatting.kind(for: entry) == "Folder")
    }

    @Test func emptyFileSizeIsNumeric() {
        let entry = FileEntry(url: URL(filePath: "/x/empty.txt"), size: 0)
        #expect(FileFormatting.size(for: entry) == "0 bytes")
    }

    @Test func folderSizeIsBlank() {
        let entry = FileEntry(url: URL(filePath: "/x/Sub"), isDirectory: true, size: 64)
        #expect(FileFormatting.size(for: entry) == "")
    }

    @Test func foldersAndPackagesWithStatsShowTheirTotal() {
        for isPackage in [false, true] {
            var entry = FileEntry(url: URL(filePath: "/x/Sub"), isDirectory: true, isPackage: isPackage, size: 64)
            entry.folderStats = FolderStats(bytes: 5000, calculated: Date())
            #expect(FileFormatting.size(for: entry) == FileFormatting.bytes(5000))
        }
    }

    @Test func folderStatsDetailListsCountsDiskUseAndAge() {
        let now = Date()
        let stats = FolderStats(
            bytes: 10, allocated: 8192, files: 1204, subfolders: 1, calculated: now - 7200, incomplete: true)

        let lines = FileFormatting.folderStatsDetail(stats, now: now).components(separatedBy: "\n")

        #expect(lines.count == 4)
        #expect(lines[0] == "\(Int64(1204).formatted()) files in 1 folder")
        #expect(lines[1] == "\(FileFormatting.bytes(8192)) on disk")
        #expect(lines[2] == "Some folders inside couldn't be read")
        #expect(lines[3].hasPrefix("Calculated "))
    }
}
