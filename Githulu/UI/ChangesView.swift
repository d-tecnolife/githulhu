import SwiftUI

struct ChangesView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    let repository: URL
    @ObservedObject var model: RepositoryViewModel

    @State private var message = ""
    @State private var selectedChange: GitFileChange?
    @State private var diff: GitDiff?
    @State private var authorName = "Githulu User"
    @State private var authorEmail = "noreply@users.noreply.github.com"

    private var stagedCount: Int {
        model.changes.filter(\.isStaged).count
    }

    var body: some View {
        NavigationStack {
            List {
                if model.changes.isEmpty {
                    ContentUnavailableView(
                        "Working tree clean",
                        systemImage: "checkmark.circle",
                        description: Text("There are no changes to commit.")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    Section("Files") {
                        ForEach(model.changes) { change in
                            HStack {
                                Button {
                                    Task { await toggleStage(change) }
                                } label: {
                                    Image(systemName: change.isStaged ? "checkmark.square.fill" : "square")
                                        .font(.title3)
                                }
                                .buttonStyle(.plain)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(change.path)
                                        .font(.subheadline)
                                        .lineLimit(2)
                                    Text(change.state.rawValue.capitalized)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    selectedChange = change
                                    Task { await loadDiff(change) }
                                } label: {
                                    Image(systemName: "doc.text.magnifyingglass")
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("View diff for \(change.path)")
                            }
                        }
                    }
                    Section("Commit") {
                        TextField("Commit message", text: $message, axis: .vertical)
                            .lineLimit(2...5)
                        Button("Commit \(stagedCount) file\(stagedCount == 1 ? "" : "s")") {
                            Task { await commit() }
                        }
                        .disabled(stagedCount == 0 || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .navigationTitle("Changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $selectedChange) { change in
                DiffView(change: change, diff: diff)
            }
            .onAppear {
                authorName = app.account?.name ?? app.account?.login ?? "Githulu User"
            }
        }
    }

    private func toggleStage(_ change: GitFileChange) async {
        do {
            if change.isStaged {
                try await app.git.unstage(repository: repository, path: change.path)
            } else {
                try await app.git.stage(repository: repository, path: change.path)
            }
            try await model.refresh(app: app)
        } catch {
            app.report(error)
        }
    }

    private func loadDiff(_ change: GitFileChange) async {
        do {
            diff = try await app.git.diff(repository: repository, path: change.path)
        } catch {
            app.report(error)
        }
    }

    private func commit() async {
        await model.run(app: app, success: "Commit created") {
            try await app.git.commit(
                repository: repository,
                message: message,
                authorName: authorName,
                authorEmail: authorEmail
            )
        }
        if app.errorMessage == nil {
            message = ""
            dismiss()
        }
    }
}

private struct DiffView: View {
    @Environment(\.dismiss) private var dismiss
    let change: GitFileChange
    let diff: GitDiff?

    var body: some View {
        NavigationStack {
            Group {
                if let diff {
                    if diff.isBinary {
                        ContentUnavailableView(
                            "Binary file",
                            systemImage: "doc.badge.ellipsis",
                            description: Text("A text diff is not available.")
                        )
                    } else if diff.isTooLarge {
                        ContentUnavailableView(
                            "Diff too large",
                            systemImage: "doc.text",
                            description: Text("Open this file in another app to review it.")
                        )
                    } else {
                        ScrollView([.horizontal, .vertical]) {
                            Text(diff.text ?? "")
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(change.path)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
