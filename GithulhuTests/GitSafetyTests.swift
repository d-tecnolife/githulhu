import XCTest
@testable import Githulhu

final class GitSafetyTests: XCTestCase {
    func testDestructiveErrorsGiveActionableMessages() {
        XCTAssertEqual(
            GitServiceError.branchNotMerged.errorDescription,
            "This branch has not been merged into the current branch."
        )
        XCTAssertEqual(
            GitServiceError.currentBranchDeletion.errorDescription,
            "The current branch cannot be deleted."
        )
        XCTAssertTrue(
            GitServiceError.nonFastForward.errorDescription?.contains("cannot be pushed safely") == true
        )
    }

    func testFileAndBranchIdentityIsStable() {
        let change = GitFileChange(
            path: "Sources/App.swift",
            state: .modified,
            isStaged: false,
            isBinary: false
        )
        let branch = GitBranch(
            name: "main",
            isRemote: false,
            isCurrent: true,
            isMerged: true,
            upstream: "origin/main"
        )

        XCTAssertEqual(change.id, "Sources/App.swift")
        XCTAssertEqual(branch.id, "local:main")
    }

    func testRepositoryLocationNormalizesEquivalentFolderURLs() {
        let direct = URL(fileURLWithPath: "/tmp/repos/project")
        let equivalent = URL(fileURLWithPath: "/tmp/repos/other/../project")

        XCTAssertTrue(RepositoryLocation.matches(direct, equivalent))
    }
}
