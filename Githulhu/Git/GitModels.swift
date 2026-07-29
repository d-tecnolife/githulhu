import Foundation

enum GitOperationKind: String, Codable, CaseIterable {
    case clone, open, status, diff, stage, commit, fetch, pull, push
    case listBranches, createBranch, switchBranch, deleteBranch, resolveConflict
}

enum GitOperationState: String, Codable {
    case queued, running, succeeded, failed, cancelled, interrupted
}

struct GitProgress: Equatable {
    let operation: GitOperationKind
    let fraction: Double?
    let message: String
}

struct GitCredentials {
    let username: String
    let token: String
}

enum GitFileState: String, Codable {
    case added, modified, deleted, renamed, untracked, conflicted, unknown
}

struct GitFileChange: Identifiable, Equatable {
    var id: String { path }
    let path: String
    let state: GitFileState
    let isStaged: Bool
    let isBinary: Bool
}

struct GitRepositoryStatus: Equatable {
    let branch: String
    let ahead: Int
    let behind: Int
    let changes: [GitFileChange]
    let hasConflicts: Bool
}

struct GitDiff: Equatable {
    let path: String
    let text: String?
    let isBinary: Bool
    let isTooLarge: Bool
}

struct GitBranch: Identifiable, Equatable {
    var id: String { "\(isRemote ? "remote" : "local"):\(name)" }
    let name: String
    let isRemote: Bool
    let isCurrent: Bool
    let isMerged: Bool
    let upstream: String?
}

struct GitConflict: Identifiable, Equatable {
    var id: String { path }
    let path: String
    let ancestor: String?
    let ours: String?
    let theirs: String?
    let isBinary: Bool
    let isTooLarge: Bool
}

enum PullResult: Equatable {
    case upToDate
    case fastForward
    case merged
    case conflicts([GitConflict])
}

enum GitServiceError: LocalizedError, Equatable {
    case invalidRepository
    case invalidRemote
    case authenticationFailed
    case dirtyWorkingTree
    case nonFastForward
    case branchNotMerged
    case currentBranchDeletion
    case unsupportedConflict(String)
    case invalidCommitMessage
    case cancelled
    case libgit2(String)

    var errorDescription: String? {
        switch self {
        case .invalidRepository:
            return "The selected folder is not a Git repository."
        case .invalidRemote:
            return "This repository does not have a usable origin remote."
        case .authenticationFailed:
            return "GitHub rejected the stored credentials. Sign in again."
        case .dirtyWorkingTree:
            return "Commit or discard local changes before this operation."
        case .nonFastForward:
            return "The remote contains divergent history that cannot be pushed safely."
        case .branchNotMerged:
            return "This branch has not been merged into the current branch."
        case .currentBranchDeletion:
            return "The current branch cannot be deleted."
        case .unsupportedConflict(let path):
            return "\(path) is binary or too large for the in-app resolver."
        case .invalidCommitMessage:
            return "Enter a commit message."
        case .cancelled:
            return "The operation was cancelled."
        case .libgit2(let message):
            return message
        }
    }
}

protocol GitServicing {
    func clone(
        remote: URL,
        destination: URL,
        credentials: GitCredentials,
        progress: @escaping (GitProgress) -> Void
    ) async throws
    func validate(repository: URL) async throws
    func status(repository: URL) async throws -> GitRepositoryStatus
    func diff(repository: URL, path: String) async throws -> GitDiff
    func stage(repository: URL, path: String) async throws
    func unstage(repository: URL, path: String) async throws
    func commit(repository: URL, message: String, authorName: String, authorEmail: String) async throws
    func fetch(repository: URL, credentials: GitCredentials) async throws
    func pull(repository: URL, credentials: GitCredentials) async throws -> PullResult
    func push(repository: URL, credentials: GitCredentials) async throws
    func branches(repository: URL) async throws -> [GitBranch]
    func createBranch(repository: URL, name: String) async throws
    func switchBranch(repository: URL, name: String) async throws
    func deleteBranch(repository: URL, name: String) async throws
    func conflicts(repository: URL) async throws -> [GitConflict]
    func resolve(repository: URL, path: String, content: String) async throws
    func completeMerge(repository: URL, message: String, authorName: String, authorEmail: String) async throws
}
