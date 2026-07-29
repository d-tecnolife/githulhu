import SwiftData
import SwiftUI

@MainActor
final class RepositoryViewModel: ObservableObject {
    @Published var status: GitRepositoryStatus?
    @Published var changes: [GitFileChange] = []
    @Published var branches: [GitBranch] = []
    @Published var conflicts: [GitConflict] = []
    @Published var isWorking = false
    @Published var lastResult: String?

    let record: RepositoryRecord
    private var scopedURL: ScopedURL?

    init(record: RepositoryRecord) {
        self.record = record
    }

    var url: URL? { scopedURL?.url }

    func load(app: AppModel) async {
        do {
            if scopedURL == nil {
                scopedURL = try app.scopedURL(for: record)
            }
            try await refresh(app: app)
        } catch {
            app.report(error)
        }
    }

    func refresh(app: AppModel) async throws {
        guard let url else { throw BookmarkError.accessDenied }
        let status = try await app.git.status(repository: url)
        self.status = status
        changes = status.changes
        record.lastBranch = status.branch
        record.lastOpenedAt = .now
    }

    func run(
        app: AppModel,
        success: String,
        operation: () async throws -> Void
    ) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await operation()
            lastResult = success
            try await refresh(app: app)
        } catch {
            app.report(error)
        }
    }

    func pull(app: AppModel) async {
        isWorking = true
        defer { isWorking = false }
        do {
            guard let url else { throw BookmarkError.accessDenied }
            let result = try await app.git.pull(repository: url, credentials: app.credentials())
            switch result {
            case .upToDate:
                lastResult = "Already up to date"
            case .fastForward:
                lastResult = "Fast-forwarded"
            case .merged:
                lastResult = "Merged remote changes"
            case .conflicts(let conflicts):
                self.conflicts = conflicts
                lastResult = "Resolve \(conflicts.count) conflict\(conflicts.count == 1 ? "" : "s")"
            }
            try await refresh(app: app)
        } catch {
            app.report(error)
        }
    }

    func push(app: AppModel) async {
        await run(app: app, success: "Push complete") {
            guard let url else { throw BookmarkError.accessDenied }
            try await app.git.push(repository: url, credentials: app.credentials())
        }
    }

    func fetch(app: AppModel) async {
        await run(app: app, success: "Remote status updated") {
            guard let url else { throw BookmarkError.accessDenied }
            try await app.git.fetch(repository: url, credentials: app.credentials())
        }
    }

    func fetchBranches(app: AppModel) async {
        do {
            guard let url else { throw BookmarkError.accessDenied }
            branches = try await app.git.branches(repository: url)
        } catch {
            app.report(error)
        }
    }
}

struct RepositoryView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.modelContext) private var modelContext
    @StateObject private var model: RepositoryViewModel
    @State private var showingChanges = false
    @State private var showingBranches = false
    @State private var showingConflicts = false
    @State private var showingFiles = false

    init(record: RepositoryRecord) {
        _model = StateObject(wrappedValue: RepositoryViewModel(record: record))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                summaryCard
                primaryActions
                if let result = model.lastResult {
                    Label(result, systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
                filesCard
                changesCard
                if model.status?.hasConflicts == true || !model.conflicts.isEmpty {
                    conflictCard
                }
            }
            .padding()
        }
        .navigationTitle(model.record.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            repositoryStatusBar
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button {
                        Task { await logged(.fetch) { await model.fetch(app: app) } }
                    } label: {
                        Label("Fetch", systemImage: "arrow.down.to.line")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Repository actions")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { try? await model.refresh(app: app) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(model.isWorking)
                .accessibilityLabel("Refresh repository")
            }
        }
        .overlay {
            if model.isWorking {
                ProgressView()
                    .controlSize(.large)
                    .padding(22)
                    .background(.regularMaterial, in: Circle())
            }
        }
        .task { await model.load(app: app) }
        .sheet(isPresented: $showingChanges) {
            if let url = model.url {
                ChangesView(repository: url, model: model)
            }
        }
        .sheet(isPresented: $showingFiles) {
            if let url = model.url {
                RepositoryBrowserView(repository: url)
            }
        }
        .sheet(isPresented: $showingBranches) {
            if let url = model.url {
                BranchesView(repository: url, model: model)
            }
        }
        .sheet(isPresented: $showingConflicts) {
            if let url = model.url {
                ConflictListView(repository: url, model: model)
            }
        }
        .onChange(of: model.record.lastBranch) {
            try? modelContext.save()
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    showingBranches = true
                    Task { await model.fetchBranches(app: app) }
                } label: {
                    HStack(spacing: 6) {
                        Label(
                            model.status?.branch ?? "Loading…",
                            systemImage: "arrow.triangle.branch"
                        )
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .font(.headline)
                }
                .buttonStyle(.plain)
                .disabled(model.url == nil)
                .accessibilityHint("Opens branch switching and management")
                Spacer()
                if let status = model.status {
                    Text(workingTreeLabel(status))
                        .font(.caption)
                        .foregroundStyle(
                            status.changes.isEmpty ? Color.secondary : Color.orange
                        )
                }
            }
            if let status = model.status {
                HStack(spacing: 18) {
                    Label(
                        status.ahead == 0 ? "Nothing to push" : "\(status.ahead) to push",
                        systemImage: "arrow.up"
                    )
                    Label(
                        status.behind == 0 ? "Nothing to pull" : "\(status.behind) to pull",
                        systemImage: "arrow.down"
                    )
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
        .cardStyle()
    }

    private var primaryActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                actionButton("Pull", icon: "arrow.down.circle.fill") {
                    await logged(.pull) { await model.pull(app: app) }
                }
                actionButton("Commit", icon: "checkmark.circle.fill") {
                    showingChanges = true
                }
                actionButton("Push", icon: "arrow.up.circle.fill") {
                    await logged(.push) { await model.push(app: app) }
                }
            }
            VStack(spacing: 10) {
                actionButton("Pull", icon: "arrow.down.circle.fill") {
                    await logged(.pull) { await model.pull(app: app) }
                }
                actionButton("Commit", icon: "checkmark.circle.fill") {
                    showingChanges = true
                }
                actionButton("Push", icon: "arrow.up.circle.fill") {
                    await logged(.push) { await model.push(app: app) }
                }
            }
        }
    }

    private func actionButton(
        _ title: String,
        icon: String,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.isWorking || model.url == nil)
    }

    private var changesCard: some View {
        Button {
            showingChanges = true
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Changes", systemImage: "doc.text.magnifyingglass")
                        .font(.headline)
                    Spacer()
                    Text("\(model.changes.count)")
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                }
                Text(
                    model.changes.isEmpty
                        ? "Your working tree is clean."
                        : "Review files and choose what to include in your next commit."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .cardStyle()
        }
        .buttonStyle(.plain)
    }

    private var filesCard: some View {
        Button {
            showingFiles = true
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Repository Files", systemImage: "folder")
                        .font(.headline)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                }
            }
            .cardStyle()
        }
        .buttonStyle(.plain)
        .disabled(model.url == nil)
    }

    private var conflictCard: some View {
        Button {
            showingConflicts = true
        } label: {
            HStack {
                Label("Resolve conflicts", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Spacer()
                Image(systemName: "chevron.right")
            }
            .cardStyle()
        }
        .buttonStyle(.plain)
    }

    private func logged(_ kind: GitOperationKind, action: () async -> Void) async {
        app.errorMessage = nil
        let record = OperationRecord(
            repositoryID: model.record.id,
            kind: kind,
            state: .running,
            message: "\(kind.rawValue.capitalized) started"
        )
        modelContext.insert(record)
        try? modelContext.save()
        await action()
        record.state = app.errorMessage == nil
            ? GitOperationState.succeeded.rawValue
            : GitOperationState.failed.rawValue
        record.message = model.lastResult ?? app.errorMessage ?? "\(kind.rawValue.capitalized) finished"
        record.finishedAt = .now
        try? modelContext.save()
    }

    private var repositoryStatusBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusBarText)
                .font(.footnote.weight(.medium))
                .lineLimit(2)
            Spacer()
            if model.isWorking {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(.bar)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(statusBarText)
    }

    private var statusBarText: String {
        guard let status = model.status else { return "Checking repository status…" }
        let staged = status.changes.filter(\.isStaged).count
        if status.hasConflicts {
            return "Conflicts need to be resolved before you can continue"
        }
        if !status.changes.isEmpty {
            let stagedText = staged > 0 ? " · \(staged) selected for commit" : ""
            let pushText = status.ahead > 0 ? " · \(status.ahead) ready to push" : ""
            return "\(status.changes.count) uncommitted change\(status.changes.count == 1 ? "" : "s")\(stagedText)\(pushText)"
        }
        if status.ahead > 0 {
            return "\(status.ahead) commit\(status.ahead == 1 ? "" : "s") ready to push"
        }
        if status.behind > 0 {
            return "\(status.behind) commit\(status.behind == 1 ? "" : "s") available to pull"
        }
        return "Working tree clean · Up to date"
    }

    private var statusColor: Color {
        guard let status = model.status else { return .secondary }
        if status.hasConflicts { return .red }
        if !status.changes.isEmpty { return .orange }
        if status.ahead > 0 || status.behind > 0 { return .blue }
        return .green
    }

    private func workingTreeLabel(_ status: GitRepositoryStatus) -> String {
        status.changes.isEmpty
            ? "Working tree clean"
            : "\(status.changes.count) uncommitted"
    }
}

private extension View {
    func cardStyle() -> some View {
        self
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 16))
    }
}
