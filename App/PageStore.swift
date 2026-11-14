import Foundation
import GlossCore
import Synchronization
import UniformTypeIdentifiers
import WebKit

/// Everything one window's page is allowed to load, served over the `gloss:`
/// scheme. This is the only route by which the web view reaches the disk.
///
/// - `gloss://doc/<path>` is the document root. The rendered page is served at
///   the document's own path, so relative links and images resolve unaided.
/// - `gloss://app/<file>` is Gloss's own page scaffolding.
/// - `gloss://bundle/<id>/<path>` is a file inside a bundle the page uses.
final class PageStore: Sendable {
    static let scheme = "gloss"
    private static let documentHost = "doc"
    private static let appHost = "app"
    private static let bundleHost = "bundle"
    /// The only app files a page may ask for.
    private static let appFiles: Set<String> = ["base.css", "print.css", "gloss.js"]

    /// What the page's policy lets through, beyond the default of nothing.
    struct Policy: Equatable, Sendable {
        var allowsRemoteImages = false
        var allowsInlineStyles = false
    }

    private struct Page {
        var html: Data
        var path: String
        var root: DocumentRoot?
        var nonce: String
        var policy: Policy
        var bundles: [String: DocumentRoot]
    }

    private let page = Mutex<Page?>(nil)
    private let appDirectory: URL?

    init(appDirectory: URL? = Bundle.main.resourceURL) {
        self.appDirectory = appDirectory
    }

    static func appURL(_ file: String) -> String { "\(scheme)://\(appHost)/\(file)" }

    static func bundleURL(_ id: String, _ path: String) -> String {
        var components = URLComponents()
        components.scheme = scheme
        components.host = bundleHost
        components.path = "/\(id)/\(path)"
        return components.string ?? "\(scheme)://\(bundleHost)/\(id)/\(path)"
    }

    /// The URL a document's page is served at.
    static func pageURL(for document: URL?) -> URL {
        let root = document.map { DocumentRoot.find(for: $0) }
        let relative = document.flatMap { root?.relativePath(of: $0) } ?? "untitled.md"
        var components = URLComponents()
        components.scheme = scheme
        components.host = documentHost
        components.path = "/" + relative
        return components.url!
    }

    /// Replaces the page and returns the URL to load it from.
    @discardableResult
    func show(
        html: String, document: URL?, nonce: String = UUID().uuidString, policy: Policy = Policy(),
        bundles: [String: URL] = [:]
    ) -> URL {
        let url = Self.pageURL(for: document)
        page.withLock {
            $0 = Page(
                html: Data(html.utf8), path: url.path(percentEncoded: false),
                root: document.map { DocumentRoot.find(for: $0) }, nonce: nonce, policy: policy,
                bundles: bundles.mapValues { DocumentRoot(url: $0) })
        }
        return url
    }

    /// Updates what a reload would serve, after the live page was edited in
    /// place.
    func update(html: String) {
        page.withLock { $0?.html = Data(html.utf8) }
    }

    /// The file a `gloss://doc/` URL stands for, if it is inside the root.
    func fileURL(for url: URL) -> URL? {
        guard url.scheme == Self.scheme, url.host() == Self.documentHost else { return nil }
        return page.withLock { $0?.root?.resolve(url.path(percentEncoded: false)) }
    }

    /// True when `url` is the current page, ignoring any fragment.
    func isCurrentPage(_ url: URL) -> Bool {
        guard url.scheme == Self.scheme, url.host() == Self.documentHost else { return false }
        return page.withLock { $0?.path == url.path(percentEncoded: false) }
    }

    func respond(to request: URLRequest) -> (URLResponse, Data) {
        guard let url = request.url, url.scheme == Self.scheme else {
            return Self.failure(request.url, status: 400)
        }
        let path = url.path(percentEncoded: false)
        let current = page.withLock { $0 }
        switch url.host() {
        case Self.documentHost:
            guard let current else { return Self.failure(url, status: 404) }
            if path == current.path {
                let policy = HTMLPage.contentSecurityPolicy(
                    scheme: Self.scheme, nonce: current.nonce,
                    allowsRemoteImages: current.policy.allowsRemoteImages,
                    allowsInlineStyles: current.policy.allowsInlineStyles)
                return Self.success(url, current.html, type: "text/html; charset=utf-8", policy: policy)
            }
            guard let file = current.root?.resolve(path) else { return Self.failure(url, status: 403) }
            return Self.file(file, for: url)
        case Self.appHost:
            let name = String(path.dropFirst())
            guard let appDirectory, Self.appFiles.contains(name) else { return Self.failure(url, status: 403) }
            return Self.file(appDirectory.appendingPathComponent(name), for: url)
        case Self.bundleHost:
            // /<bundle id>/<path inside the bundle>
            let parts = path.dropFirst().split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let root = current?.bundles[String(parts[0])],
                let file = root.resolve(String(parts[1]))
            else { return Self.failure(url, status: 403) }
            return Self.file(file, for: url)
        default:
            return Self.failure(url, status: 404)
        }
    }

    private static func file(_ file: URL, for url: URL) -> (URLResponse, Data) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue,
            let data = try? Data(contentsOf: file)
        else { return failure(url, status: 404) }
        let type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        return success(url, data, type: type, policy: nil)
    }

    private static func success(_ url: URL, _ data: Data, type: String, policy: String?) -> (URLResponse, Data) {
        var headers = [
            "Content-Type": type,
            "Content-Length": String(data.count),
            "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff",
        ]
        if let policy { headers["Content-Security-Policy"] = policy }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        return (response, data)
    }

    private static func failure(_ url: URL?, status: Int) -> (URLResponse, Data) {
        let url = url ?? URL(string: "\(scheme)://\(documentHost)/")!
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "0"])!
        return (response, Data())
    }
}

struct GlossSchemeHandler: URLSchemeHandler {
    let store: PageStore

    func reply(for request: URLRequest) -> AsyncThrowingStream<URLSchemeTaskResult, any Error> {
        AsyncThrowingStream { continuation in
            let (response, data) = store.respond(to: request)
            continuation.yield(.response(response))
            continuation.yield(.data(data))
            continuation.finish()
        }
    }
}

/// The same store for the older web view API, which printing still needs.
final class LegacySchemeHandler: NSObject, WKURLSchemeHandler {
    let store: PageStore

    init(store: PageStore) { self.store = store }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let (response, data) = store.respond(to: urlSchemeTask.request)
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}
