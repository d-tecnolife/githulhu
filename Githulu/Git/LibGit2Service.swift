import Darwin
import Foundation
import libgit2

private final class CredentialPayload {
    let credentials: GitCredentials
    let operation: GitOperationKind
    let progress: ((GitProgress) -> Void)?

    init(
        _ credentials: GitCredentials,
        operation: GitOperationKind,
        progress: ((GitProgress) -> Void)? = nil
    ) {
        self.credentials = credentials
        self.operation = operation
        self.progress = progress
    }
}

private let gitCredentialCallback: git_credential_acquire_cb = {
    output, _, usernameFromURL, allowedTypes, payload in
    guard let output, let payload else { return -1 }
    guard allowedTypes & GIT_CREDENTIAL_USERPASS_PLAINTEXT.rawValue != 0 else {
        return GIT_PASSTHROUGH.rawValue
    }
    let box = Unmanaged<CredentialPayload>.fromOpaque(payload).takeUnretainedValue()
    let username = if let usernameFromURL {
        String(cString: usernameFromURL)
    } else {
        box.credentials.username
    }
    return git_credential_userpass_plaintext_new(output, username, box.credentials.token)
}

private let gitTransferCallback: git_indexer_progress_cb = { stats, payload in
    guard !Task.isCancelled, let stats, let payload else { return GIT_EUSER.rawValue }
    let box = Unmanaged<CredentialPayload>.fromOpaque(payload).takeUnretainedValue()
    let total = max(Int(stats.pointee.total_objects), 1)
    let received = Int(stats.pointee.received_objects)
    box.progress?(
        GitProgress(
            operation: box.operation,
            fraction: min(Double(received) / Double(total), 1),
            message: "Receiving objects \(received) of \(total)"
        )
    )
    return 0
}

private let gitPushProgressCallback: git_push_transfer_progress_cb = {
    current, total, _, payload in
    guard !Task.isCancelled, let payload else { return GIT_EUSER.rawValue }
    let box = Unmanaged<CredentialPayload>.fromOpaque(payload).takeUnretainedValue()
    let safeTotal = max(Int(total), 1)
    box.progress?(
        GitProgress(
            operation: .push,
            fraction: min(Double(current) / Double(safeTotal), 1),
            message: "Uploading objects \(current) of \(total)"
        )
    )
    return 0
}

actor LibGit2Service: GitServicing {
    private static let conflictLimit = 1_000_000

    init() {
        git_libgit2_init()
    }

    deinit {
        git_libgit2_shutdown()
    }

    func clone(
        remote: URL,
        destination: URL,
        credentials: GitCredentials,
        progress: @escaping (GitProgress) -> Void
    ) async throws {
        try Task.checkCancellation()
        progress(GitProgress(operation: .clone, fraction: nil, message: "Connecting to GitHub…"))

        let payload = CredentialPayload(credentials, operation: .clone, progress: progress)
        var options = git_clone_options()
        try check(git_clone_options_init(&options, UInt32(GIT_CLONE_OPTIONS_VERSION)))
        options.fetch_opts.callbacks.credentials = gitCredentialCallback
        options.fetch_opts.callbacks.transfer_progress = gitTransferCallback
        options.fetch_opts.callbacks.payload = Unmanaged.passUnretained(payload).toOpaque()
        options.checkout_opts.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue

        var repository: OpaquePointer?
        let result = git_clone(&repository, remote.absoluteString, destination.path, &options)
        if let repository { git_repository_free(repository) }
        try check(result)
        progress(GitProgress(operation: .clone, fraction: 1, message: "Clone complete"))
    }

    func validate(repository url: URL) async throws {
        try withRepository(url) { _ in () }
    }

    func status(repository url: URL) async throws -> GitRepositoryStatus {
        try withRepository(url) { repository in
            let branch = try currentBranchName(repository)
            var options = git_status_options()
            try check(git_status_options_init(&options, UInt32(GIT_STATUS_OPTIONS_VERSION)))
            options.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR
            options.flags =
                GIT_STATUS_OPT_INCLUDE_UNTRACKED.rawValue |
                GIT_STATUS_OPT_RENAMES_HEAD_TO_INDEX.rawValue |
                GIT_STATUS_OPT_RENAMES_INDEX_TO_WORKDIR.rawValue

            var list: OpaquePointer?
            try check(git_status_list_new(&list, repository, &options))
            defer { git_status_list_free(list) }

            var changes: [GitFileChange] = []
            for index in 0..<git_status_list_entrycount(list) {
                guard let entry = git_status_byindex(list, index)?.pointee else { continue }
                let flags = entry.status.rawValue
                let staged = flags & (
                    GIT_STATUS_INDEX_NEW.rawValue |
                    GIT_STATUS_INDEX_MODIFIED.rawValue |
                    GIT_STATUS_INDEX_DELETED.rawValue |
                    GIT_STATUS_INDEX_RENAMED.rawValue |
                    GIT_STATUS_INDEX_TYPECHANGE.rawValue
                ) != 0
                let delta = entry.index_to_workdir?.pointee ?? entry.head_to_index?.pointee
                guard let rawPath = delta?.new_file.path ?? delta?.old_file.path else { continue }
                let path = String(cString: rawPath)
                let binaryFlags = delta?.new_file.flags ?? 0
                changes.append(
                    GitFileChange(
                        path: path,
                        state: fileState(flags),
                        isStaged: staged,
                        isBinary: binaryFlags & GIT_DIFF_FLAG_BINARY.rawValue != 0
                    )
                )
            }

            let counts = try aheadBehind(repository)
            return GitRepositoryStatus(
                branch: branch,
                ahead: counts.ahead,
                behind: counts.behind,
                changes: changes.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending },
                hasConflicts: changes.contains { $0.state == .conflicted }
            )
        }
    }

    func diff(repository url: URL, path: String) async throws -> GitDiff {
        try withRepository(url) { repository in
            if let result = try patch(repository: repository, path: path, staged: false) {
                return result
            }
            if let result = try patch(repository: repository, path: path, staged: true) {
                return result
            }
            return GitDiff(path: path, text: "", isBinary: false, isTooLarge: false)
        }
    }

    func stage(repository url: URL, path: String) async throws {
        try withRepository(url) { repository in
            var index: OpaquePointer?
            try check(git_repository_index(&index, repository))
            defer { git_index_free(index) }
            let file = url.appendingPathComponent(path)
            let result = FileManager.default.fileExists(atPath: file.path)
                ? git_index_add_bypath(index, path)
                : git_index_remove_bypath(index, path)
            try check(result)
            try check(git_index_write(index))
        }
    }

    func unstage(repository url: URL, path: String) async throws {
        try withRepository(url) { repository in
            var head: OpaquePointer?
            try check(git_revparse_single(&head, repository, "HEAD"))
            defer { git_object_free(head) }
            try withStringArray([path]) { paths in
                var paths = paths
                try check(git_reset_default(repository, head, &paths))
            }
        }
    }

    func commit(
        repository url: URL,
        message: String,
        authorName: String,
        authorEmail: String
    ) async throws {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GitServiceError.invalidCommitMessage
        }
        try withRepository(url) { repository in
            try createCommit(
                repository: repository,
                message: message,
                name: authorName,
                email: authorEmail,
                mergeParent: nil
            )
        }
    }

    func fetch(repository url: URL, credentials: GitCredentials) async throws {
        try withRepository(url) { repository in
            try performFetch(repository, credentials: credentials)
        }
    }

    func pull(repository url: URL, credentials: GitCredentials) async throws -> PullResult {
        try withRepository(url) { repository in
            let existing = try workingChanges(repository)
            guard existing.isEmpty else { throw GitServiceError.dirtyWorkingTree }

            try performFetch(repository, credentials: credentials)
            let branch = try currentBranchName(repository)
            let remoteName = "refs/remotes/origin/\(branch)"
            var localOID = git_oid()
            var remoteOID = git_oid()
            try check(git_reference_name_to_id(&localOID, repository, "HEAD"))
            try check(git_reference_name_to_id(&remoteOID, repository, remoteName))

            var ahead: Int = 0
            var behind: Int = 0
            try check(git_graph_ahead_behind(&ahead, &behind, repository, &localOID, &remoteOID))
            if behind == 0 { return .upToDate }

            if ahead == 0 {
                var object: OpaquePointer?
                try check(git_object_lookup(&object, repository, &remoteOID, GIT_OBJECT_COMMIT))
                defer { git_object_free(object) }
                try check(git_reset(repository, object, GIT_RESET_HARD, nil))
                return .fastForward
            }

            var annotated: OpaquePointer?
            try check(git_annotated_commit_lookup(&annotated, repository, &remoteOID))
            defer { git_annotated_commit_free(annotated) }
            var mergeOptions = git_merge_options()
            var checkoutOptions = git_checkout_options()
            try check(git_merge_options_init(&mergeOptions, UInt32(GIT_MERGE_OPTIONS_VERSION)))
            try check(git_checkout_options_init(&checkoutOptions, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)))
            checkoutOptions.checkout_strategy =
                GIT_CHECKOUT_SAFE.rawValue |
                GIT_CHECKOUT_ALLOW_CONFLICTS.rawValue |
                GIT_CHECKOUT_CONFLICT_STYLE_MERGE.rawValue
            var head = annotated
            try withUnsafeMutablePointer(to: &head) { pointer in
                try check(git_merge(repository, pointer, 1, &mergeOptions, &checkoutOptions))
            }

            let found = try readConflicts(repository)
            if !found.isEmpty { return .conflicts(found) }

            try createCommit(
                repository: repository,
                message: "Merge origin/\(branch)",
                name: "Githulu",
                email: "noreply@users.noreply.github.com",
                mergeParent: remoteOID
            )
            try check(git_repository_state_cleanup(repository))
            return .merged
        }
    }

    func push(repository url: URL, credentials: GitCredentials) async throws {
        try withRepository(url) { repository in
            try performFetch(repository, credentials: credentials)
            let status = try aheadBehind(repository)
            if status.behind > 0 { throw GitServiceError.nonFastForward }

            let branch = try currentBranchName(repository)
            var remote: OpaquePointer?
            try check(git_remote_lookup(&remote, repository, "origin"))
            defer { git_remote_free(remote) }

            let payload = CredentialPayload(credentials, operation: .push)
            var options = git_push_options()
            try check(git_push_options_init(&options, UInt32(GIT_PUSH_OPTIONS_VERSION)))
            options.callbacks.credentials = gitCredentialCallback
            options.callbacks.push_transfer_progress = gitPushProgressCallback
            options.callbacks.payload = Unmanaged.passUnretained(payload).toOpaque()
            try withStringArray(["refs/heads/\(branch):refs/heads/\(branch)"]) { refspecs in
                var refspecs = refspecs
                try check(git_remote_push(remote, &refspecs, &options))
            }
            try configureUpstream(repository, branch: branch)
        }
    }

    func branches(repository url: URL) async throws -> [GitBranch] {
        try withRepository(url) { repository in
            let current = try currentBranchName(repository)
            var iterator: OpaquePointer?
            try check(git_branch_iterator_new(&iterator, repository, GIT_BRANCH_ALL))
            defer { git_branch_iterator_free(iterator) }
            var results: [GitBranch] = []

            while true {
                var reference: OpaquePointer?
                var type = GIT_BRANCH_LOCAL
                let result = git_branch_next(&reference, &type, iterator)
                if result == GIT_ITEROVER.rawValue { break }
                try check(result)
                guard let reference else { continue }
                defer { git_reference_free(reference) }
                var rawName: UnsafePointer<CChar>?
                try check(git_branch_name(&rawName, reference))
                guard let rawName else { continue }
                let name = String(cString: rawName)
                var upstream: OpaquePointer?
                let upstreamName: String? = if git_branch_upstream(&upstream, reference) == 0,
                                               let shorthand = git_reference_shorthand(upstream) {
                    String(cString: shorthand)
                } else {
                    nil
                }
                if let upstream { git_reference_free(upstream) }
                results.append(
                    GitBranch(
                        name: name,
                        isRemote: type == GIT_BRANCH_REMOTE,
                        isCurrent: type == GIT_BRANCH_LOCAL && name == current,
                        isMerged: type == GIT_BRANCH_REMOTE ? false : try isMerged(reference, intoHEADOf: repository),
                        upstream: upstreamName
                    )
                )
            }
            return results.sorted {
                if $0.isRemote != $1.isRemote { return !$0.isRemote }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
    }

    func createBranch(repository url: URL, name: String) async throws {
        try withRepository(url) { repository in
            var headOID = git_oid()
            try check(git_reference_name_to_id(&headOID, repository, "HEAD"))
            var commit: OpaquePointer?
            try check(git_commit_lookup(&commit, repository, &headOID))
            defer { git_commit_free(commit) }
            var branch: OpaquePointer?
            try check(git_branch_create(&branch, repository, name, commit, 0))
            if let branch { git_reference_free(branch) }
        }
    }

    func switchBranch(repository url: URL, name: String) async throws {
        try withRepository(url) { repository in
            guard try workingChanges(repository).isEmpty else {
                throw GitServiceError.dirtyWorkingTree
            }
            var branch: OpaquePointer?
            var localName = name
            let localLookup = git_branch_lookup(&branch, repository, name, GIT_BRANCH_LOCAL)
            if localLookup < 0 {
                var remoteBranch: OpaquePointer?
                try check(git_branch_lookup(&remoteBranch, repository, name, GIT_BRANCH_REMOTE))
                defer { git_reference_free(remoteBranch) }
                guard let remoteBranch,
                      let remoteOID = git_reference_target(remoteBranch)?.pointee
                else {
                    throw GitServiceError.libgit2("The remote branch has no target.")
                }
                localName = name.split(separator: "/", maxSplits: 1).last.map(String.init) ?? name
                var mutableOID = remoteOID
                var commit: OpaquePointer?
                try check(git_commit_lookup(&commit, repository, &mutableOID))
                defer { git_commit_free(commit) }
                try check(git_branch_create(&branch, repository, localName, commit, 0))
                try configureUpstream(repository, branch: localName)
            }
            defer { git_reference_free(branch) }
            guard let branch, let target = git_reference_target(branch)?.pointee else {
                throw GitServiceError.libgit2("The branch has no target.")
            }
            var object: OpaquePointer?
            var mutableTarget = target
            try check(git_object_lookup(&object, repository, &mutableTarget, GIT_OBJECT_COMMIT))
            defer { git_object_free(object) }
            var options = git_checkout_options()
            try check(git_checkout_options_init(&options, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)))
            options.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue
            try check(git_checkout_tree(repository, object, &options))
            try check(git_repository_set_head(repository, "refs/heads/\(localName)"))
        }
    }

    func deleteBranch(repository url: URL, name: String) async throws {
        try withRepository(url) { repository in
            if try currentBranchName(repository) == name {
                throw GitServiceError.currentBranchDeletion
            }
            var branch: OpaquePointer?
            try check(git_branch_lookup(&branch, repository, name, GIT_BRANCH_LOCAL))
            defer { git_reference_free(branch) }
            guard let branch else { throw GitServiceError.libgit2("Branch not found.") }
            guard try isMerged(branch, intoHEADOf: repository) else {
                throw GitServiceError.branchNotMerged
            }
            try check(git_branch_delete(branch))
        }
    }

    func conflicts(repository url: URL) async throws -> [GitConflict] {
        try withRepository(url) { repository in
            try readConflicts(repository)
        }
    }

    func resolve(repository url: URL, path: String, content: String) async throws {
        guard content.utf8.count <= Self.conflictLimit else {
            throw GitServiceError.unsupportedConflict(path)
        }
        let target = url.appendingPathComponent(path)
        try content.write(to: target, atomically: true, encoding: .utf8)
        try await stage(repository: url, path: path)
    }

    func completeMerge(
        repository url: URL,
        message: String,
        authorName: String,
        authorEmail: String
    ) async throws {
        try withRepository(url) { repository in
            let unresolved = try readConflicts(repository)
            guard unresolved.isEmpty else {
                throw GitServiceError.libgit2("Resolve every conflict before completing the merge.")
            }
            let branch = try currentBranchName(repository)
            var remoteOID = git_oid()
            try check(git_reference_name_to_id(&remoteOID, repository, "refs/remotes/origin/\(branch)"))
            try createCommit(
                repository: repository,
                message: message,
                name: authorName,
                email: authorEmail,
                mergeParent: remoteOID
            )
            try check(git_repository_state_cleanup(repository))
        }
    }
}

private extension LibGit2Service {
    func withRepository<T>(_ url: URL, body: (OpaquePointer) throws -> T) throws -> T {
        var repository: OpaquePointer?
        let result = git_repository_open(&repository, url.path)
        guard result == 0, let repository else {
            throw GitServiceError.invalidRepository
        }
        defer { git_repository_free(repository) }
        return try body(repository)
    }

    func check(_ result: Int32) throws {
        guard result >= 0 else {
            if result == GIT_EUSER.rawValue, Task.isCancelled {
                throw GitServiceError.cancelled
            }
            let message: String
            if let error = git_error_last(), let raw = error.pointee.message {
                message = String(cString: raw)
            } else {
                message = "libgit2 failed with code \(result)."
            }
            if message.localizedCaseInsensitiveContains("authentication") ||
                message.localizedCaseInsensitiveContains("401") {
                throw GitServiceError.authenticationFailed
            }
            throw GitServiceError.libgit2(message)
        }
    }

    func performFetch(_ repository: OpaquePointer, credentials: GitCredentials) throws {
        var remote: OpaquePointer?
        try check(git_remote_lookup(&remote, repository, "origin"))
        defer { git_remote_free(remote) }
        let payload = CredentialPayload(credentials, operation: .fetch)
        var options = git_fetch_options()
        try check(git_fetch_options_init(&options, UInt32(GIT_FETCH_OPTIONS_VERSION)))
        options.callbacks.credentials = gitCredentialCallback
        options.callbacks.transfer_progress = gitTransferCallback
        options.callbacks.payload = Unmanaged.passUnretained(payload).toOpaque()
        try check(git_remote_fetch(remote, nil, &options, nil))
    }

    func configureUpstream(_ repository: OpaquePointer, branch: String) throws {
        var config: OpaquePointer?
        try check(git_repository_config(&config, repository))
        defer { git_config_free(config) }
        try check(git_config_set_string(config, "branch.\(branch).remote", "origin"))
        try check(git_config_set_string(config, "branch.\(branch).merge", "refs/heads/\(branch)"))
    }

    func currentBranchName(_ repository: OpaquePointer) throws -> String {
        var head: OpaquePointer?
        try check(git_repository_head(&head, repository))
        defer { git_reference_free(head) }
        guard let name = git_reference_shorthand(head) else {
            throw GitServiceError.libgit2("Unable to read the current branch.")
        }
        return String(cString: name)
    }

    func aheadBehind(_ repository: OpaquePointer) throws -> (ahead: Int, behind: Int) {
        var head: OpaquePointer?
        try check(git_repository_head(&head, repository))
        defer { git_reference_free(head) }
        guard let local = git_reference_target(head)?.pointee else { return (0, 0) }
        var upstream: OpaquePointer?
        guard git_branch_upstream(&upstream, head) == 0,
              let remote = git_reference_target(upstream)?.pointee
        else {
            if let upstream { git_reference_free(upstream) }
            return (0, 0)
        }
        defer { git_reference_free(upstream) }
        var mutableLocal = local
        var mutableRemote = remote
        var ahead: Int = 0
        var behind: Int = 0
        try check(git_graph_ahead_behind(&ahead, &behind, repository, &mutableLocal, &mutableRemote))
        return (ahead, behind)
    }

    func workingChanges(_ repository: OpaquePointer) throws -> [String] {
        var options = git_status_options()
        try check(git_status_options_init(&options, UInt32(GIT_STATUS_OPTIONS_VERSION)))
        options.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR
        options.flags = GIT_STATUS_OPT_INCLUDE_UNTRACKED.rawValue
        var list: OpaquePointer?
        try check(git_status_list_new(&list, repository, &options))
        defer { git_status_list_free(list) }
        return (0..<git_status_list_entrycount(list)).compactMap { index in
            guard let entry = git_status_byindex(list, index)?.pointee,
                  entry.status != GIT_STATUS_CURRENT
            else { return nil }
            let path = entry.index_to_workdir?.pointee.new_file.path
                ?? entry.head_to_index?.pointee.new_file.path
            return path.map(String.init(cString:))
        }
    }

    func fileState(_ flags: UInt32) -> GitFileState {
        if flags & GIT_STATUS_CONFLICTED.rawValue != 0 { return .conflicted }
        if flags & GIT_STATUS_INDEX_NEW.rawValue != 0 { return .added }
        if flags & GIT_STATUS_WT_NEW.rawValue != 0 { return .untracked }
        if flags & (GIT_STATUS_INDEX_DELETED.rawValue | GIT_STATUS_WT_DELETED.rawValue) != 0 { return .deleted }
        if flags & (GIT_STATUS_INDEX_RENAMED.rawValue | GIT_STATUS_WT_RENAMED.rawValue) != 0 { return .renamed }
        if flags & (GIT_STATUS_INDEX_MODIFIED.rawValue | GIT_STATUS_WT_MODIFIED.rawValue) != 0 { return .modified }
        return .unknown
    }

    func patch(repository: OpaquePointer, path: String, staged: Bool) throws -> GitDiff? {
        var diff: OpaquePointer?
        if staged {
            var head: OpaquePointer?
            try check(git_revparse_single(&head, repository, "HEAD^{tree}"))
            defer { git_object_free(head) }
            try check(git_diff_tree_to_index(&diff, repository, head, nil, nil))
        } else {
            try check(git_diff_index_to_workdir(&diff, repository, nil, nil))
        }
        defer { git_diff_free(diff) }

        for index in 0..<git_diff_num_deltas(diff) {
            guard let delta = git_diff_get_delta(diff, index)?.pointee else { continue }
            guard let rawPath = delta.new_file.path ?? delta.old_file.path else { continue }
            let candidate = String(cString: rawPath)
            guard candidate == path else { continue }
            let isBinary = delta.flags & GIT_DIFF_FLAG_BINARY.rawValue != 0
            if isBinary { return GitDiff(path: path, text: nil, isBinary: true, isTooLarge: false) }

            var patch: OpaquePointer?
            try check(git_patch_from_diff(&patch, diff, index))
            defer { git_patch_free(patch) }
            var buffer = git_buf()
            try check(git_patch_to_buf(&buffer, patch))
            defer { git_buf_dispose(&buffer) }
            let size = Int(buffer.size)
            guard size <= Self.conflictLimit else {
                return GitDiff(path: path, text: nil, isBinary: false, isTooLarge: true)
            }
            let text = String(cString: buffer.ptr)
            return GitDiff(path: path, text: text, isBinary: false, isTooLarge: false)
        }
        return nil
    }

    func createCommit(
        repository: OpaquePointer,
        message: String,
        name: String,
        email: String,
        mergeParent: git_oid?
    ) throws {
        var index: OpaquePointer?
        try check(git_repository_index(&index, repository))
        defer { git_index_free(index) }
        guard git_index_has_conflicts(index) == 0 else {
            throw GitServiceError.libgit2("The index still contains conflicts.")
        }
        var treeOID = git_oid()
        try check(git_index_write_tree(&treeOID, index))
        try check(git_index_write(index))
        var tree: OpaquePointer?
        try check(git_tree_lookup(&tree, repository, &treeOID))
        defer { git_tree_free(tree) }

        var signature: UnsafeMutablePointer<git_signature>?
        try check(git_signature_now(&signature, name, email))
        defer { git_signature_free(signature) }

        var parents: [OpaquePointer?] = []
        var headOID = git_oid()
        if git_reference_name_to_id(&headOID, repository, "HEAD") == 0 {
            var parent: OpaquePointer?
            try check(git_commit_lookup(&parent, repository, &headOID))
            parents.append(parent)
        }
        if var mergeParent {
            var parent: OpaquePointer?
            try check(git_commit_lookup(&parent, repository, &mergeParent))
            parents.append(parent)
        }
        defer { parents.forEach { git_commit_free($0) } }

        var commitOID = git_oid()
        let parentCount = parents.count
        try parents.withUnsafeMutableBufferPointer { parentBuffer in
            try check(
                git_commit_create(
                    &commitOID,
                    repository,
                    "HEAD",
                    signature,
                    signature,
                    nil,
                    message,
                    tree,
                    parentCount,
                    parentBuffer.baseAddress
                )
            )
        }
    }

    func isMerged(_ branch: OpaquePointer, intoHEADOf repository: OpaquePointer) throws -> Bool {
        guard let branchOID = git_reference_target(branch)?.pointee else { return false }
        var headOID = git_oid()
        try check(git_reference_name_to_id(&headOID, repository, "HEAD"))
        var mutableBranch = branchOID
        return git_graph_descendant_of(repository, &headOID, &mutableBranch) == 1 ||
            git_oid_equal(&headOID, &mutableBranch) == 1
    }

    func readConflicts(_ repository: OpaquePointer) throws -> [GitConflict] {
        var index: OpaquePointer?
        try check(git_repository_index(&index, repository))
        defer { git_index_free(index) }
        guard git_index_has_conflicts(index) != 0 else { return [] }
        var iterator: OpaquePointer?
        try check(git_index_conflict_iterator_new(&iterator, index))
        defer { git_index_conflict_iterator_free(iterator) }
        var results: [GitConflict] = []

        while true {
            var ancestor: UnsafePointer<git_index_entry>?
            var ours: UnsafePointer<git_index_entry>?
            var theirs: UnsafePointer<git_index_entry>?
            let result = git_index_conflict_next(&ancestor, &ours, &theirs, iterator)
            if result == GIT_ITEROVER.rawValue { break }
            try check(result)
            let rawPath = ours?.pointee.path ?? theirs?.pointee.path ?? ancestor?.pointee.path
            guard let rawPath else { continue }
            let path = String(cString: rawPath)
            let ancestorText = try blobText(repository, entry: ancestor)
            let oursText = try blobText(repository, entry: ours)
            let theirsText = try blobText(repository, entry: theirs)
            let texts = [ancestorText, oursText, theirsText]
            results.append(
                GitConflict(
                    path: path,
                    ancestor: ancestorText?.text,
                    ours: oursText?.text,
                    theirs: theirsText?.text,
                    isBinary: texts.contains { $0?.binary == true },
                    isTooLarge: texts.contains { $0?.tooLarge == true }
                )
            )
        }
        return results
    }

    func blobText(
        _ repository: OpaquePointer,
        entry: UnsafePointer<git_index_entry>?
    ) throws -> (text: String?, binary: Bool, tooLarge: Bool)? {
        guard var oid = entry?.pointee.id else { return nil }
        var blob: OpaquePointer?
        try check(git_blob_lookup(&blob, repository, &oid))
        defer { git_blob_free(blob) }
        let size = Int(git_blob_rawsize(blob))
        if size > Self.conflictLimit { return (nil, false, true) }
        guard let content = git_blob_rawcontent(blob) else { return ("", false, false) }
        let data = Data(bytes: content, count: size)
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            return (nil, true, false)
        }
        return (text, false, false)
    }

    func withStringArray<T>(_ strings: [String], body: (git_strarray) throws -> T) throws -> T {
        let copies = strings.map { strdup($0) }
        defer { copies.forEach { free($0) } }
        var mutable = copies
        return try mutable.withUnsafeMutableBufferPointer { buffer in
            try body(git_strarray(strings: buffer.baseAddress, count: strings.count))
        }
    }
}
