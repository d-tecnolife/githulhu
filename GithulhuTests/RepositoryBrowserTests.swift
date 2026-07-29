import XCTest
@testable import Githulhu

final class RepositoryBrowserTests: XCTestCase {
    func testDirectoryListingHidesGitMetadataAndSortsFoldersFirst() throws {
        let root = try makeTemporaryDirectory()
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git"),
            withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".github"),
            withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sources"),
            withIntermediateDirectories: false
        )
        try Data("read me".utf8).write(to: root.appendingPathComponent("README.md"))

        let entries = try RepositoryFileAccess.entries(in: root, repositoryRoot: root)

        XCTAssertEqual(entries.map(\.name), [".github", "Sources", "README.md"])
        XCTAssertEqual(entries.map(\.isDirectory), [true, true, false])
    }

    func testTextAndBinaryFilesAreClassifiedForReading() throws {
        let root = try makeTemporaryDirectory()
        let textFile = root.appendingPathComponent("App.swift")
        let binaryFile = root.appendingPathComponent("image.bin")
        try Data("let answer = 42\n".utf8).write(to: textFile)
        try Data([0x01, 0x00, 0x02]).write(to: binaryFile)

        XCTAssertEqual(
            try RepositoryFileAccess.read(file: textFile, repositoryRoot: root),
            .text("let answer = 42\n")
        )
        XCTAssertEqual(
            try RepositoryFileAccess.read(file: binaryFile, repositoryRoot: root),
            .binary
        )
    }

    func testReaderBlocksItemsOutsideRepository() throws {
        let root = try makeTemporaryDirectory()
        let outside = try makeTemporaryDirectory().appendingPathComponent("secret.txt")
        try Data("outside".utf8).write(to: outside)

        XCTAssertFalse(RepositoryFileAccess.contains(outside, repositoryRoot: root))
        XCTAssertThrowsError(
            try RepositoryFileAccess.read(file: outside, repositoryRoot: root)
        ) { error in
            XCTAssertEqual(error as? RepositoryBrowserError, .outsideRepository)
        }
    }

    func testOversizedFileIsNotLoadedAsText() throws {
        let root = try makeTemporaryDirectory()
        let file = root.appendingPathComponent("large.txt")
        let size = Int(RepositoryFileAccess.maximumReadableBytes + 1)
        try Data(repeating: 0x41, count: size).write(to: file)

        XCTAssertEqual(
            try RepositoryFileAccess.read(file: file, repositoryRoot: root),
            .tooLarge(Int64(size))
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GithulhuTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
