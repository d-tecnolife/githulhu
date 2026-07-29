import Foundation
import SwiftUI
import UIKit

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
    case fileTooLargeToSave

    var errorDescription: String? {
        switch self {
        case .outsideRepository:
            return "This item points outside the repository and cannot be opened."
        case .notAFile:
            return "This item is not a readable file."
        case .unreadableText:
            return "This file is not encoded as supported text."
        case .fileTooLargeToSave:
            return "The edited file is too large to save in Githulhu."
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

    static func write(text: String, to file: URL, repositoryRoot: URL) throws {
        guard contains(file, repositoryRoot: repositoryRoot) else {
            throw RepositoryBrowserError.outsideRepository
        }

        let values = try file.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else {
            throw RepositoryBrowserError.notAFile
        }

        let data = Data(text.utf8)
        guard Int64(data.count) <= maximumReadableBytes else {
            throw RepositoryBrowserError.fileTooLargeToSave
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        try data.write(to: file, options: .atomic)
        if let permissions = attributes?[.posixPermissions] {
            try? FileManager.default.setAttributes(
                [.posixPermissions: permissions],
                ofItemAtPath: file.path
            )
        }
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

enum SyntaxHighlighter {
    static func highlight(_ source: String, fileExtension: String) -> AttributedString {
        let font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let highlighted = NSMutableAttributedString(
            string: source,
            attributes: [
                .font: font,
                .foregroundColor: UIColor.label
            ]
        )
        let fullRange = NSRange(location: 0, length: highlighted.length)

        apply(
            pattern: #"\b\d+(?:\.\d+)?\b"#,
            color: .systemOrange,
            to: highlighted,
            range: fullRange
        )

        let keywords = keywords(for: fileExtension)
        if !keywords.isEmpty {
            let escaped = keywords.map(NSRegularExpression.escapedPattern(for:))
            apply(
                pattern: #"\b(?:"# + escaped.joined(separator: "|") + #")\b"#,
                color: .systemPink,
                to: highlighted,
                range: fullRange
            )
        }

        if ["json", "jsonc"].contains(fileExtension.lowercased()) {
            apply(
                pattern: #""(?:\\.|[^"\\])*"(?=\s*:)"#,
                color: .systemBlue,
                to: highlighted,
                range: fullRange
            )
        }

        apply(
            pattern: #""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`"#,
            color: .systemGreen,
            to: highlighted,
            range: fullRange
        )
        apply(
            pattern: commentPattern(for: fileExtension),
            color: .secondaryLabel,
            to: highlighted,
            range: fullRange,
            options: [.anchorsMatchLines]
        )

        return addLineNumbers(to: highlighted, font: font)
    }

    private static func apply(
        pattern: String,
        color: UIColor,
        to text: NSMutableAttributedString,
        range: NSRange,
        options: NSRegularExpression.Options = []
    ) {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else {
            return
        }
        expression.enumerateMatches(in: text.string, range: range) { match, _, _ in
            guard let match else { return }
            text.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }

    private static func addLineNumbers(
        to highlighted: NSAttributedString,
        font: UIFont
    ) -> AttributedString {
        let output = NSMutableAttributedString(string: "")
        let source = highlighted.string as NSString
        var location = 0
        var lineNumber = 1

        repeat {
            let lineRange = source.lineRange(
                for: NSRange(location: min(location, source.length), length: 0)
            )
            output.append(
                NSAttributedString(
                    string: String(format: "%4d  ", lineNumber),
                    attributes: [
                        .font: font,
                        .foregroundColor: UIColor.tertiaryLabel
                    ]
                )
            )
            if lineRange.length > 0 {
                output.append(highlighted.attributedSubstring(from: lineRange))
            }
            location = NSMaxRange(lineRange)
            lineNumber += 1
        } while location < source.length

        return AttributedString(output)
    }

    private static func keywords(for fileExtension: String) -> [String] {
        switch fileExtension.lowercased() {
        case "swift":
            return [
                "actor", "associatedtype", "async", "await", "break", "case", "catch",
                "class", "continue", "default", "defer", "do", "else", "enum", "extension",
                "false", "for", "func", "guard", "if", "import", "in", "init", "inout",
                "internal", "is", "let", "nil", "nonisolated", "open", "private", "protocol",
                "public", "repeat", "return", "self", "some", "static", "struct", "super",
                "switch", "throw", "throws", "true", "try", "typealias", "var", "where",
                "while"
            ]
        case "js", "jsx", "mjs", "cjs", "ts", "tsx":
            return [
                "async", "await", "break", "case", "catch", "class", "const", "continue",
                "default", "delete", "do", "else", "export", "extends", "false", "finally",
                "for", "from", "function", "if", "import", "in", "instanceof", "interface",
                "let", "new", "null", "of", "return", "static", "super", "switch", "this",
                "throw", "true", "try", "type", "typeof", "undefined", "var", "while"
            ]
        case "py":
            return [
                "and", "as", "assert", "async", "await", "break", "class", "continue",
                "def", "del", "elif", "else", "except", "False", "finally", "for", "from",
                "global", "if", "import", "in", "is", "lambda", "None", "nonlocal", "not",
                "or", "pass", "raise", "return", "True", "try", "while", "with", "yield"
            ]
        case "c", "h", "cc", "cpp", "cxx", "hpp", "m", "mm", "java", "kt", "kts":
            return [
                "abstract", "auto", "boolean", "break", "case", "catch", "char", "class",
                "const", "continue", "default", "do", "double", "else", "enum", "extends",
                "false", "final", "finally", "float", "for", "if", "implements", "import",
                "instanceof", "int", "interface", "long", "namespace", "new", "null",
                "private", "protected", "public", "return", "short", "static", "struct",
                "super", "switch", "this", "throw", "true", "try", "void", "while"
            ]
        case "sh", "bash", "zsh":
            return [
                "case", "do", "done", "elif", "else", "esac", "fi", "for", "function",
                "if", "in", "select", "then", "until", "while"
            ]
        default:
            return []
        }
    }

    private static func commentPattern(for fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "py", "sh", "bash", "zsh", "yml", "yaml", "toml":
            return #"#.*$"#
        case "html", "htm", "xml", "md":
            return #"<!--[\s\S]*?-->"#
        default:
            return #"//.*$|/\*[\s\S]*?\*/"#
        }
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
    @State private var originalText = ""
    @State private var draft = ""
    @State private var isEditing = false
    @State private var editorError: String?
    @State private var showingDiscardConfirmation = false
    @State private var didSave = false

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
                    if isEditing {
                        TextEditor(text: $draft)
                            .font(.system(.body, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding()
                            .scrollContentBackground(.hidden)
                            .background(Color(uiColor: .systemBackground))
                            .accessibilityLabel("File editor")
                    } else {
                        ScrollView(.vertical) {
                            Text(
                                SyntaxHighlighter.highlight(
                                    text,
                                    fileExtension: file.pathExtension
                                )
                            )
                            .textSelection(.enabled)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                        .background(Color(uiColor: .systemBackground))
                    }
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
                Button("Done", action: attemptToClose)
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if didSave {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                if isEditing {
                    HStack {
                        Button("Cancel", role: .cancel, action: cancelEditing)
                        Spacer()
                        Text("Editing")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Save", action: save)
                            .buttonStyle(.borderedProminent)
                            .disabled(draft == originalText)
                    }
                } else {
                    HStack {
                        Text(relativePath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let displayedByteCount {
                            Text(
                                ByteCountFormatter.string(
                                    fromByteCount: displayedByteCount,
                                    countStyle: .file
                                )
                            )
                        }
                        Spacer()
                        if editableText != nil {
                            Button("Edit", action: beginEditing)
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .confirmationDialog(
            "Discard unsaved changes?",
            isPresented: $showingDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("Discard and close", role: .destructive) {
                close()
            }
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("Your edits to \(file.lastPathComponent) have not been saved.")
        }
        .alert(
            "Couldn’t save file",
            isPresented: Binding(
                get: { editorError != nil },
                set: { if !$0 { editorError = nil } }
            )
        ) {
            Button("OK") { editorError = nil }
        } message: {
            Text(editorError ?? "")
        }
        .task(id: file) {
            do {
                content = try RepositoryFileAccess.read(
                    file: file,
                    repositoryRoot: repository
                )
                if case .text(let text)? = content {
                    originalText = text
                    draft = text
                }
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

    private var editableText: String? {
        guard case .text(let text)? = content else { return nil }
        return text
    }

    private var displayedByteCount: Int64? {
        if let editableText {
            return Int64(editableText.utf8.count)
        }
        return byteCount
    }

    private func beginEditing() {
        guard let editableText else { return }
        originalText = editableText
        draft = editableText
        didSave = false
        isEditing = true
    }

    private func cancelEditing() {
        draft = originalText
        isEditing = false
    }

    private func save() {
        do {
            try RepositoryFileAccess.write(
                text: draft,
                to: file,
                repositoryRoot: repository
            )
            originalText = draft
            content = .text(draft)
            isEditing = false
            didSave = true
        } catch {
            editorError = error.localizedDescription
        }
    }

    private func attemptToClose() {
        if isEditing && draft != originalText {
            showingDiscardConfirmation = true
        } else {
            close()
        }
    }
}
