import XCTest
@testable import Githulhu

final class GitHubModelTests: XCTestCase {
    func testRepositoryDecodesGitHubWireNames() throws {
        let data = Data(
            """
            {
              "id": 42,
              "name": "githulhu",
              "full_name": "octocat/githulhu",
              "description": "Git from an iPhone",
              "clone_url": "https://github.com/octocat/githulhu.git",
              "private": true,
              "default_branch": "main"
            }
            """.utf8
        )

        let repository = try JSONDecoder().decode(GitHubRepository.self, from: data)

        XCTAssertEqual(repository.id, 42)
        XCTAssertEqual(repository.fullName, "octocat/githulhu")
        XCTAssertEqual(repository.cloneURL.absoluteString, "https://github.com/octocat/githulhu.git")
        XCTAssertTrue(repository.isPrivate)
        XCTAssertEqual(repository.defaultBranch, "main")
    }

    func testPKCEChallengeMatchesRFC7636Example() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"

        XCTAssertEqual(
            GitHubPKCE.challenge(for: verifier),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
    }

    func testAuthorizationRequestUsesCallbackStateAndPKCE() throws {
        let service = GitHubService(clientID: "test-client-id")
        let request = try service.makeAuthorizationRequest()
        let components = try XCTUnwrap(
            URLComponents(url: request.authorizationURL, resolvingAgainstBaseURL: false)
        )
        let query = Dictionary(
            uniqueKeysWithValues: try XCTUnwrap(components.queryItems).compactMap { item in
                item.value.map { (item.name, $0) }
            }
        )

        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "github.com")
        XCTAssertEqual(components.path, "/login/oauth/authorize")
        XCTAssertEqual(query["client_id"], "test-client-id")
        XCTAssertEqual(query["redirect_uri"], "githulhu://oauth/callback")
        XCTAssertEqual(query["scope"], "repo read:user")
        XCTAssertEqual(query["state"], request.state)
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertEqual(query["code_challenge"], GitHubPKCE.challenge(for: request.codeVerifier))
        XCTAssertEqual(request.callbackURLScheme, "githulhu")
    }

    func testCallbackRequiresMatchingState() throws {
        let validURL = try XCTUnwrap(
            URL(string: "githulhu://oauth/callback?code=temporary-code&state=expected")
        )
        let invalidURL = try XCTUnwrap(
            URL(string: "githulhu://oauth/callback?code=temporary-code&state=attacker")
        )

        XCTAssertEqual(
            try GitHubService.authorizationCode(from: validURL, expectedState: "expected"),
            "temporary-code"
        )
        XCTAssertThrowsError(
            try GitHubService.authorizationCode(from: invalidURL, expectedState: "expected")
        ) { error in
            XCTAssertEqual(error as? GitHubError, .stateMismatch)
        }
    }

    func testTokenExchangeRequiresConfiguredClientSecret() async throws {
        let service = GitHubService(clientID: "test-client-id", clientSecret: "")
        let request = GitHubAuthorizationRequest(
            authorizationURL: try XCTUnwrap(URL(string: "https://github.com/login/oauth/authorize")),
            callbackURLScheme: "githulhu",
            state: "expected",
            codeVerifier: "verifier"
        )
        let callback = try XCTUnwrap(
            URL(string: "githulhu://oauth/callback?code=temporary-code&state=expected")
        )

        do {
            _ = try await service.exchangeAuthorizationCode(
                callbackURL: callback,
                request: request
            )
            XCTFail("Expected a missing client secret error.")
        } catch {
            XCTAssertEqual(error as? GitHubError, .missingClientSecret)
        }
    }
}
