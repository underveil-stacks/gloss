import Foundation

/// Everything about a page that is not the document: how it looks and what
/// is loaded alongside it.
public struct PageSpec: Sendable, Equatable {
    public var title: String
    /// `light` or `dark`.
    public var appearance: String
    public var themeID: String
    /// The reader asked for the text to fill the window instead of the
    /// theme's measure.
    public var fitsWindow: Bool
    public var stylesheets: [String]
    public var printStylesheets: [String]
    public var scripts: [String]
    /// The value scripts must carry to be allowed to run.
    public var nonce: String

    public init(
        title: String, appearance: String, themeID: String, fitsWindow: Bool = false, stylesheets: [String],
        printStylesheets: [String] = [], scripts: [String] = [], nonce: String
    ) {
        self.title = title
        self.appearance = appearance
        self.themeID = themeID
        self.fitsWindow = fitsWindow
        self.stylesheets = stylesheets
        self.printStylesheets = printStylesheets
        self.scripts = scripts
        self.nonce = nonce
    }
}

/// Builds the full page around a rendered fragment, and the policy it is
/// served with.
public enum HTMLPage {
    /// The page's content security policy. Nothing loads by default; images,
    /// styles and fonts come only from the app's own scheme; scripts run only
    /// with this page's nonce, which the document never sees.
    ///
    /// - `allowsRemoteImages`: the reader asked for this document's remote
    ///   images.
    /// - `allowsInlineStyles`: an enabled add-on needs to write styles into
    ///   the page (diagram and math libraries do). Document-supplied `style`
    ///   attributes and elements never reach the page; the sanitizer removes
    ///   them.
    public static func contentSecurityPolicy(
        scheme: String, nonce: String, allowsRemoteImages: Bool = false, allowsInlineStyles: Bool = false
    ) -> String {
        [
            "default-src 'none'",
            "img-src \(scheme): data:" + (allowsRemoteImages ? " https:" : ""),
            "style-src \(scheme):" + (allowsInlineStyles ? " 'unsafe-inline'" : ""),
            "font-src \(scheme): data:",
            "script-src 'nonce-\(nonce)'",
            "base-uri 'none'",
            "form-action 'none'",
        ].joined(separator: "; ")
    }

    /// The front-matter header, or an empty string when the file has none.
    public static func frontMatterHTML(_ document: RenderedDocument) -> String {
        guard let yaml = document.frontMatter, !yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ""
        }
        let entries = FrontMatter.entries(in: yaml)
        if entries.isEmpty {
            return "<header class=\"gloss-frontmatter\"><pre><code>\(escape(yaml))</code></pre></header>"
        }
        let rows = entries.map { "<dt>\(escape($0.key))</dt><dd>\(escape($0.value))</dd>" }.joined(separator: "\n")
        return "<header class=\"gloss-frontmatter\">\n<dl>\n\(rows)\n</dl>\n</header>"
    }

    public static func articleHTML(_ document: RenderedDocument) -> String {
        "<article class=\"markdown-body\">\n\(document.html)\n</article>"
    }

    public static func wrap(_ document: RenderedDocument, spec: PageSpec) -> String {
        let styles = spec.stylesheets
            .map { "<link rel=\"stylesheet\" href=\"\(escape($0))\">" }
        let printStyles = spec.printStylesheets
            .map { "<link rel=\"stylesheet\" media=\"print\" href=\"\(escape($0))\">" }
        let scripts = spec.scripts
            .map { "<script nonce=\"\(escape(spec.nonce))\" src=\"\(escape($0))\"></script>" }
        let width = spec.fitsWindow ? " data-width=\"window\"" : ""
        return """
            <!doctype html>
            <html data-appearance="\(escape(spec.appearance))" data-theme="\(escape(spec.themeID))"\(width)>
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>\(escape(spec.title))</title>
            \((styles + printStyles).joined(separator: "\n"))
            </head>
            <body>
            \(frontMatterHTML(document))
            \(articleHTML(document))
            \(scripts.joined(separator: "\n"))
            </body>
            </html>
            """
    }

    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
