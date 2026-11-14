import AppKit
import UniformTypeIdentifiers
import WebKit

/// Prints a document, paginated, using the page's print stylesheet.
///
/// The page is loaded a second time into an off-screen web view, served by
/// the same store, because only that kind of view can produce a paginated
/// print job.
@MainActor
final class PrintController: NSObject, WKNavigationDelegate {
    private static var active: Set<PrintController> = []

    private let webView: WKWebView
    private let handler: LegacySchemeHandler
    private let finish: (WKWebView) -> Void
    /// What the reader typed into the page's fields, put into this copy so
    /// the answers are printed too.
    private let answers: String

    private init(model: PageModel, answers: String, finish: @escaping (WKWebView) -> Void) {
        self.answers = answers
        handler = LegacySchemeHandler(store: model.store)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(handler, forURLScheme: PageStore.scheme)
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 1000), configuration: configuration)
        self.finish = finish
        super.init()
        webView.navigationDelegate = self
        Self.active.insert(self)
        webView.load(URLRequest(url: PageStore.pageURL(for: model.fileURL)))
    }

    static func print(_ model: PageModel) {
        Task { await print(model, answers: model.formState()) }
    }

    private static func print(_ model: PageModel, answers: String) {
        _ = PrintController(model: model, answers: answers) { webView in
            let operation = webView.printOperation(with: printInfo())
            operation.view?.frame = webView.bounds
            if let window = NSApp.keyWindow {
                operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
            } else {
                operation.run()
            }
        }
    }

    /// Writes the paginated print output to a PDF file, with no panel.
    static func writePDF(_ model: PageModel, to url: URL) async -> Bool {
        let answers = await model.formState()
        return await withCheckedContinuation { continuation in
            _ = PrintController(model: model, answers: answers) { webView in
                let info = printInfo()
                info.jobDisposition = .save
                info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
                let operation = webView.printOperation(with: info)
                operation.showsPrintPanel = false
                operation.showsProgressPanel = false
                operation.view?.frame = webView.bounds
                let delegate = PrintResult { continuation.resume(returning: $0) }
                operation.runModal(
                    for: NSApp.keyWindow ?? NSWindow(), delegate: delegate,
                    didRun: #selector(PrintResult.printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
                objc_setAssociatedObject(operation, "result", delegate, .OBJC_ASSOCIATION_RETAIN)
            }
        }
    }

    private static func printInfo() -> NSPrintInfo {
        let info = NSPrintInfo(dictionary: NSPrintInfo.shared.dictionary() as? [NSPrintInfo.AttributeKey: Any] ?? [:])
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        return info
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !answers.isEmpty else {
            finish(webView)
            Self.active.remove(self)
            return
        }
        webView.callAsyncJavaScript(
            "window.gloss && gloss.forms.apply(JSON.parse(answers))", arguments: ["answers": answers], in: nil, in: .page
        ) { [self] _ in
            finish(webView)
            Self.active.remove(self)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        Self.active.remove(self)
    }

    // The page only ever shows its own document.
    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        navigationAction.request.url?.scheme == PageStore.scheme ? .allow : .cancel
    }
}

private final class PrintResult: NSObject {
    private let completion: (Bool) -> Void

    init(completion: @escaping (Bool) -> Void) { self.completion = completion }

    @objc func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        completion(success)
    }
}

/// Saves the page as a single continuous PDF, as it appears on screen.
@MainActor
enum PDFExporter {
    static func export(_ model: PageModel) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let name = model.fileURL?.deletingPathExtension().lastPathComponent ?? "Document"
        panel.nameFieldStringValue = "\(name).pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await model.pdf().write(to: url)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }
}
