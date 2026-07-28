import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var account: GitHubAccount?
    @Published private(set) var availableRepositories: [GitHubRepository] = []
    @Published var authorization: DeviceAuthorization?
    @Published var operation: GitProgress?
    @Published var errorMessage: String?

    let git: GitServicing
    private let github: GitHubServicing
    private let keychain: TokenStoring
    private let bookmarks: BookmarkStoring
    private var authorizationTask: Task<Void, Never>?

    init(
        git: GitServicing,
        github: GitHubServicing,
        keychain: TokenStoring,
        bookmarks: BookmarkStoring
    ) {
        self.git = git
        self.github = github
        self.keychain = keychain
        self.bookmarks = bookmarks
    }

    var isSignedIn: Bool { account != nil }

    func restoreSession() async {
        guard account == nil else { return }
        do {
            guard let token = try keychain.loadToken() else { return }
            account = try await github.account(token: token)
            availableRepositories = try await github.repositories(token: token)
        } catch {
            try? keychain.deleteToken()
            account = nil
            availableRepositories = []
        }
    }

    func beginSignIn() async {
        do {
            authorization = try await github.beginDeviceAuthorization()
        } catch {
            report(error)
        }
    }

    func awaitSignIn() {
        guard let authorization else { return }
        authorizationTask?.cancel()
        authorizationTask = Task {
            do {
                let token = try await github.pollForToken(authorization)
                try keychain.saveToken(token)
                account = try await github.account(token: token)
                availableRepositories = try await github.repositories(token: token)
                self.authorization = nil
            } catch is CancellationError {
                return
            } catch {
                report(error)
            }
        }
    }

    func signOut() {
        authorizationTask?.cancel()
        try? keychain.deleteToken()
        account = nil
        availableRepositories = []
        authorization = nil
    }

    func cancelSignIn() {
        authorizationTask?.cancel()
        authorizationTask = nil
        authorization = nil
    }

    func refreshRepositories() async {
        do {
            let token = try requireToken()
            availableRepositories = try await github.repositories(token: token)
        } catch {
            report(error)
        }
    }

    func registerExisting(folder: URL) async throws -> RepositoryRecord {
        let scoped = try ScopedURL(url: folder)
        try await git.validate(repository: scoped.url)
        let bookmark = try bookmarks.makeBookmark(for: folder)
        let status = try await git.status(repository: folder)
        return RepositoryRecord(
            displayName: folder.lastPathComponent,
            bookmark: bookmark,
            lastBranch: status.branch
        )
    }

    func clone(_ repository: GitHubRepository, inside folder: URL) async throws -> RepositoryRecord {
        let scoped = try ScopedURL(url: folder)
        let target = scoped.url.appendingPathComponent(repository.name, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw GitServiceError.libgit2("A folder named \(repository.name) already exists.")
        }
        let credentials = try credentials()
        operation = GitProgress(operation: .clone, fraction: nil, message: "Starting clone…")
        do {
            try await git.clone(
                remote: repository.cloneURL,
                destination: target,
                credentials: credentials
            ) { [weak self] progress in
                Task { @MainActor in self?.operation = progress }
            }
            operation = nil
            let bookmark = try bookmarks.makeBookmark(for: target)
            return RepositoryRecord(
                displayName: repository.name,
                remoteURL: repository.cloneURL.absoluteString,
                bookmark: bookmark,
                lastBranch: repository.defaultBranch
            )
        } catch {
            operation = nil
            if FileManager.default.fileExists(atPath: target.path) {
                try? FileManager.default.removeItem(at: target)
            }
            throw error
        }
    }

    func scopedURL(for record: RepositoryRecord) throws -> ScopedURL {
        try bookmarks.resolve(record.bookmark)
    }

    func credentials() throws -> GitCredentials {
        GitCredentials(username: "x-access-token", token: try requireToken())
    }

    func report(_ error: Error) {
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func requireToken() throws -> String {
        guard let token = try keychain.loadToken(), !token.isEmpty else {
            throw GitServiceError.authenticationFailed
        }
        return token
    }
}
