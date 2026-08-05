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

    func testWritingTextUpdatesFile() throws {
        let root = try makeTemporaryDirectory()
        let file = root.appendingPathComponent("App.swift")
        try Data("let answer = 41\n".utf8).write(to: file)

        try RepositoryFileAccess.write(
            text: "let answer = 42\n",
            to: file,
            repositoryRoot: root
        )

        XCTAssertEqual(
            try RepositoryFileAccess.read(file: file, repositoryRoot: root),
            .text("let answer = 42\n")
        )
    }

    func testWriterBlocksItemsOutsideRepository() throws {
        let root = try makeTemporaryDirectory()
        let outside = try makeTemporaryDirectory().appendingPathComponent("secret.txt")
        try Data("outside".utf8).write(to: outside)

        XCTAssertThrowsError(
            try RepositoryFileAccess.write(
                text: "changed",
                to: outside,
                repositoryRoot: root
            )
        ) { error in
            XCTAssertEqual(error as? RepositoryBrowserError, .outsideRepository)
        }
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "outside")
    }

    func testWriterRejectsOversizedText() throws {
        let root = try makeTemporaryDirectory()
        let file = root.appendingPathComponent("large.txt")
        try Data("original".utf8).write(to: file)
        let oversized = String(
            repeating: "a",
            count: Int(RepositoryFileAccess.maximumReadableBytes + 1)
        )

        XCTAssertThrowsError(
            try RepositoryFileAccess.write(
                text: oversized,
                to: file,
                repositoryRoot: root
            )
        ) { error in
            XCTAssertEqual(error as? RepositoryBrowserError, .fileTooLargeToSave)
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "original")
    }

    func testSyntaxHighlightingKeepsSourceAndAddsLineNumbers() {
        let highlighted = SyntaxHighlighter.highlight(
            "let answer = 42\nreturn answer",
            fileExtension: "swift"
        )

        XCTAssertEqual(
            String(highlighted.characters),
            "   1  let answer = 42\n   2  return answer"
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
