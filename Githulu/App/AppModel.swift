import AuthenticationServices
import Foundation
import SwiftUI
import UIKit

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var account: GitHubAccount?
    @Published private(set) var availableRepositories: [GitHubRepository] = []
    @Published private(set) var isRestoringSession = true
    @Published private(set) var isAuthenticating = false
    @Published var operation: GitProgress?
    @Published var errorMessage: String?

    let git: GitServicing
    private let github: GitHubServicing
    private let keychain: TokenStoring
    private let bookmarks: BookmarkStoring
    private let authenticationPresentationContext = AuthenticationPresentationContext()
    private var authenticationSession: ASWebAuthenticationSession?

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
        guard account == nil else {
            isRestoringSession = false
            return
        }
        defer { isRestoringSession = false }
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

    func beginSignIn() {
        guard !isAuthenticating else { return }
        errorMessage = nil
        do {
            let request = try github.makeAuthorizationRequest()
            isAuthenticating = true
            let session = ASWebAuthenticationSession(
                url: request.authorizationURL,
                callbackURLScheme: request.callbackURLScheme
            ) { [weak self] callbackURL, error in
                Task { @MainActor [weak self] in
                    await self?.completeSignIn(
                        callbackURL: callbackURL,
                        request: request,
                        sessionError: error
                    )
                }
            }
            session.presentationContextProvider = authenticationPresentationContext
            session.prefersEphemeralWebBrowserSession = false
            authenticationSession = session
            guard session.start() else {
                authenticationSession = nil
                isAuthenticating = false
                throw GitHubError.unableToStartAuthentication
            }
        } catch {
            report(error)
        }
    }

    func signOut() {
        authenticationSession?.cancel()
        authenticationSession = nil
        isAuthenticating = false
        try? keychain.deleteToken()
        account = nil
        availableRepositories = []
    }

    func cancelSignIn() {
        authenticationSession?.cancel()
        authenticationSession = nil
        isAuthenticating = false
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

    private func completeSignIn(
        callbackURL: URL?,
        request: GitHubAuthorizationRequest,
        sessionError: Error?
    ) async {
        defer {
            authenticationSession = nil
            isAuthenticating = false
        }
        if let authenticationError = sessionError as? ASWebAuthenticationSessionError,
           authenticationError.code == .canceledLogin {
            return
        }
        if let sessionError {
            report(sessionError)
            return
        }
        guard let callbackURL else {
            report(GitHubError.invalidCallback)
            return
        }
        do {
            let token = try await github.exchangeAuthorizationCode(
                callbackURL: callbackURL,
                request: request
            )
            let signedInAccount = try await github.account(token: token)
            let repositories = try await github.repositories(token: token)
            try keychain.saveToken(token)
            account = signedInAccount
            availableRepositories = repositories
        } catch {
            try? keychain.deleteToken()
            account = nil
            availableRepositories = []
            report(error)
        }
    }
}

@MainActor
private final class AuthenticationPresentationContext:
    NSObject,
    ASWebAuthenticationPresentationContextProviding
{
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) ?? UIWindow()
    }
}
