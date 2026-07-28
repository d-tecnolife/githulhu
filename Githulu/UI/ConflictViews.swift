import SwiftUI

struct ConflictListView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    let repository: URL
    @ObservedObject var model: RepositoryViewModel

    @State private var conflicts: [GitConflict] = []
    @State private var mergeMessage = "Merge remote changes"

    var body: some View {
        NavigationStack {
            List {
                Section("Conflicts") {
                    ForEach(conflicts) { conflict in
                        if conflict.isBinary || conflict.isTooLarge {
                            Label {
                                VStack(alignment: .leading) {
                                    Text(conflict.path)
                                    Text(conflict.isBinary ? "Binary conflict" : "Too large to edit")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            }
                        } else {
                            NavigationLink {
                                ConflictEditorView(repository: repository, conflict: conflict) {
                                    await reload()
                                }
                            } label: {
                                Label(conflict.path, systemImage: "doc.text")
                            }
                        }
                    }
                }
                if conflicts.isEmpty {
                    Section("Complete merge") {
                        TextField("Merge message", text: $mergeMessage)
                        Button("Complete merge") {
                            Task { await completeMerge() }
                        }
                    }
                }
            }
            .navigationTitle("Resolve conflicts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await reload() }
        }
    }

    private func reload() async {
        do {
            conflicts = try await app.git.conflicts(repository: repository)
            model.conflicts = conflicts
        } catch {
            app.report(error)
        }
    }

    private func completeMerge() async {
        await model.run(app: app, success: "Merge completed") {
            try await app.git.completeMerge(
                repository: repository,
                message: mergeMessage,
                authorName: app.account?.name ?? app.account?.login ?? "Githulu User",
                authorEmail: "noreply@users.noreply.github.com"
            )
        }
        if app.errorMessage == nil { dismiss() }
    }
}

private struct ConflictEditorView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    let repository: URL
    let conflict: GitConflict
    let resolved: () async -> Void

    @State private var source = 1
    @State private var content = ""

    private var sourceText: String {
        switch source {
        case 0: return conflict.ancestor ?? ""
        case 2: return conflict.theirs ?? ""
        default: return conflict.ours ?? ""
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Version", selection: $source) {
                Text("Base").tag(0)
                Text("Ours").tag(1)
                Text("Theirs").tag(2)
            }
            .pickerStyle(.segmented)
            .padding()
            TextEditor(text: $content)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(.horizontal, 8)
        }
        .navigationTitle(conflict.path)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Resolve") {
                    Task {
                        do {
                            try await app.git.resolve(
                                repository: repository,
                                path: conflict.path,
                                content: content
                            )
                            await resolved()
                            dismiss()
                        } catch {
                            app.report(error)
                        }
                    }
                }
            }
        }
        .onAppear { content = conflict.ours ?? "" }
        .onChange(of: source) { content = sourceText }
    }
}
