import SwiftUI

struct GitHubRepositoryPicker: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    let select: (GitHubRepository) -> Void

    private var filtered: [GitHubRepository] {
        guard !query.isEmpty else { return app.availableRepositories }
        return app.availableRepositories.filter {
            $0.fullName.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { repository in
                Button {
                    select(repository)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(repository.fullName)
                                .font(.headline)
                            if repository.isPrivate {
                                Image(systemName: "lock.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let description = repository.description {
                            Text(description)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
            .overlay {
                if filtered.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, prompt: "Find a repository")
            .navigationTitle("Clone repository")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
