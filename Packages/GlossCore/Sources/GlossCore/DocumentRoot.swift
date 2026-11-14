import Foundation

/// The directory tree a document's page is allowed to read from.
public struct DocumentRoot: Sendable, Equatable {
    public let url: URL

    /// The enclosing git repository if there is one, otherwise the document's
    /// own directory.
    public static func find(for document: URL, fileManager: FileManager = .default) -> DocumentRoot {
        let start = document.resolvingSymlinksInPath().deletingLastPathComponent()
        var candidate = start
        while candidate.path != "/" {
            if fileManager.fileExists(atPath: candidate.appendingPathComponent(".git").path) {
                return DocumentRoot(url: candidate)
            }
            candidate = candidate.deletingLastPathComponent()
        }
        return DocumentRoot(url: start)
    }

    public init(url: URL) {
        self.url = url.resolvingSymlinksInPath()
    }

    /// Maps a path from a page request to a file inside the root. Returns nil
    /// when the path, after `..` and symlinks are resolved, lands outside it.
    public func resolve(_ relativePath: String) -> URL? {
        let trimmed = relativePath.drop(while: { $0 == "/" })
        let target = url.appendingPathComponent(String(trimmed)).standardizedFileURL.resolvingSymlinksInPath()
        return contains(target) ? target : nil
    }

    /// The path a file inside the root is served at, or nil if it is outside.
    public func relativePath(of file: URL) -> String? {
        let target = file.resolvingSymlinksInPath()
        guard contains(target), target.path != url.path else { return nil }
        return String(target.path.dropFirst(prefix.count))
    }

    private var prefix: String { url.path.hasSuffix("/") ? url.path : url.path + "/" }

    private func contains(_ target: URL) -> Bool {
        target.path == url.path || target.path.hasPrefix(prefix)
    }
}
