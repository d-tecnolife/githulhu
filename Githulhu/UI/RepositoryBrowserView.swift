import Foundation
import SwiftUI

struct RepositoryEntry: Identifiable, Equatable {
    var id: String { url.path }

    let url: URL
    let name: String
    let isDirectory: Bool
    let byteCount: Int64?
}

enum RepositoryFileContent: Equatable {
    case text(String)
    case binary
    case tooLarge(Int64)
}

enum RepositoryBrowserError: LocalizedError, Equatable {
    case outsideRepository
    case notAFile
    case unreadableText

    var errorDescription: String? {
        switch self {
        case .outsideRepository:
            return "This item points outside the repository and cannot be opened."
        case .notAFile:
            return "This item is not a readable file."
        case .unreadableText:
            return "This file is not encoded as supported text."
        }
    }
}

enum RepositoryFileAccess {
    static let maximumReadableBytes: Int64 = 1_000_000

    static func entries(in directory: URL, repositoryRoot: URL) throws -> [RepositoryEntry] {
        guard contains(directory, repositoryRoot: repositoryRoot) else {
            throw RepositoryBrowserError.outsideRepository
        }

        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .fileSizeKey
        ]
        return try FileManager.default
            .contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: keys,
                options: []
            )
            .filter { $0.lastPathComponent != ".git" }
            .filter { contains($0, repositoryRoot: repositoryRoot) }
            .compactMap { url in
                let values = try url.resourceValues(forKeys: Set(keys))
                guard values.isDirectory == true || values.isRegularFile == true else {
                    return nil
                }
                return RepositoryEntry(
                    url: url,
                    name: url.lastPathComponent,
                    isDirectory: values.isDirectory == true,
                    byteCount: values.fileSize.map { Int64($0) }
                )
            }
            .sorted { first, second in
                if first.isDirectory != second.isDirectory {
                    return first.isDirectory
                }
                return first.name.localizedStandardCompare(second.name) == .orderedAscending
            }
    }

    static func read(file: URL, repositoryRoot: URL) throws -> RepositoryFileContent {
        guard contains(file, repositoryRoot: repositoryRoot) else {
            throw RepositoryBrowserError.outsideRepository
        }

        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw RepositoryBrowserError.notAFile
        }
        if let size = values.fileSize.map({ Int64($0) }), size > maximumReadableBytes {
            return .tooLarge(size)
        }

        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        if Int64(data.count) > maximumReadableBytes {
            return .tooLarge(Int64(data.count))
        }
        if data.prefix(8_192).contains(0) {
            return .binary
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw RepositoryBrowserError.unreadableText
        }
        return .text(text)
    }

    static func contains(_ candidate: URL, repositoryRoot: URL) -> Bool {
        let rootPath = repositoryRoot
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        let candidatePath = candidate
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path

        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }
}

struct RepositoryBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    let repository: URL

    var body: some View {
        NavigationStack {
            RepositoryDirectoryView(
                repository: repository,
                directory: repository,
                title: repository.lastPathComponent,
                close: { dismiss() }
            )
        }
    }
}

private struct RepositoryDirectoryView: View {
    let repository: URL
    let directory: URL
    let title: String
    let close: () -> Void

    @State private var entries: [RepositoryEntry]?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let errorMessage {
                ContentUnavailableView(
                    "Unable to open folder",
                    systemImage: "folder.badge.questionmark",
                    description: Text(errorMessage)
                )
            } else if let entries {
                if entries.isEmpty {
                    ContentUnavailableView(
                        "Empty folder",
                        systemImage: "folder",
                        description: Text("There are no files in this folder.")
                    )
                } else {
                    List(entries) { entry in
                        NavigationLink {
                            if entry.isDirectory {
                                RepositoryDirectoryView(
                                    repository: repository,
                                    directory: entry.url,
                                    title: entry.name,
                                    close: close
                                )
                            } else {
                                RepositoryFileView(
                                    repository: repository,
                                    file: entry.url,
                                    byteCount: entry.byteCount,
                                    close: close
                                )
                            }
                        } label: {
                            RepositoryEntryRow(entry: entry)
                        }
                    }
                    .listStyle(.plain)
                }
            } else {
                ProgressView("Loading files…")
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: close)
            }
        }
        .task(id: directory) {
            do {
                entries = try RepositoryFileAccess.entries(
                    in: directory,
                    repositoryRoot: repository
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct RepositoryEntryRow: View {
    let entry: RepositoryEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .lineLimit(2)
                if !entry.isDirectory, let byteCount = entry.byteCount {
                    Text(ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var iconName: String {
        if entry.isDirectory {
            return "folder.fill"
        }
        switch entry.url.pathExtension.lowercased() {
        case "swift":
            return "swift"
        case "json", "yml", "yaml", "toml", "xml":
            return "curlybraces"
        case "md", "txt", "rst":
            return "doc.text"
        default:
            return "doc"
        }
    }
}

private struct RepositoryFileView: View {
    let repository: URL
    let file: URL
    let byteCount: Int64?
    let close: () -> Void

    @State private var content: RepositoryFileContent?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let errorMessage {
                ContentUnavailableView(
                    "Unable to read file",
                    systemImage: "doc.badge.ellipsis",
                    description: Text(errorMessage)
                )
            } else if let content {
                switch content {
                case .text(let text):
                    ScrollView(.vertical) {
                        Text(numbered(text))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .background(Color(uiColor: .systemBackground))
                case .binary:
                    ContentUnavailableView(
                        "Binary file",
                        systemImage: "doc.badge.ellipsis",
                        description: Text("This file cannot be displayed as text.")
                    )
                case .tooLarge(let size):
                    ContentUnavailableView(
                        "File too large",
                        systemImage: "doc.text",
                        description: Text(
                            "\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) files are not loaded into the reader."
                        )
                    )
                }
            } else {
                ProgressView("Opening file…")
            }
        }
        .navigationTitle(file.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: close)
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text(relativePath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if let byteCount {
                    Text(ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .task(id: file) {
            do {
                content = try RepositoryFileAccess.read(
                    file: file,
                    repositoryRoot: repository
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var relativePath: String {
        let root = repository.standardizedFileURL.path
        let path = file.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { return file.lastPathComponent }
        return String(path.dropFirst(root.count + 1))
    }

    private func numbered(_ text: String) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { index, line in
                "\(String(format: "%4d", index + 1))  \(line)"
            }
            .joined(separator: "\n")
    }
}
