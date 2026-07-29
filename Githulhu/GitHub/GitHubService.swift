import Foundation
import CryptoKit
import Security

struct GitHubAccount: Codable, Equatable {
    let login: String
    let name: String?
    let avatarURL: URL?

    private enum CodingKeys: String, CodingKey {
        case login, name
        case avatarURL = "avatar_url"
    }
}

struct GitHubRepository: Codable, Identifiable, Equatable {
    let id: Int
    let name: String
    let fullName: String
    let description: String?
    let cloneURL: URL
    let isPrivate: Bool
    let defaultBranch: String

    private enum CodingKeys: String, CodingKey {
        case id, name, description
        case fullName = "full_name"
        case cloneURL = "clone_url"
        case isPrivate = "private"
        case defaultBranch = "default_branch"
    }
}

struct GitHubAuthorizationRequest: Equatable {
    let authorizationURL: URL
    let callbackURLScheme: String
    let state: String
    let codeVerifier: String
}

enum GitHubError: LocalizedError, Equatable {
    case missingClientID
    case missingClientSecret
    case invalidResponse
    case authorizationDenied
    case invalidCallback
    case stateMismatch
    case unableToStartAuthentication
    case api(String)

    var errorDescription: String? {
        switch self {
        case .missingClientID:
            return "GitHub sign-in is unavailable in this build."
        case .missingClientSecret:
            return "GitHub sign-in credentials are incomplete in this build."
        case .invalidResponse:
            return "GitHub returned an invalid response."
        case .authorizationDenied:
            return "GitHub sign-in was cancelled."
        case .invalidCallback:
            return "GitHub returned an invalid sign-in callback."
        case .stateMismatch:
            return "The GitHub sign-in response could not be verified. Try again."
        case .unableToStartAuthentication:
            return "The secure GitHub sign-in window could not be opened."
        case .api(let message):
            return message
        }
    }
}

protocol GitHubServicing {
    func makeAuthorizationRequest() throws -> GitHubAuthorizationRequest
    func exchangeAuthorizationCode(
        callbackURL: URL,
        request: GitHubAuthorizationRequest
    ) async throws -> String
    func account(token: String) async throws -> GitHubAccount
    func repositories(token: String) async throws -> [GitHubRepository]
}

final class GitHubService: GitHubServicing {
    private static let callbackURL = URL(string: "githulhu://oauth/callback")!
    private let session: URLSession
    private let configuredClientID: String?
    private let configuredClientSecret: String?

    init(session: URLSession = .shared, bundle: Bundle = .main) {
        self.session = session
        self.configuredClientID = bundle.object(forInfoDictionaryKey: "GITHUB_CLIENT_ID") as? String
        self.configuredClientSecret = bundle.object(
            forInfoDictionaryKey: "GITHUB_CLIENT_SECRET"
        ) as? String
    }

    init(
        session: URLSession = .shared,
        clientID: String,
        clientSecret: String = "test-client-secret"
    ) {
        self.session = session
        self.configuredClientID = clientID
        self.configuredClientSecret = clientSecret
    }

    private var clientID: String? {
        guard let value = configuredClientID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value != "$(GITHUB_CLIENT_ID)"
        else { return nil }
        return value
    }

    private var clientSecret: String? {
        guard let value = configuredClientSecret?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value != "$(GITHUB_CLIENT_SECRET)"
        else { return nil }
        return value
    }

    func makeAuthorizationRequest() throws -> GitHubAuthorizationRequest {
        guard let clientID else { throw GitHubError.missingClientID }
        let verifier = try GitHubPKCE.randomValue()
        let state = try GitHubPKCE.randomValue()
        var components = URLComponents(string: "https://github.com/login/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: Self.callbackURL.absoluteString),
            URLQueryItem(name: "scope", value: "repo read:user"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: GitHubPKCE.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "prompt", value: "select_account")
        ]
        guard let authorizationURL = components.url else {
            throw GitHubError.invalidResponse
        }
        return GitHubAuthorizationRequest(
            authorizationURL: authorizationURL,
            callbackURLScheme: Self.callbackURL.scheme!,
            state: state,
            codeVerifier: verifier
        )
    }

    func exchangeAuthorizationCode(
        callbackURL: URL,
        request authorization: GitHubAuthorizationRequest
    ) async throws -> String {
        guard let clientID else { throw GitHubError.missingClientID }
        guard let clientSecret else { throw GitHubError.missingClientSecret }
        let code = try Self.authorizationCode(
            from: callbackURL,
            expectedState: authorization.state
        )

        var tokenRequest = URLRequest(url: URL(string: "https://github.com/login/oauth/access_token")!)
        tokenRequest.httpMethod = "POST"
        tokenRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        tokenRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        tokenRequest.httpBody = formData([
            "client_id": clientID,
            "client_secret": clientSecret,
            "code": code,
            "redirect_uri": Self.callbackURL.absoluteString,
            "code_verifier": authorization.codeVerifier
        ])

        let (data, response) = try await session.data(for: tokenRequest)
        try validate(response)
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GitHubError.invalidResponse
        }
        if let token = payload["access_token"] as? String, !token.isEmpty {
            return token
        }
        if let description = payload["error_description"] as? String {
            throw GitHubError.api(description)
        }
        if let error = payload["error"] as? String {
            throw GitHubError.api(error)
        }
        throw GitHubError.invalidResponse
    }

    static func authorizationCode(from callbackURL: URL, expectedState: String) throws -> String {
        guard callbackURL.scheme == Self.callbackURL.scheme,
              callbackURL.host == Self.callbackURL.host,
              callbackURL.path == Self.callbackURL.path,
              let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
        else {
            throw GitHubError.invalidCallback
        }
        let queryItems = components.queryItems ?? []
        let value: (String) -> String? = { name in
            queryItems.first(where: { $0.name == name })?.value
        }
        guard value("state") == expectedState else {
            throw GitHubError.stateMismatch
        }
        if value("error") == "access_denied" {
            throw GitHubError.authorizationDenied
        }
        guard let code = value("code"), !code.isEmpty else {
            throw GitHubError.invalidCallback
        }
        return code
    }

    func account(token: String) async throws -> GitHubAccount {
        try await api(GitHubAccount.self, path: "/user", token: token)
    }

    func repositories(token: String) async throws -> [GitHubRepository] {
        var page = 1
        var result: [GitHubRepository] = []
        while true {
            let repositories = try await api(
                [GitHubRepository].self,
                path: "/user/repos?affiliation=owner,collaborator,organization_member&sort=updated&per_page=100&page=\(page)",
                token: token
            )
            result.append(contentsOf: repositories)
            guard repositories.count == 100 else { return result }
            page += 1
        }
    }

    private func api<T: Decodable>(_ type: T.Type, path: String, token: String) async throws -> T {
        var request = URLRequest(url: URL(string: "https://api.github.com\(path)")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return try await decode(type, request: request)
    }

    private func decode<T: Decodable>(_ type: T.Type, request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        try validate(response)
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw GitHubError.invalidResponse
        }
    }

    private func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else {
            throw GitHubError.invalidResponse
        }
        guard 200..<300 ~= response.statusCode else {
            throw GitHubError.api("GitHub request failed with status \(response.statusCode).")
        }
    }

    private func formData(_ values: [String: String]) -> Data? {
        var components = URLComponents()
        components.queryItems = values
            .map { URLQueryItem(name: $0.key, value: $0.value) }
            .sorted { $0.name < $1.name }
        return components.percentEncodedQuery?.data(using: .utf8)
    }
}

enum GitHubPKCE {
    static func randomValue(byteCount: Int = 32) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, byteCount, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw GitHubError.invalidResponse
        }
        return Data(bytes).base64URLEncodedString()
    }

    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
