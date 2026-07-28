import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RepositoryRecord.lastOpenedAt, order: .reverse)
    private var repositories: [RepositoryRecord]
    @Query private var operationHistory: [OperationRecord]

    @State private var showingOpenPicker = false
    @State private var showingRepositoryPicker = false
    @State private var cloneSelection: GitHubRepository?
    @State private var showingCloneDestination = false
    @State private var activeCloneTask: Task<Void, Never>?

    var body: some View {
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
                    .refreshable { await app.restoreSession() }
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
                await app.restoreSession()
            }
            .sheet(isPresented: $showingRepositoryPicker) {
                GitHubRepositoryPicker { repository in
                    showingRepositoryPicker = false
                    cloneSelection = repository
                    showingCloneDestination = true
                }
            }
            .fileImporter(
                isPresented: $showingOpenPicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false,
                onCompletion: openExisting
            )
            .fileImporter(
                isPresented: $showingCloneDestination,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false,
                onCompletion: chooseCloneDestination
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
    }

    @ViewBuilder
    private var repositoryActions: some View {
        Button {
            if app.isSignedIn {
                showingRepositoryPicker = true
            } else {
                Task { await app.beginSignIn() }
            }
        } label: {
            Label("Clone from GitHub", systemImage: "square.and.arrow.down")
        }
        Button {
            showingOpenPicker = true
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
            .sheet(
                item: $app.authorization,
                onDismiss: { app.cancelSignIn() },
                content: { authorization in
                    DeviceAuthorizationView(authorization: authorization)
                        .onAppear { app.awaitSignIn() }
                }
            )
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

    private func chooseCloneDestination(_ result: Result<[URL], Error>) {
        activeCloneTask = Task {
            defer { activeCloneTask = nil }
            do {
                guard let repository = cloneSelection,
                      let destination = try result.get().first
                else { return }
                let record = try await app.clone(repository, inside: destination)
                modelContext.insert(record)
                try modelContext.save()
                cloneSelection = nil
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
