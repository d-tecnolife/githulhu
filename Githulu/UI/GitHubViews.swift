import SwiftUI
import UIKit

struct DeviceAuthorizationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let authorization: DeviceAuthorization

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "person.badge.key.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(.tint)
                Text("Connect GitHub")
                    .font(.title.bold())
                Text("Enter this one-time code on GitHub:")
                    .foregroundStyle(.secondary)
                Text(authorization.userCode)
                    .font(.system(.title, design: .monospaced, weight: .bold))
                    .textSelection(.enabled)
                    .padding()
                    .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                Button("Copy code and open GitHub") {
                    UIPasteboard.general.string = authorization.userCode
                    openURL(authorization.verificationURI)
                }
                .buttonStyle(.borderedProminent)
                Text("Githulu will finish signing in automatically after authorization.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(28)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

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
