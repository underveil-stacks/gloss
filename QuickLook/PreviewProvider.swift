import Cocoa
import GlossCore
import QuickLookUI
import UniformTypeIdentifiers

/// Quick Look preview for Markdown files: the same renderer and built-in
/// themes as the app, as one self-contained page.
///
/// The extension is sandboxed and is handed only the file being previewed, so
/// it cannot show images stored beside the document, and it does not know
/// which theme or add-ons the reader chose in Gloss. Remote images are never
/// loaded.
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL
        let reply = QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 900, height: 1100)) { reply in
            let data = try Data(contentsOf: url)
            // Invalid UTF-8 is shown with replacement characters, never dropped.
            let source = String(decoding: data, as: UTF8.self)
            let document = MarkdownRenderer.render(source, highlighter: Highlighter.shared.codeHighlighter)
            reply.stringEncoding = .utf8
            reply.title = url.lastPathComponent
            return Data(
                StandalonePage.html(
                    for: document, title: url.lastPathComponent,
                    baseCSS: Self.resource("base.css"),
                    darkCSS: Self.resource("gloss-dark.glossbundle/theme.css"),
                    lightCSS: Self.resource("gloss-light.glossbundle/theme.css")
                ).utf8)
        }
        return reply
    }

    private static func resource(_ path: String) -> String {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent(path) else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}
