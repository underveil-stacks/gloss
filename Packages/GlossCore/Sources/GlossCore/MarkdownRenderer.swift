import Foundation
import cmark_gfm
import cmark_gfm_extensions

/// One heading in a document's outline.
public struct Heading: Sendable, Equatable {
    public let level: Int
    public let text: String
    /// The heading's `id` in the page, following GitHub's anchor rules.
    public let id: String
    /// 1-based line in the original file, front matter included.
    public let line: Int

    public init(level: Int, text: String, id: String, line: Int) {
        self.level = level
        self.text = text
        self.id = id
        self.line = line
    }
}

/// The result of rendering one Markdown file.
public struct RenderedDocument: Sendable, Equatable {
    /// An HTML fragment. Block elements carry `data-sourcepos`, with line
    /// numbers that match the original file.
    public let html: String
    /// The raw YAML between the front-matter fences, if the file has any.
    public let frontMatter: String?
    public let headings: [Heading]
    /// True when the document refers to an image on the network. The page
    /// will not load it unless the reader asks.
    public let hasRemoteImages: Bool
    /// The languages named on the document's fenced code blocks, lowercased.
    public let codeLanguages: Set<String>

    public init(
        html: String, frontMatter: String?, headings: [Heading], hasRemoteImages: Bool = false,
        codeLanguages: Set<String> = []
    ) {
        self.html = html
        self.frontMatter = frontMatter
        self.headings = headings
        self.hasRemoteImages = hasRemoteImages
        self.codeLanguages = codeLanguages
    }
}

/// Turns the text of a code block into highlighted HTML (the inside of a
/// `<code>` element), or nil to leave the block as plain text. The result is
/// trusted and inserted as is, so it must come from the app, never a document.
public typealias CodeHighlighter = @Sendable (_ code: String, _ language: String) -> String?

public enum MarkdownRenderer {
    /// GitHub's extension set, without `tagfilter`. That one escapes
    /// `<textarea>`, which documents may use as a form control, and everything
    /// else it covers the sanitizer removes with its content.
    private static let extensions = ["table", "strikethrough", "autolink", "tasklist"]


    public static func render(_ source: String, highlighter: CodeHighlighter? = nil) -> RenderedDocument {
        let split = FrontMatter.split(source)

        cmark_gfm_core_extensions_ensure_registered()
        // The parser lets raw HTML through, and HTMLSanitizer, which sees the
        // whole output, cuts it down to an allowlist.
        let options = CMARK_OPT_FOOTNOTES | CMARK_OPT_SOURCEPOS | CMARK_OPT_UNSAFE
        guard let parser = cmark_parser_new(options) else {
            return RenderedDocument(html: "", frontMatter: split.frontMatter, headings: [])
        }
        defer { cmark_parser_free(parser) }

        for name in extensions {
            if let ext = cmark_find_syntax_extension(name) {
                cmark_parser_attach_syntax_extension(parser, ext)
            }
        }

        // `split.body` keeps the front matter's lines as blanks, so every
        // source position the parser reports is a line in the original file.
        var body = split.body
        body.withUTF8 { buffer in
            buffer.withMemoryRebound(to: CChar.self) { chars in
                cmark_parser_feed(parser, chars.baseAddress, chars.count)
            }
        }
        guard let document = cmark_parser_finish(parser) else {
            return RenderedDocument(html: "", frontMatter: split.frontMatter, headings: [])
        }
        defer { cmark_node_free(document) }

        // Everything below edits the page by source position. The tree is read
        // (and alert markers removed) before rendering; the edits are applied
        // after sanitizing, so what they insert is not filtered away.
        disownSourcePositions(in: document)
        let alerts = Alerts.extract(from: document)
        let headings = outline(of: document)
        let codeBlocks = highlighter.map { highlightedBlocks(in: document, with: $0) } ?? []
        let languages = codeLanguages(in: document)

        var html = ""
        if let rendered = cmark_render_html(document, options, cmark_parser_get_syntax_extensions(parser)) {
            html = String(cString: rendered)
            free(rendered)
        }
        html = HTMLSanitizer.sanitize(html)

        for heading in headings {
            html = html.replacingFirst(
                "<h\(heading.heading.level) data-sourcepos=\"\(heading.position)\">",
                with: "<h\(heading.heading.level) id=\"\(HTMLPage.escape(heading.heading.id))\" data-sourcepos=\"\(heading.position)\">")
        }
        for alert in alerts {
            html = Alerts.apply(alert, to: html)
        }
        for block in codeBlocks {
            html = block.apply(to: html)
        }

        return RenderedDocument(
            html: html,
            frontMatter: split.frontMatter,
            headings: headings.map(\.heading),
            hasRemoteImages: html.range(
                of: #"<(img|source)\b[^>]*\s(src|srcset)="\s*https?:"#, options: [.regularExpression, .caseInsensitive])
                != nil,
            codeLanguages: languages
        )
    }

    // MARK: Source positions

    /// Heading ids, alerts and highlighted code are attached to elements by
    /// their `data-sourcepos`, which only the parser should write. Raw HTML in
    /// the document could carry the same attribute and take a real element's
    /// place, so the name is spoiled in every piece of raw HTML before
    /// rendering; the sanitizer then drops it as an unknown attribute.
    private static func disownSourcePositions(in document: UnsafeMutablePointer<cmark_node>) {
        forEachNode(in: document) { node in
            let type = cmark_node_get_type(node)
            guard type == CMARK_NODE_HTML_BLOCK || type == CMARK_NODE_HTML_INLINE,
                let literal = cmark_node_get_literal(node)
            else { return }
            let raw = String(cString: literal)
            guard raw.range(of: "sourcepos", options: .caseInsensitive) != nil else { return }
            let spoiled = raw.replacingOccurrences(of: "sourcepos", with: "sourcepos-from-document", options: .caseInsensitive)
            cmark_node_set_literal(node, spoiled)
        }
    }

    // MARK: Outline

    private struct PositionedHeading {
        let heading: Heading
        let position: String
    }

    private static func outline(of document: UnsafeMutablePointer<cmark_node>) -> [PositionedHeading] {
        var headings: [PositionedHeading] = []
        var slugs = Slugger()
        forEachNode(in: document) { node in
            guard cmark_node_get_type(node) == CMARK_NODE_HEADING else { return }
            let text = plainText(of: node)
            headings.append(
                PositionedHeading(
                    heading: Heading(
                        level: Int(cmark_node_get_heading_level(node)),
                        text: text,
                        id: slugs.slug(for: text),
                        line: Int(cmark_node_get_start_line(node))
                    ),
                    position: sourcePosition(of: node)
                ))
        }
        return headings
    }

    // MARK: Code

    private struct HighlightedBlock {
        let position: String
        let language: String
        let html: String

        func apply(to page: String) -> String {
            let open = "<pre data-sourcepos=\"\(position)\">"
            let close = "</code></pre>"
            guard let start = page.range(of: open),
                let end = page.range(of: close, range: start.upperBound..<page.endIndex)
            else { return page }
            let language = HTMLPage.escape(language)
            let block = "\(open)<code class=\"language-\(language) hljs\">\(html)\(close)"
            return page.replacingCharacters(in: start.lowerBound..<end.upperBound, with: block)
        }
    }

    private static func highlightedBlocks(
        in document: UnsafeMutablePointer<cmark_node>, with highlighter: CodeHighlighter
    ) -> [HighlightedBlock] {
        var blocks: [HighlightedBlock] = []
        forEachNode(in: document) { node in
            guard cmark_node_get_type(node) == CMARK_NODE_CODE_BLOCK,
                let info = cmark_node_get_fence_info(node),
                let literal = cmark_node_get_literal(node)
            else { return }
            let language = String(cString: info).split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
            guard !language.isEmpty, let html = highlighter(String(cString: literal), language) else { return }
            blocks.append(HighlightedBlock(position: sourcePosition(of: node), language: language, html: html))
        }
        return blocks
    }

    private static func codeLanguages(in document: UnsafeMutablePointer<cmark_node>) -> Set<String> {
        var languages: Set<String> = []
        forEachNode(in: document) { node in
            guard cmark_node_get_type(node) == CMARK_NODE_CODE_BLOCK, let info = cmark_node_get_fence_info(node)
            else { return }
            if let language = String(cString: info).split(whereSeparator: \.isWhitespace).first {
                languages.insert(language.lowercased())
            }
        }
        return languages
    }

    // MARK: Tree helpers

    static func forEachNode(
        in root: UnsafeMutablePointer<cmark_node>, _ body: (UnsafeMutablePointer<cmark_node>) -> Void
    ) {
        guard let iterator = cmark_iter_new(root) else { return }
        defer { cmark_iter_free(iterator) }
        var nodes: [UnsafeMutablePointer<cmark_node>] = []
        while true {
            let event = cmark_iter_next(iterator)
            if event == CMARK_EVENT_DONE { break }
            if event == CMARK_EVENT_ENTER, let node = cmark_iter_get_node(iterator) { nodes.append(node) }
        }
        // Collected first, so `body` may edit the tree.
        nodes.forEach(body)
    }

    static func sourcePosition(of node: UnsafeMutablePointer<cmark_node>) -> String {
        "\(cmark_node_get_start_line(node)):\(cmark_node_get_start_column(node))-\(cmark_node_get_end_line(node)):\(cmark_node_get_end_column(node))"
    }

    static func plainText(of node: UnsafeMutablePointer<cmark_node>) -> String {
        var text = ""
        forEachNode(in: node) { current in
            let type = cmark_node_get_type(current)
            if type == CMARK_NODE_TEXT || type == CMARK_NODE_CODE, let literal = cmark_node_get_literal(current) {
                text += String(cString: literal)
            }
        }
        return text
    }
}

/// GitHub's heading-anchor rules: lowercase, drop everything but letters,
/// digits, spaces, hyphens and underscores, turn spaces into hyphens, and
/// number repeats.
struct Slugger {
    private var seen: [String: Int] = [:]

    mutating func slug(for text: String) -> String {
        var base = ""
        for scalar in text.lowercased().unicodeScalars {
            if scalar == " " {
                base.append("-")
            } else if scalar == "-" || scalar == "_" || CharacterSet.alphanumerics.contains(scalar) {
                base.unicodeScalars.append(scalar)
            }
        }
        let count = seen[base, default: 0]
        seen[base] = count + 1
        return count == 0 ? base : "\(base)-\(count)"
    }
}

extension String {
    func replacingFirst(_ target: String, with replacement: String) -> String {
        guard let range = range(of: target) else { return self }
        return replacingCharacters(in: range, with: replacement)
    }
}
