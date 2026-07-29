import SwiftUI

struct BranchesView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    let repository: URL
    @ObservedObject var model: RepositoryViewModel

    @State private var newBranchName = ""
    @State private var branchToDelete: GitBranch?

    var body: some View {
        NavigationStack {
            List {
                Section("Create branch") {
                    HStack {
                        TextField("Branch name", text: $newBranchName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Create") {
                            Task { await create() }
                        }
                        .disabled(newBranchName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Section("Local") {
                    ForEach(model.branches.filter { !$0.isRemote }) { branch in
                        branchRow(branch)
                    }
                }
                Section("Remote") {
                    ForEach(model.branches.filter(\.isRemote)) { branch in
                        branchRow(branch)
                    }
                }
            }
            .navigationTitle("Branches")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Delete \(branchToDelete?.name ?? "branch")?",
                isPresented: Binding(
                    get: { branchToDelete != nil },
                    set: { if !$0 { branchToDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete branch", role: .destructive) {
                    if let branch = branchToDelete {
                        Task { await delete(branch) }
                    }
                    branchToDelete = nil
                }
                Button("Cancel", role: .cancel) { branchToDelete = nil }
            } message: {
                Text("Only branches already merged into the current branch can be deleted.")
            }
        }
        .task { await model.fetchBranches(app: app) }
    }

    private func branchRow(_ branch: GitBranch) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(branch.name)
                    if branch.isCurrent {
                        Text("CURRENT")
                            .font(.caption2.bold())
                            .foregroundStyle(.tint)
                    }
                }
                if let upstream = branch.upstream {
                    Text("Tracks \(upstream)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !branch.isCurrent {
                Button(branch.isRemote ? "Track" : "Switch") {
                    Task { await switchTo(branch) }
                }
                .buttonStyle(.borderless)
            }
        }
        .swipeActions {
            if !branch.isRemote && !branch.isCurrent {
                Button("Delete", role: .destructive) {
                    branchToDelete = branch
                }
                .disabled(!branch.isMerged)
            }
        }
    }

    private func create() async {
        do {
            try await app.git.createBranch(repository: repository, name: newBranchName)
            newBranchName = ""
            await model.fetchBranches(app: app)
        } catch {
            app.report(error)
        }
    }

    private func switchTo(_ branch: GitBranch) async {
        await model.run(app: app, success: "Switched to \(branch.name)") {
            try await app.git.switchBranch(repository: repository, name: branch.name)
        }
        await model.fetchBranches(app: app)
    }

    private func delete(_ branch: GitBranch) async {
        do {
            try await app.git.deleteBranch(repository: repository, name: branch.name)
            await model.fetchBranches(app: app)
        } catch {
            app.report(error)
        }
    }
}
