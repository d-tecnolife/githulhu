import XCTest
@testable import Githulu

final class GitHubModelTests: XCTestCase {
    func testRepositoryDecodesGitHubWireNames() throws {
        let data = Data(
            """
            {
              "id": 42,
              "name": "githulu",
              "full_name": "octocat/githulu",
              "description": "Git from an iPhone",
              "clone_url": "https://github.com/octocat/githulu.git",
              "private": true,
              "default_branch": "main"
            }
            """.utf8
        )

        let repository = try JSONDecoder().decode(GitHubRepository.self, from: data)

        XCTAssertEqual(repository.id, 42)
        XCTAssertEqual(repository.fullName, "octocat/githulu")
        XCTAssertEqual(repository.cloneURL.absoluteString, "https://github.com/octocat/githulu.git")
        XCTAssertTrue(repository.isPrivate)
        XCTAssertEqual(repository.defaultBranch, "main")
    }

    func testDeviceAuthorizationDecodesWireNames() throws {
        let data = Data(
            """
            {
              "device_code": "device",
              "user_code": "ABCD-EFGH",
              "verification_uri": "https://github.com/login/device",
              "expires_in": 900,
              "interval": 5
            }
            """.utf8
        )

        let authorization = try JSONDecoder().decode(DeviceAuthorization.self, from: data)

        XCTAssertEqual(authorization.deviceCode, "device")
        XCTAssertEqual(authorization.userCode, "ABCD-EFGH")
        XCTAssertEqual(authorization.expiresIn, 900)
    }
}
