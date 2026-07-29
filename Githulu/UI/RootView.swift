import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    private enum FolderPickerAction {
        case openExisting
        case cloneDestination
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

    var body: some View {
        Group {
            if app.isRestoringSession {
                ProgressView("Restoring GitHub session…")
            } else if app.isSignedIn {
                repositoryNavigation
            } else {
                SignedOutView {
                    Task { await app.beginSignIn() }
                }
            }
        }
        .task {
            await app.restoreSession()
        }
        .sheet(
            item: $app.authorization,
            onDismiss: { app.cancelSignIn() },
            content: { authorization in
                DeviceAuthorizationView(authorization: authorization)
                    .onAppear { app.awaitSignIn() }
            }
        )
        .alert("Githulu", isPresented: errorPresented) {
            Button("OK") { app.errorMessage = nil }
        } message: {
            Text(app.errorMessage ?? "")
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
                                RepositoryRow(repository: repository)
                            }
                        }
                        .onDelete(perform: removeRepositories)
                    }
                    .refreshable { await app.refreshRepositories() }
                }
            }
            .navigationTitle("Githulu")
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
            }
            .sheet(
                isPresented: $showingRepositoryPicker,
                onDismiss: {
                    if cloneSelection != nil {
                        presentFolderPicker(.cloneDestination)
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
        }
    }

    @ViewBuilder
    private var repositoryActions: some View {
        Button {
            if app.isSignedIn {
                cloneSelection = nil
                showingRepositoryPicker = true
            } else {
                Task { await app.beginSignIn() }
            }
        } label: {
            Label("Clone from GitHub", systemImage: "square.and.arrow.down")
        }
        Button {
            presentFolderPicker(.openExisting)
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
                    Task { await app.beginSignIn() }
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

    private func openExisting(_ result: Result<[URL], Error>) {
        Task {
            do {
                guard let url = try result.get().first else { return }
                let record = try await app.registerExisting(folder: url)
                modelContext.insert(record)
                try modelContext.save()
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
}

private struct SignedOutView: View {
    let signIn: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            Text("Githulu")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))

            Button(action: signIn) {
                Label("Sign in to GitHub", systemImage: "person.crop.circle.badge.checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityHint("Connects your GitHub account to Githulu")
        }
        .padding(32)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RepositoryRow: View {
    let repository: RepositoryRecord

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
            }
        }
        .padding(.vertical, 4)
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
