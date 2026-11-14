import AppKit
import GlossCore
import OSLog
import WebKit

private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "gloss", category: "page")

/// Owns one window's web page: renders the document, serves it, and keeps the
/// page from ever navigating away from it.
@MainActor
@Observable
final class PageModel {
    let page: WebPage
    private(set) var isLoading = true
    private(set) var snapshot = PageSnapshot()
    private(set) var headings: [Heading] = []
    private(set) var hasRemoteImages = false
    /// How many form fields the page has: the document's own controls and
    /// the blanks Gloss turns into fields.
    private(set) var formFieldCount = 0
    private(set) var themeID = ""
    private(set) var appearance = "dark"
    private(set) var fileURL: URL?
    /// The file was moved or deleted. The last version stays on screen.
    private(set) var fileMissing = false
    /// The reader asked for this document's remote images. Not remembered.
    var allowsRemoteImages = false
    var isFinding = false
    var findFailed = false

    let store: PageStore
    private let preferences: Preferences
    private let library: BundleLibrary
    /// One nonce for the life of the page. A document cannot read it: nothing
    /// a document contains is ever run.
    private let nonce = UUID().uuidString
    private var text = ""
    /// The text the document handed over last. The file watcher may have
    /// moved `text` on since; a stale hand-over must not undo that.
    private var documentText: String?
    private var watcher: DirectoryWatcher?
    private var watchedURL: URL?
    private var generation = 0
    /// What the live page was loaded with. A re-render that needs the same
    /// chrome is swapped in place, which keeps the reader's position exactly.
    private var loaded: Chrome?
    /// The answers as they were last copied, saved or shared.
    private var exportedFields: [FormField]?

    private struct Chrome: Equatable {
        var url: URL
        var appearance: String
        var themeID: String
        var fitsWindow: Bool
        var stylesheets: [String]
        var printStylesheets: [String]
        var scripts: [String]
        var policy: PageStore.Policy
        var bundles: [String: URL]
    }

    init(
        store: PageStore = PageStore(), preferences: Preferences = .shared, library: BundleLibrary = .shared
    ) {
        self.store = store
        self.preferences = preferences
        self.library = library
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = .nonPersistent()
        if let scheme = URLScheme(PageStore.scheme) {
            configuration.urlSchemeHandlers[scheme] = GlossSchemeHandler(store: store)
        }
        page = WebPage(configuration: configuration, navigationDecider: LinkRouter(store: store))
    }

    /// Shows a document. Called again when the file changes on disk or the
    /// window's appearance changes.
    func show(text: String, fileURL: URL?, appearance: String) async {
        if text != documentText {
            documentText = text
            self.text = text
        }
        self.fileURL = fileURL
        self.appearance = appearance
        if let fileURL { PageRegistry.register(self, for: fileURL) }
        watch(fileURL)
        await render()
    }

    /// Watches the file's directory, not the file: editors and git replace a
    /// file with a new one, which a watch on the old file would never see.
    private func watch(_ url: URL?) {
        guard url != watchedURL else { return }
        watchedURL = url
        fileMissing = false
        watcher = url.flatMap { url in
            DirectoryWatcher(directory: url.deletingLastPathComponent()) { [weak self] in
                Task { @MainActor in await self?.fileMayHaveChanged() }
            }
        }
    }

    private func fileMayHaveChanged() async {
        guard let fileURL else { return }
        let data = await Task.detached { try? Data(contentsOf: fileURL) }.value
        guard let data else {
            fileMissing = true
            return
        }
        fileMissing = false
        // Invalid UTF-8 is shown with replacement characters, never dropped.
        let current = String(decoding: data, as: UTF8.self)
        guard current != text else { return }
        text = current
        await render()
    }

    /// Rebuilds the page after a theme, add-on or setting change.
    func refresh() async {
        await render()
    }

    private func render() async {
        generation += 1
        let current = generation
        isLoading = true

        let source = text
        let highlighter = Highlighter.shared.codeHighlighter
        let rendered = await Task.detached { MarkdownRenderer.render(source, highlighter: highlighter) }.value
        guard current == generation else { return }

        // A moved file has a new address, so its chrome differs and the page
        // reloads there; relative links then resolve from the new place.
        let chrome = chrome(for: rendered)
        let spec = PageSpec(
            title: fileURL?.lastPathComponent ?? "Untitled", appearance: chrome.appearance,
            themeID: chrome.themeID, fitsWindow: chrome.fitsWindow, stylesheets: chrome.stylesheets, printStylesheets: chrome.printStylesheets,
            scripts: chrome.scripts, nonce: nonce)
        let html = HTMLPage.wrap(rendered, spec: spec)

        if chrome == loaded {
            store.update(html: html)
            await run(
                "gloss.replace(header, article)",
                ["header": HTMLPage.frontMatterHTML(rendered), "article": HTMLPage.articleHTML(rendered)])
        } else {
            let anchor = loaded == nil ? nil : await read("return window.gloss ? JSON.stringify(gloss.anchor()) : ''")
            // A reload must not lose what the reader typed.
            let answers = loaded == nil ? nil : await read("return window.gloss ? JSON.stringify(gloss.forms.state()) : ''")
            store.show(html: html, document: fileURL, nonce: nonce, policy: chrome.policy, bundles: chrome.bundles)
            do {
                for try await _ in page.load(URLRequest(url: chrome.url)) {}
            } catch {
                log.error("page load failed: \(error.localizedDescription, privacy: .public)")
            }
            guard current == generation else { return }
            loaded = chrome
            if let answers, !answers.isEmpty {
                await run("gloss.forms.apply(JSON.parse(answers))", ["answers": answers])
            }
            if let anchor, !anchor.isEmpty, anchor != "null" {
                await run("gloss.restore(JSON.parse(anchor))", ["anchor": anchor])
            }
        }
        guard current == generation else { return }
        await applyZoom()

        themeID = chrome.themeID
        headings = rendered.headings
        hasRemoteImages = rendered.hasRemoteImages
        formFieldCount = (try? await page.callJavaScript("return window.gloss ? gloss.forms.count() : 0")) as? Int ?? 0
        snapshot = PageSnapshot(
            text: await read("return document.body ? document.body.innerText : ''"),
            html: await read("return document.documentElement.outerHTML"),
            outline: rendered.headings.map(\.text)
        )
        guard current == generation else { return }
        isLoading = false
        DefaultViewer.promptIfNeeded()
    }

    /// Chooses the theme and add-ons for this page and works out what it loads.
    private func chrome(for rendered: RenderedDocument) -> Chrome {
        let wanted = library.bundle(preferences.themeID(for: appearance))
        let fallbackID = appearance == "dark" ? Preferences.defaultDarkTheme : Preferences.defaultLightTheme
        let theme =
            [wanted, library.bundle(fallbackID)].compactMap { $0 }
            .first { $0.manifest.kind == .theme && $0.supports(appearance) }
        let addOns = library.addOns.filter {
            !preferences.disabledAddOns.contains($0.id)
                && $0.manifest.applies(languages: rendered.codeLanguages, source: text)
        }
        let used = [theme].compactMap { $0 } + addOns

        func urls(_ keyPath: KeyPath<BundleManifest, [String]?>, in bundles: [InstalledBundle]) -> [String] {
            bundles.flatMap { bundle in
                (bundle.manifest[keyPath: keyPath] ?? []).map { PageStore.bundleURL(bundle.id, $0) }
            }
        }

        let themePrint = urls(\.printStyles, in: [theme].compactMap { $0 })
        return Chrome(
            url: PageStore.pageURL(for: fileURL),
            appearance: appearance,
            themeID: theme?.id ?? "",
            fitsWindow: preferences.textWidth == .window,
            stylesheets: [PageStore.appURL("base.css")] + urls(\.styles, in: used),
            printStylesheets: themePrint.isEmpty ? [PageStore.appURL("print.css")] : themePrint,
            scripts: [PageStore.appURL("gloss.js")] + urls(\.scripts, in: used),
            policy: PageStore.Policy(
                allowsRemoteImages: allowsRemoteImages,
                allowsInlineStyles: used.contains { $0.manifest.inlineStyles == true }),
            bundles: Dictionary(uniqueKeysWithValues: used.map { ($0.id, $0.directory) })
        )
    }

    func loadRemoteImages() async {
        allowsRemoteImages = true
        await render()
    }

    func applyZoom() async {
        await run("window.gloss && gloss.zoom(factor)", ["factor": preferences.zoom])
    }

    func reveal(_ heading: Heading) async {
        await run("gloss.reveal(id)", ["id": heading.id])
    }

    /// Selects the next (or previous) match and scrolls to it.
    func find(_ query: String, backwards: Bool = false) async {
        guard !query.isEmpty else {
            findFailed = false
            return
        }
        let found = try? await page.callJavaScript(
            "return window.find(query, false, backwards, true)",
            arguments: ["query": query, "backwards": backwards])
        findFailed = (found as? Bool) != true
    }

    // MARK: Form answers

    /// The page's fields and what has been entered in them.
    func formFields() async throws -> [FormField] {
        let json = try await page.callJavaScript("return JSON.stringify(gloss.forms.values())") as? String ?? "[]"
        return try JSONDecoder().decode([FormField].self, from: Data(json.utf8))
    }

    /// The answers as an export, without counting it as one.
    func formJSON() async throws -> (json: Data, fields: [FormField]) {
        let fields = try await formFields()
        let export = FormExport(document: fileURL?.lastPathComponent ?? "Untitled", exported: .now, fields: fields)
        return (try export.json(), fields)
    }

    /// The answers as an export, counted as exported.
    func exportForm() async throws -> Data {
        let export = try await formJSON()
        markExported(export.fields)
        return export.json
    }

    func markExported(_ fields: [FormField]) {
        exportedFields = fields
    }

    /// Whether the reader has entered anything that has not been exported
    /// as it now stands.
    func hasUnexportedAnswers() async -> Bool {
        guard formFieldCount > 0,
            (try? await page.callJavaScript("return window.gloss ? gloss.forms.changed() : false")) as? Bool == true
        else { return false }
        guard let fields = try? await formFields() else { return true }
        return fields != exportedFields
    }

    /// What the reader has typed, to put into another copy of this page.
    func formState() async -> String {
        await read("return window.gloss ? JSON.stringify(gloss.forms.state()) : ''")
    }

    /// Opens a Finder window on the document's folder, with the file selected.
    func showInFinder() {
        guard let fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    func pdf() async throws -> Data {
        try await page.exported(as: .pdf())
    }

    private func run(_ script: String, _ arguments: [String: Any] = [:]) async {
        do {
            _ = try await page.callJavaScript(script, arguments: arguments)
        } catch {
            log.error("page script failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func read(_ script: String) async -> String {
        (try? await page.callJavaScript(script)) as? String ?? ""
    }

    /// Used by tests to load a page directly, bypassing the renderer.
    func load(html: String, fileURL: URL?, bundles: [String: URL] = [:]) async {
        isLoading = true
        let url = store.show(html: html, document: fileURL, nonce: nonce, bundles: bundles)
        do {
            for try await _ in page.load(URLRequest(url: url)) {}
        } catch {
            log.error("page load failed: \(error.localizedDescription, privacy: .public)")
        }
        isLoading = false
    }
}

/// Decides what a navigation is allowed to do. The page only ever shows its
/// own document; a clicked link is handed to the right native handler.
struct LinkRouter: WebPage.NavigationDeciding {
    private static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]
    private static let externalSchemes: Set<String> = ["http", "https", "mailto"]

    let store: PageStore

    mutating func decidePolicy(
        for action: WebPage.NavigationAction, preferences: inout WebPage.NavigationPreferences
    ) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        if store.isCurrentPage(url) { return .allow }
        guard action.navigationType == .linkActivated else { return .cancel }

        if let file = store.fileURL(for: url) {
            if Self.markdownExtensions.contains(file.pathExtension.lowercased()) {
                NSDocumentController.shared.openDocument(withContentsOf: file, display: true) { _, _, error in
                    if let error {
                        log.error("open failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            } else {
                NSWorkspace.shared.open(file)
            }
        } else if let scheme = url.scheme?.lowercased(), Self.externalSchemes.contains(scheme) {
            NSWorkspace.shared.open(url)
        }
        return .cancel
    }
}
