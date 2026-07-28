import Foundation
import SwiftData

@Model
final class RepositoryRecord {
    @Attribute(.unique) var id: UUID
    var displayName: String
    var remoteURL: String
    @Attribute(.externalStorage) var bookmark: Data
    var lastOpenedAt: Date
    var lastBranch: String?

    init(
        id: UUID = UUID(),
        displayName: String,
        remoteURL: String = "",
        bookmark: Data,
        lastOpenedAt: Date = .now,
        lastBranch: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.remoteURL = remoteURL
        self.bookmark = bookmark
        self.lastOpenedAt = lastOpenedAt
        self.lastBranch = lastBranch
    }
}

@Model
final class OperationRecord {
    @Attribute(.unique) var id: UUID
    var repositoryID: UUID?
    var kind: String
    var state: String
    var message: String
    var startedAt: Date
    var finishedAt: Date?

    init(
        id: UUID = UUID(),
        repositoryID: UUID?,
        kind: GitOperationKind,
        state: GitOperationState,
        message: String,
        startedAt: Date = .now,
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.repositoryID = repositoryID
        self.kind = kind.rawValue
        self.state = state.rawValue
        self.message = message
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}
