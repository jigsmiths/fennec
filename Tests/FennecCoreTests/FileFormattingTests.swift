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
}
