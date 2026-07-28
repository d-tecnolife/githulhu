import Foundation

protocol BookmarkStoring {
    func makeBookmark(for url: URL) throws -> Data
    func resolve(_ bookmark: Data) throws -> ScopedURL
}

enum BookmarkError: LocalizedError {
    case stale
    case accessDenied

    var errorDescription: String? {
        switch self {
        case .stale:
            return "This Files permission is stale. Select the folder again."
        case .accessDenied:
            return "Githulu no longer has permission to access this folder."
        }
    }
}

final class ScopedURL {
    let url: URL
    private let accessing: Bool

    init(url: URL) throws {
        self.url = url
        accessing = url.startAccessingSecurityScopedResource()
        guard accessing else { throw BookmarkError.accessDenied }
    }

    deinit {
        if accessing {
            url.stopAccessingSecurityScopedResource()
        }
    }
}

final class BookmarkStore: BookmarkStoring {
    func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    func resolve(_ bookmark: Data) throws -> ScopedURL {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        guard !stale else { throw BookmarkError.stale }
        return try ScopedURL(url: url)
    }
}
