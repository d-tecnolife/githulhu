import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    private enum FolderPickerAction {
        case openExisting
        case cloneDestination
    }

    private enum PickerPrompt: String, Identifiable, Equatable {
        case openExisting
        case cloneDestination

        var id: String { rawValue }
    }

    @EnvironmentObject private var app: AppModel
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RepositoryRecord.lastOpenedAt, order: .reverse)
    private var repositories: [RepositoryRecord]
    @Query private var operationHistory: [OperationRecord]

    @State private var showingFolderPicker = false
    @State private var folderPickerAction: FolderPickerAction?
    @State private var showingRepositoryPicker = false
    @State private var cloneSelection: GitHubRepository?
    @State private var activeCloneTask: Task<Void, Never>?
    @State private var pickerPrompt: PickerPrompt?
    @State private var quickCommitRecord: RepositoryRecord?
    @State private var rowStatuses: [UUID: GitRepositoryStatus] = [:]
    @State private var rowResults: [UUID: String] = [:]
    @State private var workingRepositoryIDs: Set<UUID> = []
    @State private var duplicateRepositoryName: String?

    var body: some View {
        Group {
            if app.isRestoringSession {
                ProgressView("Restoring GitHub session…")
            } else if app.isSignedIn {
                repositoryNavigation
            } else {
                SignedOutView(
                    isAuthenticating: app.isAuthenticating,
                    signIn: app.beginSignIn
                )
            }
        }
        .task {
            await app.restoreSession()
        }
        .alert("Githulhu", isPresented: errorPresented) {
            Button("OK") { app.errorMessage = nil }
        } message: {
            Text(app.errorMessage ?? "")
        }
        .alert("Repository already added", isPresented: duplicatePresented) {
            Button("OK") { duplicateRepositoryName = nil }
        } message: {
            Text("\(duplicateRepositoryName ?? "This repository") is already in your repository list.")
        }
        .overlay {
            if let operation = app.operation {
                OperationOverlay(progress: operation) {
                    activeCloneTask?.cancel()
                }
            }
        }
    }

    private var repositoryNavigation: some View {
        NavigationStack {
            Group {
                if repositories.isEmpty {
                    ContentUnavailableView {
                        Label("No repositories", systemImage: "shippingbox")
                    } description: {
                        Text("Clone from GitHub or open a repository from Files.")
                    } actions: {
                        repositoryActions
                    }
                } else {
                    List {
                        ForEach(repositories) { repository in
                            NavigationLink {
                                RepositoryView(record: repository)
                            } label: {
                                RepositoryRow(
                                    repository: repository,
                                    status: rowStatuses[repository.id],
                                    result: rowResults[repository.id],
                                    isWorking: workingRepositoryIDs.contains(repository.id)
                                )
                            }
                            .contextMenu {
                                Button {
                                    quickCommitRecord = repository
                                } label: {
                                    Label("Review & Commit", systemImage: "checkmark.circle")
                                }
                                Button {
                                    runQuickAction(.pull, for: repository)
                                } label: {
                                    Label("Pull", systemImage: "arrow.down.circle")
                                }
                                Button {
                                    runQuickAction(.push, for: repository)
                                } label: {
                                    Label("Push", systemImage: "arrow.up.circle")
                                }
                            }
                        }
                        .onDelete(perform: removeRepositories)
                    }
                    .refreshable {
                        await app.refreshRepositories()
                        await refreshRowStatuses()
                    }
                }
            }
            .navigationTitle("Githulhu")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    accountMenu
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        repositoryActions
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add repository")
                }
            }
            .task {
                recoverInterruptedOperations()
                await refreshRowStatuses()
            }
            .sheet(
                isPresented: $showingRepositoryPicker,
                onDismiss: {
                    if cloneSelection != nil {
                        pickerPrompt = .cloneDestination
                    }
                }
            ) {
                GitHubRepositoryPicker { repository in
                    cloneSelection = repository
                    showingRepositoryPicker = false
                }
            }
            .fileImporter(
                isPresented: $showingFolderPicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false,
                onCompletion: handleFolderSelection
            )
            .sheet(item: $pickerPrompt) { prompt in
                FolderPickerPrompt(
                    isCloneDestination: prompt == .cloneDestination,
                    continueAction: {
                        pickerPrompt = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            presentFolderPicker(
                                prompt == .cloneDestination ? .cloneDestination : .openExisting
                            )
                        }
                    },
                    cancelAction: {
                        pickerPrompt = nil
                        if prompt == .cloneDestination {
                            cloneSelection = nil
                        }
                    }
                )
                .presentationDetents([.height(300)])
            }
            .sheet(item: $quickCommitRecord) { repository in
                QuickCommitContainer(record: repository)
            }
        }
    }

    @ViewBuilder
    private var repositoryActions: some View {
        Button {
            if app.isSignedIn {
                cloneSelection = nil
                showingRepositoryPicker = true
            } else {
                app.beginSignIn()
            }
        } label: {
            Label("Clone from GitHub", systemImage: "square.and.arrow.down")
        }
        Button {
            pickerPrompt = .openExisting
        } label: {
            Label("Open from Files", systemImage: "folder")
        }
    }

    private var accountMenu: some View {
        Menu {
            if let account = app.account {
                Text("@\(account.login)")
                Button("Refresh GitHub repositories") {
                    Task { await app.refreshRepositories() }
                }
                Button("Sign out", role: .destructive) {
                    app.signOut()
                }
            } else {
                Button("Sign in to GitHub") {
                    app.beginSignIn()
                }
            }
        } label: {
            Image(systemName: app.isSignedIn ? "person.crop.circle.fill" : "person.crop.circle")
        }
        .accessibilityLabel(app.isSignedIn ? "GitHub account" : "Sign in to GitHub")
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { app.errorMessage != nil },
            set: { if !$0 { app.errorMessage = nil } }
        )
    }

    private var duplicatePresented: Binding<Bool> {
        Binding(
            get: { duplicateRepositoryName != nil },
            set: { if !$0 { duplicateRepositoryName = nil } }
        )
    }

    private func openExisting(_ result: Result<[URL], Error>) {
        Task {
            do {
                guard let url = try result.get().first else { return }
                if let existing = existingRecord(for: url) {
                    existing.lastOpenedAt = .now
                    try? modelContext.save()
                    duplicateRepositoryName = existing.displayName
                    return
                }
                let record = try await app.registerExisting(folder: url)
                modelContext.insert(record)
                try modelContext.save()
                await refreshRowStatus(for: record)
            } catch {
                app.report(error)
            }
        }
    }

    private func presentFolderPicker(_ action: FolderPickerAction) {
        folderPickerAction = action
        showingFolderPicker = true
    }

    private func handleFolderSelection(_ result: Result<[URL], Error>) {
        guard let action = folderPickerAction else { return }
        folderPickerAction = nil
        switch action {
        case .openExisting:
            openExisting(result)
        case .cloneDestination:
            chooseCloneDestination(result)
        }
    }

    private func chooseCloneDestination(_ result: Result<[URL], Error>) {
        activeCloneTask = Task {
            defer { activeCloneTask = nil }
            defer { cloneSelection = nil }
            do {
                guard let repository = cloneSelection,
                      let destination = try result.get().first
                else { return }
                let record = try await app.clone(repository, inside: destination)
                modelContext.insert(record)
                try modelContext.save()
                await refreshRowStatus(for: record)
            } catch {
                app.report(error)
            }
        }
    }

    private func removeRepositories(at offsets: IndexSet) {
        offsets.forEach { modelContext.delete(repositories[$0]) }
        try? modelContext.save()
    }

    private func recoverInterruptedOperations() {
        var changed = false
        for operation in operationHistory where operation.state == GitOperationState.running.rawValue {
            operation.state = GitOperationState.interrupted.rawValue
            operation.message = "The app closed before this operation finished. Retry when ready."
            operation.finishedAt = .now
            changed = true
        }
        if changed { try? modelContext.save() }
    }

    private func existingRecord(for selectedURL: URL) -> RepositoryRecord? {
        let selectedPath = normalizedPath(selectedURL)
        return repositories.first { record in
            guard let scoped = try? app.scopedURL(for: record) else { return false }
            return normalizedPath(scoped.url) == selectedPath
        }
    }

    private func normalizedPath(_ url: URL) -> String {
        RepositoryLocation.normalizedPath(url)
    }

    private func refreshRowStatuses() async {
        for repository in repositories {
            await refreshRowStatus(for: repository)
        }
    }

    private func refreshRowStatus(for repository: RepositoryRecord) async {
        guard let scoped = try? app.scopedURL(for: repository),
              let status = try? await app.git.status(repository: scoped.url)
        else { return }
        rowStatuses[repository.id] = status
        repository.lastBranch = status.branch
        try? modelContext.save()
    }

    private func runQuickAction(_ kind: GitOperationKind, for repository: RepositoryRecord) {
        guard !workingRepositoryIDs.contains(repository.id) else { return }
        Task {
            workingRepositoryIDs.insert(repository.id)
            defer { workingRepositoryIDs.remove(repository.id) }
            app.errorMessage = nil
            let log = OperationRecord(
                repositoryID: repository.id,
                kind: kind,
                state: .running,
                message: "\(kind.rawValue.capitalized) started"
            )
            modelContext.insert(log)
            try? modelContext.save()
            do {
                let scoped = try app.scopedURL(for: repository)
                switch kind {
                case .pull:
                    let result = try await app.git.pull(
                        repository: scoped.url,
                        credentials: app.credentials()
                    )
                    switch result {
                    case .upToDate: rowResults[repository.id] = "Already up to date"
                    case .fastForward: rowResults[repository.id] = "Pull complete"
                    case .merged: rowResults[repository.id] = "Remote changes merged"
                    case .conflicts(let conflicts):
                        rowResults[repository.id] = "\(conflicts.count) conflicts need attention"
                    }
                case .push:
                    try await app.git.push(
                        repository: scoped.url,
                        credentials: app.credentials()
                    )
                    rowResults[repository.id] = "Push complete"
                default:
                    return
                }
                log.state = GitOperationState.succeeded.rawValue
                log.message = rowResults[repository.id] ?? "\(kind.rawValue.capitalized) complete"
                await refreshRowStatus(for: repository)
            } catch {
                log.state = GitOperationState.failed.rawValue
                log.message = error.localizedDescription
                app.report(error)
            }
            log.finishedAt = .now
            try? modelContext.save()
        }
    }
}

private struct SignedOutView: View {
    let isAuthenticating: Bool
    let signIn: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            Text("Githulhu")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))

            Button(action: signIn) {
                if isAuthenticating {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("Signing in to GitHub")
                } else {
                    Label("Sign in to GitHub", systemImage: "person.crop.circle.badge.checkmark")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isAuthenticating)
            .accessibilityHint("Connects your GitHub account to Githulhu")
        }
        .padding(32)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RepositoryRow: View {
    let repository: RepositoryRecord
    let status: GitRepositoryStatus?
    let result: String?
    let isWorking: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 36, height: 36)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text(repository.displayName)
                    .font(.headline)
                if let branch = repository.lastBranch {
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let status {
                    Text(statusText(status))
                        .font(.caption)
                        .foregroundStyle(status.changes.isEmpty ? .secondary : .orange)
                } else if let result {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isWorking {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private func statusText(_ status: GitRepositoryStatus) -> String {
        if !status.changes.isEmpty {
            return "\(status.changes.count) uncommitted change\(status.changes.count == 1 ? "" : "s")"
        }
        if status.ahead > 0 {
            return "\(status.ahead) commit\(status.ahead == 1 ? "" : "s") ready to push"
        }
        if status.behind > 0 {
            return "\(status.behind) commit\(status.behind == 1 ? "" : "s") available to pull"
        }
        return "Up to date"
    }
}

private struct FolderPickerPrompt: View {
    let isCloneDestination: Bool
    let continueAction: () -> Void
    let cancelAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: isCloneDestination ? "folder.badge.plus" : "folder")
                .font(.largeTitle)
                .foregroundStyle(.tint)
            Text(isCloneDestination ? "Choose where to save the repository" : "Choose a repository folder")
                .font(.title2.bold())
            Text(
                isCloneDestination
                    ? "Files will open next. Browse to the parent folder where Githulhu should create the cloned repository, then tap Open."
                    : "Files will open next. Select the folder that already contains the .git repository, then tap Open."
            )
            .foregroundStyle(.secondary)
            Spacer()
            HStack {
                Button("Cancel", role: .cancel, action: cancelAction)
                Spacer()
                Button("Choose Folder", action: continueAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
    }
}

private struct QuickCommitContainer: View {
    @EnvironmentObject private var app: AppModel
    let record: RepositoryRecord
    @StateObject private var model: RepositoryViewModel

    init(record: RepositoryRecord) {
        self.record = record
        _model = StateObject(wrappedValue: RepositoryViewModel(record: record))
    }

    var body: some View {
        Group {
            if let url = model.url {
                ChangesView(repository: url, model: model)
            } else {
                ProgressView("Opening \(record.displayName)…")
            }
        }
        .task { await model.load(app: app) }
    }
}

private struct OperationOverlay: View {
    let progress: GitProgress
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            if let fraction = progress.fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView()
            }
            Text(progress.message)
                .font(.subheadline)
            Button("Cancel", role: .cancel, action: cancel)
        }
        .padding(24)
        .frame(maxWidth: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(radius: 12)
        .accessibilityElement(children: .combine)
    }
}
