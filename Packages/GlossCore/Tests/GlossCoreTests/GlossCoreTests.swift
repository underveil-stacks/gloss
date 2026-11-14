import Foundation
import Testing

@testable import GlossCore

@Suite struct MarkdownRendererTests {
    @Test func rendersGitHubTables() {
        let html = MarkdownRenderer.render("| a | b |\n|---|---|\n| 1 | 2 |\n").html
        #expect(html.contains("<table"))
        #expect(html.contains(">1</td>"))
    }

    @Test func rendersFormControlsWrittenInHTML() {
        let html = MarkdownRenderer.render(
            "<textarea name=\"notes\">\none\n\n# two\n</textarea>\n\n| a | b |\n|---|---|\n| x | <select name=\"s\"><option>1</option></select> |\n\n<script>alert(1)</script>\n<input type=\"password\">\n"
        ).html
        // A blank line inside the box does not end it.
        #expect(html.contains("<textarea name=\"user-content-notes\">\none\n\n# two\n</textarea>"))
        #expect(html.contains("<select name=\"user-content-s\"><option>1</option></select>"))
        #expect(!html.contains("script"))
        #expect(!html.contains("password"))
    }

    @Test func rendersTaskListsStrikethroughAndAutolinks() {
        let html = MarkdownRenderer.render("- [x] done\n- [ ] todo\n\n~~gone~~ https://example.com\n").html
        #expect(html.contains("type=\"checkbox\""))
        #expect(html.contains("<del>gone</del>"))
        #expect(html.contains("<a href=\"https://example.com\">"))
    }

    @Test func rendersFootnotes() {
        let html = MarkdownRenderer.render("Text[^1].\n\n[^1]: The note.\n").html
        #expect(html.contains("footnote"))
        #expect(html.contains("The note."))
    }

    @Test func dropsRawHTMLAndScriptURLs() {
        let source = "<script>alert(1)</script>\n\n<img src=x onerror=alert(1)>\n\n[x](javascript:alert(1))\n"
        let html = MarkdownRenderer.render(source).html
        #expect(!html.contains("<script"))
        #expect(!html.contains("onerror"))
        #expect(!html.contains("javascript:"))
    }

    @Test func allowsHarmlessRawHTML() {
        let source = "<details><summary>More</summary>\n\nHidden **text**.\n\n</details>\n\nPress <kbd>F</kbd>, H<sub>2</sub>O, x<sup>2</sup>.\n"
        let html = MarkdownRenderer.render(source).html
        for tag in ["<details>", "<summary>More</summary>", "<kbd>F</kbd>", "<sub>2</sub>", "<sup>2</sup>", "<strong>text</strong>"] {
            #expect(html.contains(tag), "\(tag) was removed")
        }
    }

    @Test func rawHTMLCannotForgeWhatGlossAddsAfterSanitizing() {
        // Heading ids, alerts and highlighting are added by Gloss after the
        // sanitizer has run. A document must not be able to write them itself.
        let source = "<div class=\"markdown-alert markdown-alert-note\">x</div>\n\n<h2 id=\"real\" onclick=\"x\">Fake</h2>\n\n<pre><code class=\"language-js hljs\"><span class=\"hljs-keyword\" style=\"color:red\">k</span></code></pre>\n\n## Real\n"
        let html = MarkdownRenderer.render(source).html
        #expect(!html.contains("markdown-alert"))
        #expect(!html.contains("onclick"))
        #expect(!html.contains("style="))
        #expect(!html.contains("id=\"real\">Fake"))
        #expect(html.contains("<h2 id=\"real\" data-sourcepos="))
    }

    @Test func rawHTMLCannotTakeARealElementsSourcePosition() {
        // The real heading is on line 3, the real alert on line 5 and the real
        // code block on line 8. Each forgery claims one of those positions and
        // comes first in the document.
        let source = [
            "<h2 data-sourcepos=\"3:1-3:7\">Fake</h2><blockquote DATA-SOURCEPOS=\"5:1-6:6\">q</blockquote><pre data-sourcepos=\"8:1-10:3\"><code>forged</code></pre>",
            "",
            "## Real",
            "",
            "> [!NOTE]",
            "> note",
            "",
            "```swift",
            "let a = 1",
            "```",
        ].joined(separator: "\n")
        let html = MarkdownRenderer.render(source) { _, _ in "HIGHLIGHTED" }.html
        #expect(html.contains("<h2 id=\"real\" data-sourcepos=\"3:1-3:7\">Real</h2>"))
        #expect(!html.contains("\">Fake"))
        #expect(html.contains("<div class=\"markdown-alert markdown-alert-note\" data-sourcepos=\"5:1-6:6\">"))
        #expect(html.contains("<blockquote>q</blockquote>"))
        #expect(html.contains("<code>forged</code>"))
        #expect(html.contains("<code class=\"language-swift hljs\">HIGHLIGHTED</code>"))
        #expect(!html.contains("sourcepos-from-document"))
    }

    @Test func noticesRemoteImagesHoweverTheyAreWritten() {
        #expect(MarkdownRenderer.render("<img src=\" https://example.com/a.png\">").hasRemoteImages)
        #expect(MarkdownRenderer.render("<img srcset=\"https://example.com/a.png 2x\" src=\"a.png\">").hasRemoteImages)
        #expect(MarkdownRenderer.render("<picture><source srcset=\"https://example.com/a.webp\"><img src=\"a.png\"></picture>").hasRemoteImages)
        #expect(!MarkdownRenderer.render("<img src=\"a.png\" alt=\"https://example.com\">").hasRemoteImages)
    }

    @Test func splitsFrontMatterAndKeepsLineNumbers() {
        let source = "---\ntitle: Hello\n---\n\n# Heading\n"
        let document = MarkdownRenderer.render(source)
        #expect(document.frontMatter == "title: Hello")
        #expect(!document.html.contains("title: Hello"))
        #expect(document.headings == [Heading(level: 1, text: "Heading", id: "heading", line: 5)])
        #expect(document.html.contains("<h1 id=\"heading\" data-sourcepos=\"5:1-5:9\">"))
    }

    @Test func leavesAnUnclosedFenceAsMarkdown() {
        let document = MarkdownRenderer.render("---\nnot front matter\n")
        #expect(document.frontMatter == nil)
        #expect(document.html.contains("not front matter"))
    }

    @Test func headingIDsFollowGitHubAnchorRules() {
        let source = "# Hello, World!\n\n## Hello World\n\n## `code` & more_stuff\n\n> ## Quoted\n\n## Über Größe\n"
        let ids = MarkdownRenderer.render(source).headings.map(\.id)
        #expect(ids == ["hello-world", "hello-world-1", "code--more_stuff", "quoted", "über-größe"])
    }

    @Test func rendersGitHubAlerts() {
        let source = "> [!WARNING]\n> Mind the gap.\n>\n> > nested quote\n\n> [!note]\n> not an alert\n\n> [!TIP] same line\n"
        let html = MarkdownRenderer.render(source).html
        #expect(html.contains("<div class=\"markdown-alert markdown-alert-warning\""))
        #expect(html.contains("<p class=\"markdown-alert-title\">Warning</p>"))
        #expect(html.contains("Mind the gap."))
        #expect(!html.contains("[!WARNING]"))
        // The nested quote stays a quote, and the alert closes after it.
        #expect(html.contains("<blockquote"))
        #expect(html.components(separatedBy: "</div>").count == 2)
        // Lowercase and same-line markers are ordinary quotes, as on GitHub.
        #expect(html.contains("[!note]"))
        #expect(html.contains("[!TIP] same line"))
    }

    @Test func alertWithOnlyAMarkerHasNoEmptyParagraph() {
        let html = MarkdownRenderer.render("> [!NOTE]\n").html
        #expect(html.contains("markdown-alert-note"))
        #expect(!html.contains("<p data-sourcepos"))
    }

    @Test func highlighterOutputReplacesTheCodeBlock() {
        let source = "```swift\nlet a = \"<b>\"\n```\n\n```\nplain\n```\n\n```unknown\nx\n```\n"
        let html = MarkdownRenderer.render(source) { code, language in
            language == "swift" ? "<span class=\"hljs-keyword\">\(code.count)</span>" : nil
        }.html
        #expect(html.contains("<code class=\"language-swift hljs\"><span class=\"hljs-keyword\">14</span></code></pre>"))
        #expect(html.contains("<code>plain\n</code>"))
        #expect(html.contains("<code class=\"language-unknown\">x\n</code>"))
    }

    @Test func reportsCodeLanguages() {
        let document = MarkdownRenderer.render("```Mermaid\ngraph TD\n```\n\n```swift title=x\nlet a\n```\n\n```\nplain\n```\n")
        #expect(document.codeLanguages == ["mermaid", "swift"])
    }

    @Test func noticesRemoteImages() {
        #expect(MarkdownRenderer.render("![a](https://example.com/a.png)").hasRemoteImages)
        #expect(!MarkdownRenderer.render("![a](img/a.png) https://example.com/a.png").hasRemoteImages)
    }

    @Test func outlineUsesPlainText() {
        let document = MarkdownRenderer.render("# One `two` *three*\n\n## Four\n")
        #expect(document.headings.map(\.text) == ["One two three", "Four"])
        #expect(document.headings.map(\.level) == [1, 2])
    }
}

@Suite struct DocumentRootTests {
    private func makeTree() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("gloss-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: base.appendingPathComponent("repo/.git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: base.appendingPathComponent("repo/docs/img"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: base.appendingPathComponent("loose"), withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: base.appendingPathComponent("outside.txt"))
        try Data("# hi".utf8).write(to: base.appendingPathComponent("repo/docs/guide.md"))
        try Data("# hi".utf8).write(to: base.appendingPathComponent("loose/note.md"))
        return base.resolvingSymlinksInPath()
    }

    @Test func usesTheEnclosingGitRepository() throws {
        let base = try makeTree()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = DocumentRoot.find(for: base.appendingPathComponent("repo/docs/guide.md"))
        #expect(root.url.path == base.appendingPathComponent("repo").path)
        #expect(root.relativePath(of: base.appendingPathComponent("repo/docs/guide.md")) == "docs/guide.md")
    }

    @Test func fallsBackToTheDocumentDirectory() throws {
        let base = try makeTree()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = DocumentRoot.find(for: base.appendingPathComponent("loose/note.md"))
        #expect(root.url.path == base.appendingPathComponent("loose").path)
    }

    @Test func refusesPathsThatEscapeTheRoot() throws {
        let base = try makeTree()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = DocumentRoot(url: base.appendingPathComponent("repo"))
        #expect(root.resolve("docs/img") != nil)
        #expect(root.resolve("/docs/../docs/guide.md") != nil)
        #expect(root.resolve("../outside.txt") == nil)
        #expect(root.resolve("docs/../../outside.txt") == nil)

        let link = base.appendingPathComponent("repo/docs/escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: base.appendingPathComponent("outside.txt"))
        #expect(root.resolve("docs/escape") == nil)
    }
}

@Suite struct FrontMatterTests {
    @Test func readsScalarsListsAndQuotes() {
        let yaml = "title: \"Release: notes\"\n# comment\ntags: [one, 'two']\nauthors:\n  - Ada\n  - Grace\ndraft: true\nempty:\n"
        #expect(FrontMatter.entries(in: yaml) == [
            .init(key: "title", value: "Release: notes"),
            .init(key: "tags", value: "one, two"),
            .init(key: "authors", value: "Ada, Grace"),
            .init(key: "draft", value: "true"),
            .init(key: "empty", value: ""),
        ])
    }

    @Test func givesUpOnTextThatIsNotKeyValueLines() {
        #expect(FrontMatter.entries(in: "just some text\nmore").isEmpty)
        #expect(FrontMatter.entries(in: "- a\n- b").isEmpty)
        #expect(FrontMatter.entries(in: "url:http://x").isEmpty)
    }
}

@Suite struct HTMLPageTests {
    private let spec = PageSpec(
        title: "<a> & \"b\"", appearance: "dark", themeID: "t", stylesheets: ["gloss://app/base.css"],
        printStylesheets: ["gloss://app/print.css"], scripts: ["gloss://app/gloss.js"], nonce: "n1")

    @Test func policyAllowsOnlyTheAppSchemeAndTheNonce() {
        let policy = HTMLPage.contentSecurityPolicy(scheme: "gloss", nonce: "abc")
        #expect(policy.contains("default-src 'none'"))
        #expect(policy.contains("script-src 'nonce-abc'"))
        #expect(!policy.contains("https:"))
        #expect(!policy.contains("unsafe-inline"))
    }

    @Test func policyOpensOnlyWhatIsAskedFor() {
        let remote = HTMLPage.contentSecurityPolicy(scheme: "gloss", nonce: "abc", allowsRemoteImages: true)
        #expect(remote.contains("img-src gloss: data: https:"))
        #expect(!remote.contains("unsafe-inline"))
        let inline = HTMLPage.contentSecurityPolicy(scheme: "gloss", nonce: "abc", allowsInlineStyles: true)
        #expect(inline.contains("style-src gloss: 'unsafe-inline'"))
        #expect(!inline.contains("https:"))
        #expect(!inline.contains("script-src 'nonce-abc' 'unsafe-inline'"))
    }

    @Test func wrapBuildsTheContractStructure() {
        let page = HTMLPage.wrap(
            RenderedDocument(html: "<p>x</p>", frontMatter: "title: <T>", headings: []), spec: spec)
        #expect(page.contains("<html data-appearance=\"dark\" data-theme=\"t\">"))
        #expect(page.contains("<title>&lt;a&gt; &amp; &quot;b&quot;</title>"))
        var fitting = spec
        fitting.fitsWindow = true
        #expect(
            HTMLPage.wrap(RenderedDocument(html: "", frontMatter: nil, headings: []), spec: fitting)
                .contains("<html data-appearance=\"dark\" data-theme=\"t\" data-width=\"window\">"))
        #expect(page.contains("<header class=\"gloss-frontmatter\">"))
        #expect(page.contains("<dt>title</dt><dd>&lt;T&gt;</dd>"))
        #expect(page.contains("<article class=\"markdown-body\">"))
        #expect(page.contains("<link rel=\"stylesheet\" media=\"print\" href=\"gloss://app/print.css\">"))
        #expect(page.contains("<script nonce=\"n1\" src=\"gloss://app/gloss.js\"></script>"))
    }

    @Test func frontMatterThatIsNotKeyValueIsShownAsText() {
        let html = HTMLPage.frontMatterHTML(RenderedDocument(html: "", frontMatter: "- <a>\n- b", headings: []))
        #expect(html.contains("<pre><code>- &lt;a&gt;\n- b</code></pre>"))
        #expect(HTMLPage.frontMatterHTML(RenderedDocument(html: "", frontMatter: nil, headings: [])).isEmpty)
    }
}

@Suite struct StandalonePageTests {
    @Test func isSelfContainedAndFollowsTheSystemAppearance() {
        let document = MarkdownRenderer.render("---\ntitle: T\n---\n# Hi\n\n![r](https://example.com/a.png)\n")
        let page = StandalonePage.html(
            for: document, title: "a<b>.md",
            baseCSS: "html[data-appearance=\"dark\"] { color-scheme: dark } html[data-appearance='light'] { color-scheme: light } /* </style><b>x</b> */",
            darkCSS: ":root { --gloss-bg: #000 }",
            lightCSS: "html[data-appearance=\"light\"] { --gloss-bg: #fff }")
        #expect(page.contains("default-src 'none'"))
        #expect(!page.contains("<script"))
        #expect(!page.contains("<link"))
        #expect(page.components(separatedBy: "</style>").count == 2, "a stylesheet closed the style element")
        #expect(page.contains("<title>a&lt;b&gt;.md</title>"))
        #expect(page.contains("<h1 id=\"hi\""))
        #expect(page.contains("<header class=\"gloss-frontmatter\">"))
        #expect(page.contains("<html data-appearance=\"system\""))

        // Each appearance gets the rules written for it, pointed at the page
        // as it is marked; the other appearance's rules are left matching nothing.
        let darkBlock = page.components(separatedBy: "@media (prefers-color-scheme: light)")[0]
        let lightBlock = page.components(separatedBy: "@media (prefers-color-scheme: light)")[1]
        #expect(darkBlock.contains("html[data-appearance=\"system\"] { color-scheme: dark }"))
        #expect(darkBlock.contains("html[data-appearance='light'] { color-scheme: light }"))
        #expect(darkBlock.contains(":root { --gloss-bg: #000 }"))
        #expect(lightBlock.contains("html[data-appearance=\"system\"] { color-scheme: light }"))
        #expect(lightBlock.contains("html[data-appearance=\"dark\"] { color-scheme: dark }"))
        #expect(lightBlock.contains("html[data-appearance=\"system\"] { --gloss-bg: #fff }"))
        #expect(!lightBlock.contains("--gloss-bg: #000"))
    }
}
