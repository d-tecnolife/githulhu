import Foundation

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

struct DeviceAuthorization: Codable, Equatable, Identifiable {
    let deviceCode: String
    let userCode: String
    let verificationURI: URL
    let expiresIn: Int
    let interval: Int

    var id: String { deviceCode }

    private enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case expiresIn = "expires_in"
        case interval
    }
}

enum GitHubError: LocalizedError, Equatable {
    case missingClientID
    case invalidResponse
    case authorizationExpired
    case authorizationDenied
    case api(String)

    var errorDescription: String? {
        switch self {
        case .missingClientID:
            return "Set GITHUB_CLIENT_ID in the app target's build settings."
        case .invalidResponse:
            return "GitHub returned an invalid response."
        case .authorizationExpired:
            return "The GitHub sign-in code expired. Try again."
        case .authorizationDenied:
            return "GitHub sign-in was cancelled."
        case .api(let message):
            return message
        }
    }
}

protocol GitHubServicing {
    func beginDeviceAuthorization() async throws -> DeviceAuthorization
    func pollForToken(_ authorization: DeviceAuthorization) async throws -> String
    func account(token: String) async throws -> GitHubAccount
    func repositories(token: String) async throws -> [GitHubRepository]
}

final class GitHubService: GitHubServicing {
    private let session: URLSession
    private let bundle: Bundle

    init(session: URLSession = .shared, bundle: Bundle = .main) {
        self.session = session
        self.bundle = bundle
    }

    private var clientID: String? {
        guard let value = bundle.object(forInfoDictionaryKey: "GITHUB_CLIENT_ID") as? String,
              !value.isEmpty
        else { return nil }
        return value
    }

    func beginDeviceAuthorization() async throws -> DeviceAuthorization {
        guard let clientID else { throw GitHubError.missingClientID }
        var request = URLRequest(url: URL(string: "https://github.com/login/device/code")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formData([
            "client_id": clientID,
            "scope": "repo read:user"
        ])
        return try await decode(DeviceAuthorization.self, request: request)
    }

    func pollForToken(_ authorization: DeviceAuthorization) async throws -> String {
        guard let clientID else { throw GitHubError.missingClientID }
        let deadline = Date().addingTimeInterval(TimeInterval(authorization.expiresIn))
        var interval = max(authorization.interval, 5)

        while Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)

            var request = URLRequest(url: URL(string: "https://github.com/login/oauth/access_token")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = formData([
                "client_id": clientID,
                "device_code": authorization.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
            ])

            let (data, response) = try await session.data(for: request)
            try validate(response)
            let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let token = payload?["access_token"] as? String { return token }

            switch payload?["error"] as? String {
            case "authorization_pending":
                continue
            case "slow_down":
                interval += 5
            case "expired_token":
                throw GitHubError.authorizationExpired
            case "access_denied":
                throw GitHubError.authorizationDenied
            case let error?:
                throw GitHubError.api(error)
            default:
                throw GitHubError.invalidResponse
            }
        }
        throw GitHubError.authorizationExpired
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
        values
            .map { key, value in
                let escaped = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
                return "\(key)=\(escaped)"
            }
            .sorted()
            .joined(separator: "&")
            .data(using: .utf8)
    }
}
