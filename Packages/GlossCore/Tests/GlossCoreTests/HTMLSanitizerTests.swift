import Foundation
import Testing

@testable import GlossCore

#if canImport(cmark_gfm) && canImport(cmark_gfm_extensions)
    import cmark_gfm
    import cmark_gfm_extensions

    /// What `MarkdownRenderer` will produce once raw HTML is let through: the
    /// same parser, extensions and options, plus `CMARK_OPT_UNSAFE`.
    private func renderUnsafe(_ source: String) -> String {
        cmark_gfm_core_extensions_ensure_registered()
        let options = CMARK_OPT_FOOTNOTES | CMARK_OPT_SOURCEPOS | CMARK_OPT_UNSAFE
        guard let parser = cmark_parser_new(options) else { return "" }
        defer { cmark_parser_free(parser) }
        for name in ["table", "strikethrough", "autolink", "tasklist"] {
            if let ext = cmark_find_syntax_extension(name) {
                cmark_parser_attach_syntax_extension(parser, ext)
            }
        }
        var body = source
        body.withUTF8 { buffer in
            buffer.withMemoryRebound(to: CChar.self) { chars in
                cmark_parser_feed(parser, chars.baseAddress, chars.count)
            }
        }
        guard let document = cmark_parser_finish(parser) else { return "" }
        defer { cmark_node_free(document) }
        guard let rendered = cmark_render_html(document, options, cmark_parser_get_syntax_extensions(parser)) else {
            return ""
        }
        defer { free(rendered) }
        return String(cString: rendered)
    }
#endif

// MARK: - An independent reading of the output

/// One tag of sanitizer output, read by a parser that accepts only the form
/// the sanitizer is meant to write.
private struct OutputTag {
    var name: String
    var isEnd: Bool
    var attributes: [(name: String, value: String?)]
    var raw: String
}

/// The tags in `html`, or `nil` if any `<` or `>` is not part of a tag of the
/// form `<name attr attr="value" />` or `</name>`.
private func outputTags(in html: String) -> [OutputTag]? {
    let characters = Array(html)
    var tags: [OutputTag] = []
    var index = 0
    func isNameCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || character == "-")
    }
    while index < characters.count {
        if characters[index] == ">" { return nil }
        guard characters[index] == "<" else {
            index += 1
            continue
        }
        let start = index
        index += 1
        var tag = OutputTag(name: "", isEnd: false, attributes: [], raw: "")
        if index < characters.count, characters[index] == "/" {
            tag.isEnd = true
            index += 1
        }
        while index < characters.count, isNameCharacter(characters[index]) {
            tag.name.append(characters[index])
            index += 1
        }
        guard !tag.name.isEmpty else { return nil }
        while index < characters.count, characters[index] == " " {
            index += 1
            if index < characters.count, characters[index] == "/" {
                index += 1
                break
            }
            var name = ""
            while index < characters.count, isNameCharacter(characters[index]) {
                name.append(characters[index])
                index += 1
            }
            guard !name.isEmpty, !tag.isEnd else { return nil }
            var value: String?
            if index < characters.count, characters[index] == "=" {
                guard index + 1 < characters.count, characters[index + 1] == "\"" else { return nil }
                index += 2
                var text = ""
                while index < characters.count, characters[index] != "\"" {
                    if "<>'`".contains(characters[index]) { return nil }
                    text.append(characters[index])
                    index += 1
                }
                guard index < characters.count else { return nil }
                index += 1
                value = text
            }
            tag.attributes.append((name, value))
        }
        guard index < characters.count, characters[index] == ">" else { return nil }
        index += 1
        tag.raw = String(characters[start..<index])
        tags.append(tag)
    }
    return tags
}

/// Kept separately from the sanitizer's own list on purpose.
private let allowedElements: Set<String> = [
    "h1", "h2", "h3", "h4", "h5", "h6", "h7", "h8", "br", "b", "i", "strong", "em", "a", "pre", "code",
    "img", "tt", "div", "ins", "del", "sup", "sub", "p", "ol", "ul", "table", "thead", "tbody", "tfoot",
    "blockquote", "dl", "dt", "dd", "kbd", "q", "samp", "var", "hr", "ruby", "rt", "rp", "li", "tr", "td",
    "th", "s", "strike", "summary", "details", "caption", "figure", "figcaption", "abbr", "bdo", "cite",
    "dfn", "mark", "small", "span", "time", "wbr", "picture", "source", "section", "input", "textarea",
    "select", "option", "optgroup", "label", "fieldset", "legend",
]

/// Kept separately from the sanitizer's own list on purpose.
private let allowedInputTypes: Set<String> = [
    "text", "search", "number", "range", "date", "time", "datetime-local", "month", "week", "email", "url",
    "tel", "color", "checkbox", "radio",
]

private let urlAttributes: Set<String> = ["href", "src", "srcset", "cite", "longdesc"]

/// The scheme a browser would give the URL in an attribute written as
/// `value`, or `nil` if it would resolve it as relative. Written from the URL
/// and HTML standards rather than from the sanitizer, which is stricter.
/// Returns "?" for a value it cannot be sure about.
private func browserScheme(of value: String) -> String? {
    let scalars = Array(value.unicodeScalars)
    var decoded: [Unicode.Scalar] = []
    var index = 0
    while index < scalars.count {
        guard scalars[index] == "&" else {
            decoded.append(scalars[index])
            index += 1
            continue
        }
        var cursor = index + 1
        if cursor < scalars.count, scalars[cursor] == "#" {
            cursor += 1
            var radix = 10
            if cursor < scalars.count, scalars[cursor] == "x" || scalars[cursor] == "X" {
                radix = 16
                cursor += 1
            }
            var digits = ""
            while cursor < scalars.count, Character(scalars[cursor]).isHexDigit,
                radix == 16 || Character(scalars[cursor]).isNumber
            {
                digits.unicodeScalars.append(scalars[cursor])
                cursor += 1
            }
            if !digits.isEmpty {
                if cursor < scalars.count, scalars[cursor] == ";" { cursor += 1 }
                decoded.append(UInt32(digits, radix: radix).flatMap(Unicode.Scalar.init) ?? "\u{FFFD}")
                index = cursor
                continue
            }
        } else {
            var name = ""
            while cursor < scalars.count, scalars[cursor].isASCII, Character(scalars[cursor]).isLetter || Character(scalars[cursor]).isNumber {
                name.unicodeScalars.append(scalars[cursor])
                cursor += 1
            }
            if !name.isEmpty, cursor < scalars.count, scalars[cursor] == ";" {
                let known: [String: Unicode.Scalar] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'"]
                if let scalar = known[name] {
                    decoded.append(scalar)
                    index = cursor + 1
                    continue
                }
                // Past the first `/`, `?` or `#` nothing can become a scheme.
                guard decoded.contains(where: { "/?#".unicodeScalars.contains($0) }) else { return "?" }
            }
        }
        decoded.append("&")
        index += 1
    }
    // The URL parser drops C0 controls and spaces at the ends, and tabs and
    // newlines anywhere.
    while let first = decoded.first, first.value <= 0x20 { decoded.removeFirst() }
    decoded.removeAll { $0 == "\t" || $0 == "\n" || $0 == "\r" }
    var scheme = ""
    for (position, scalar) in decoded.enumerated() {
        if scalar == ":" { return position == 0 ? nil : scheme.lowercased() }
        let character = Character(scalar)
        let isSchemeCharacter =
            scalar.isASCII && (character.isLetter || (position > 0 && (character.isNumber || "+-.".contains(character))))
        guard isSchemeCharacter else { return nil }
        scheme.unicodeScalars.append(scalar)
    }
    return nil
}

/// Asserts that nothing in `sanitize(input)` can run script or load a
/// disallowed element, and that sanitizing again changes nothing.
private func expectHarmless(_ input: String, sourceLocation: SourceLocation = #_sourceLocation) {
    let output = HTMLSanitizer.sanitize(input)
    let comment = Comment(rawValue: "input: \(input.debugDescription)\noutput: \(output.debugDescription)")
    #expect(HTMLSanitizer.sanitize(output) == output, comment, sourceLocation: sourceLocation)
    #expect(!output.lowercased().contains("<script"), comment, sourceLocation: sourceLocation)
    #expect(!output.contains("\0"), comment, sourceLocation: sourceLocation)
    guard let tags = outputTags(in: output) else {
        Issue.record("output is not in the sanitizer's own form\n\(comment)", sourceLocation: sourceLocation)
        return
    }
    var depth = 0
    for tag in tags {
        #expect(allowedElements.contains(tag.name), comment, sourceLocation: sourceLocation)
        if tag.isEnd {
            depth -= 1
            #expect(depth >= 0, "an end tag closes more than was opened\n\(comment)", sourceLocation: sourceLocation)
        } else if !["br", "hr", "img", "input", "source", "wbr"].contains(tag.name) {
            depth += 1
        }
        if tag.name == "input", let type = tag.attributes.first(where: { $0.name == "type" }) {
            #expect(allowedInputTypes.contains(type.value?.lowercased() ?? ""), comment, sourceLocation: sourceLocation)
        }
        if tag.name == "input" || tag.name == "textarea" || tag.name == "select" {
            #expect(
                !tag.attributes.contains { ["form", "autofocus", "autocomplete", "list", "accept"].contains($0.name) },
                comment, sourceLocation: sourceLocation)
        }
        for attribute in tag.attributes {
            let name = attribute.name
            #expect(!name.hasPrefix("on"), comment, sourceLocation: sourceLocation)
            #expect(
                !["style", "srcdoc", "formaction", "action", "data", "background", "content", "http-equiv"].contains(name),
                comment, sourceLocation: sourceLocation)
            guard urlAttributes.contains(name), let value = attribute.value else { continue }
            let candidates = name == "srcset" ? value.split(separator: ",").map(String.init) : [value]
            for candidate in candidates {
                let scheme = browserScheme(of: candidate)
                #expect(
                    scheme == nil || scheme == "http" || scheme == "https" || (scheme == "mailto" && name == "href"),
                    "scheme \(scheme ?? "")\n\(comment)", sourceLocation: sourceLocation)
            }
        }
    }
    #expect(depth == 0, "unbalanced output\n\(comment)", sourceLocation: sourceLocation)
}

private func sanitize(_ html: String) -> String { HTMLSanitizer.sanitize(html) }

// MARK: - What cmark-gfm writes

@Suite struct HTMLSanitizerPassThroughTests {
    /// Captured from cmark-gfm with `CMARK_OPT_UNSAFE`; none of it is raw HTML.
    private static let rendered: [String] = [
        #"<h1 data-sourcepos="1:1-1:15">Heading <em>one</em></h1>"# + "\n",
        #"<p data-sourcepos="3:1-5:9">Para with <code>code</code>, <strong>b</strong>, <em>i</em>, <del>del</del>, <a href="https://example.com">https://example.com</a>, <a href="http://www.example.com">www.example.com</a>, <a href="mailto:me@example.com">me@example.com</a>, <a href="https://a.b/c?d=1&amp;e=2">https://a.b/c?d=1&amp;e=2</a>."#
            + "\nHard<br />\nbreak and <a href=\"http://x.y\" title=\"ti&quot;tle\">link</a> and "
            + #"<img src="a/b.png" alt="img" title="t" /> &amp; &lt; &gt; &quot;quoted&quot; 'single' © A</p>"# + "\n",
        """
        <table data-sourcepos="7:1-9:13">
        <thead>
        <tr data-sourcepos="7:1-7:13">
        <th align="left" data-sourcepos="7:2-7:4">a</th>
        <th align="center" data-sourcepos="7:6-7:8">b</th>
        <th align="right" data-sourcepos="7:10-7:12">c</th>
        </tr>
        </thead>
        <tbody>
        <tr data-sourcepos="9:1-9:13">
        <td align="left" data-sourcepos="9:2-9:4">1</td>
        <td align="center" data-sourcepos="9:6-9:8">2</td>
        <td align="right" data-sourcepos="9:10-9:12">3</td>
        </tr>
        </tbody>
        </table>

        """,
        """
        <ul data-sourcepos="11:1-15:0">
        <li data-sourcepos="11:1-11:10"><input type="checkbox" checked="" disabled="" /> done</li>
        <li data-sourcepos="12:1-15:0"><input type="checkbox" disabled="" /> todo
        <ol data-sourcepos="13:3-15:0">
        <li data-sourcepos="13:3-13:11">nested</li>
        <li data-sourcepos="14:3-15:0">two</li>
        </ol>
        </li>
        </ul>
        <ol start="3" data-sourcepos="16:1-17:0">
        <li data-sourcepos="16:1-17:0">start</li>
        </ol>
        <blockquote data-sourcepos="18:1-18:7">
        <p data-sourcepos="18:3-18:7">quote</p>
        </blockquote>

        """,
        """
        <pre data-sourcepos="20:1-22:3"><code class="language-swift">let x = &quot;&lt;b&gt;&quot; &amp; 1
        </code></pre>
        <pre data-sourcepos="24:5-25:0"><code>indented
        </code></pre>
        <hr data-sourcepos="26:1-27:0" />

        """,
        """
        <p data-sourcepos="1:1-1:30">One<sup class="footnote-ref"><a href="#fn-1" id="fnref-1" data-footnote-ref>1</a></sup> two<sup class="footnote-ref"><a href="#fn-n" id="fnref-n" data-footnote-ref>2</a></sup> again<sup class="footnote-ref"><a href="#fn-1" id="fnref-1-2" data-footnote-ref>1</a></sup> <sup class="footnote-ref"><a href="#fn-caf%C3%A9" id="fnref-caf%C3%A9" data-footnote-ref>3</a></sup>.</p>
        <section class="footnotes" data-footnotes>
        <ol>
        <li id="fn-1">
        <p data-sourcepos="40:7-40:15">The note. <a href="#fnref-1" class="footnote-backref" data-footnote-backref data-footnote-backref-idx="1" aria-label="Back to reference 1">↩</a> <a href="#fnref-1-2" class="footnote-backref" data-footnote-backref data-footnote-backref-idx="1-2" aria-label="Back to reference 1-2">↩<sup class="footnote-ref">2</sup></a></p>
        </li>
        <li id="fn-n">
        <p data-sourcepos="41:7-41:20">Second <em>note</em>.</p>
        <p data-sourcepos="43:5-43:16">code in note <a href="#fnref-n" class="footnote-backref" data-footnote-backref data-footnote-backref-idx="2" aria-label="Back to reference 2">↩</a></p>
        </li>
        <li id="fn-caf%C3%A9">
        <p data-sourcepos="9:11-9:15">Note. <a href="#fnref-caf%C3%A9" class="footnote-backref" data-footnote-backref data-footnote-backref-idx="3" aria-label="Back to reference 3">↩</a></p>
        </li>
        </ol>
        </section>

        """,
    ]

    @Test(arguments: rendered) func capturedOutputIsUnchanged(_ html: String) {
        #expect(sanitize(html) == html)
    }

    private static let documents: [String] = [
        "# Heading *one*\n\n## Two `code`\n\nSetext\n======\n",
        "Para with `code`, **b**, *i*, ~~del~~, https://example.com, www.example.com, <me@example.com>.\nHard  \nbreak.\n",
        "[link](http://x.y \"ti\\\"tle\") and ![img](a/b.png \"t\") and [rel](../other.md#part) and [q](x?a=1&b=2).\n",
        "| a | b | c |\n|:--|:-:|--:|\n| 1 | 2 | 3 |\n| `x` | **y** | ~~z~~ |\n",
        "- [x] done\n- [ ] todo\n  1. nested\n  2. two\n\n3. start\n\n* loose\n\n* list\n",
        "> quote\n>\n> > nested\n\n```swift\nlet x = \"<b>\" & 1\n```\n\n    indented <i>\n\n~~~c++\nint x;\n~~~\n\n---\n",
        "Text[^1] and[^n] again[^1] and [^café].\n\n[^1]: The note.\n[^n]: Second *note*.\n\n    more\n[^café]: Accent.\n",
        "Entities &amp; &lt; &copy; &#x41; \"quoted\" and 1 < 2 > 0 & so on.\n",
        "---\ntitle: Front\n---\n\n# After front matter\n\nBody.\n",
    ]

    /// The parser as it runs today drops raw HTML, so its output is all
    /// cmark-gfm's own and the sanitizer must not touch a byte of it.
    @Test(arguments: documents) func rendererOutputIsUnchanged(_ markdown: String) {
        let document = MarkdownRenderer.render(markdown)
        #expect(!document.html.isEmpty)
        // The renderer gives headings an id after sanitizing; that part of its
        // output is not the sanitizer's input.
        guard document.headings.isEmpty else { return }
        #expect(sanitize(document.html) == document.html)
    }

    #if canImport(cmark_gfm) && canImport(cmark_gfm_extensions)
        @Test(arguments: documents) func unsafeRendererOutputIsUnchanged(_ markdown: String) {
            let html = renderUnsafe(markdown)
            #expect(!html.isEmpty)
            #expect(sanitize(html) == html)
        }

        @Test func allowedRawHTMLSurvivesTheRealRenderer() {
            let markdown = """
                <details open><summary>Sum</summary>

                inner *md*

                </details>

                <div align="center"><img src="x.png" width="10"><kbd>K</kbd><sub>s</sub><sup>p</sup><br><picture><source srcset="a.png" media="(prefers-color-scheme: dark)"><img src="b.png"></picture></div>

                Inline <kbd>Ctrl</kbd>+<kbd>C</kbd>, H<sub>2</sub>O, x<sup>2</sup>, a<br>b.
                """
            let html = renderUnsafe(markdown)
            #expect(sanitize(html) == html)
            #expect(html.contains("<details open><summary>Sum</summary>"))
            #expect(html.contains("<p data-sourcepos=\"3:1-3:10\">inner <em>md</em></p>"))
        }

        @Test func hostileMarkdownIsHarmlessAfterTheRealRenderer() {
            let markdown = """
                # Title <script>alert(1)</script>

                [x](javascript:alert(1)) ![y](javascript:alert(2)) <javascript:alert(3)>

                <img src=x onerror=alert(1)> <a href="jav&#x09;ascript:alert(1)" onclick="alert(2)">l</a>

                <svg onload=alert(1)><script>alert(2)</script></svg>

                <div style="position:fixed" onmouseover="alert(1)" id="app">

                *still markdown*

                </div>

                <object data="javascript:alert(1)"></object><noscript><p title="</noscript><img src=x onerror=alert(1)>">

                | a |
                |---|
                | <iframe src="javascript:alert(1)"></iframe> |

                ```html
                <script>alert(1)</script>
                ```
                """
            let html = renderUnsafe(markdown)
            #expect(html.contains("onerror"))
            #expect(html.contains("href=\"javascript:alert(1)\""))
            expectHarmless(html)
            let output = sanitize(html)
            #expect(output.contains("<em>still markdown</em>"))
            #expect(output.contains("<div id=\"user-content-app\">"))
            #expect(output.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        }
    #endif
}

// MARK: - Raw HTML that is allowed

@Suite struct HTMLSanitizerAllowedHTMLTests {
    @Test(arguments: [
        "<details open><summary>Sum</summary>\n<p>body</p>\n</details>",
        "<kbd>Ctrl</kbd>+<kbd>C</kbd>",
        "H<sub>2</sub>O and x<sup>2</sup>",
        "a<br>b<br />c<hr>d<wbr>e",
        "<img src=\"a/b.png\" alt=\"A\" width=\"10\" height=\"20\" align=\"right\">",
        "<img src=\"https://example.com/a.png\">",
        "<img src=\"http://example.com/a.png\" longdesc=\"/long.html\">",
        "<div align=\"center\"><b>x</b></div>",
        "<picture><source srcset=\"a.png 1x, b.png 2x\" media=\"(prefers-color-scheme: dark)\" type=\"image/png\"><img src=\"c.png\" srcset=\"d.png 2x\" sizes=\"100vw\"></picture>",
        "<a href=\"https://example.com/?a=1&amp;b=2#f\" title=\"T\" rel=\"nofollow\" target=\"_blank\">x</a>",
        "<a href=\"mailto:me@example.com\">m</a> <a href=\"../x.md#part\">r</a> <a href=\"//example.com/x\">p</a> <a href=\"?q=1\">q</a> <a href=\"\">e</a>",
        "<b>b</b><i>i</i><strong>s</strong><em>e</em><tt>t</tt><ins>i</ins><del>d</del><s>s</s><strike>k</strike><mark>m</mark><small>s</small>",
        "<span>s</span><abbr title=\"T\">a</abbr><cite>c</cite><dfn>d</dfn><q cite=\"https://e.com\">q</q><samp>s</samp><var>v</var><time datetime=\"2026-01-01\">t</time><bdo dir=\"rtl\">b</bdo>",
        "<h1>1</h1><h2>2</h2><h3>3</h3><h4>4</h4><h5>5</h5><h6>6</h6>",
        "<dl><dt>t</dt><dd>d</dd></dl><ruby>k<rp>(</rp><rt>r</rt><rp>)</rp></ruby>",
        "<figure><img src=\"x.png\"><figcaption>c</figcaption></figure>",
        "<table><caption>c</caption><thead><tr><th scope=\"col\" colspan=\"2\">h</th></tr></thead><tbody><tr><td rowspan=\"2\" valign=\"top\">d</td></tr></tbody><tfoot><tr><td>f</td></tr></tfoot></table>",
        "<blockquote cite=\"https://example.com/src\"><p>q</p></blockquote>",
        "<ol start=\"3\" type=\"a\"><li value=\"5\">x</li></ol>",
        "<pre><code class=\"language-c++\">x</code></pre>",
        "<ul class=\"contains-task-list\"><li class=\"task-list-item\"><input type=\"checkbox\" class=\"task-list-item-checkbox\" disabled> x</li></ul>",
        "<p lang=\"fr\" dir=\"ltr\" role=\"note\" aria-label=\"L\" aria-hidden=\"true\" itemprop=\"p\">x</p>",
        "<div itemscope itemtype=\"https://schema.org/Thing\">x</div>",
    ])
    func isUnchanged(_ html: String) {
        #expect(sanitize(html) == html)
        expectHarmless(html)
    }

    @Test func textIsKeptAndEscaped() {
        #expect(sanitize("1 < 2 > 0 & AT&T &amp; &copy; &#65; \"q\" 'a'") == "1 &lt; 2 &gt; 0 & AT&T &amp; &copy; &#65; \"q\" 'a'")
        #expect(sanitize("a <3 b << c <") == "a &lt;3 b &lt;&lt; c &lt;")
        // cmark-gfm's tagfilter writes a bare `>`.
        #expect(sanitize("&lt;script>alert(1)&lt;/script>") == "&lt;script&gt;alert(1)&lt;/script&gt;")
        #expect(sanitize("") == "")
        #expect(sanitize("naïve — ✓ 日本語") == "naïve — ✓ 日本語")
    }

    @Test func tagAndAttributeNamesAreLowercased() {
        #expect(sanitize("<DIV ALIGN=\"Center\"><KBD>K</KBD></DIV>") == "<div align=\"Center\"><kbd>K</kbd></div>")
        #expect(sanitize("<A HREF=\"HTTPS://EXAMPLE.COM\">x</A>") == "<a href=\"HTTPS://EXAMPLE.COM\">x</a>")
    }

    @Test func attributeFormsAreNormalized() {
        #expect(sanitize("<img src=a.png alt='it\"s'>") == "<img src=\"a.png\" alt=\"it&quot;s\">")
        #expect(sanitize("<img src = \"a.png\"\n\talt = x >") == "<img src=\"a.png\" alt=\"x\">")
        #expect(sanitize("<details open>x</details>") == "<details open>x</details>")
        #expect(sanitize("<details open=\"\">x</details>") == "<details open=\"\">x</details>")
        #expect(sanitize("<a href=>x</a>") == "<a href=\"\">x</a>")
        #expect(sanitize("<img src=a/>") == "<img src=\"a/\">")
        #expect(sanitize("<br/>") == "<br />")
        // Only void elements keep a closing slash; a browser ignores it elsewhere.
        #expect(sanitize("<div/>x") == "<div>x</div>")
    }
}

// MARK: - Elements

@Suite struct HTMLSanitizerElementTests {
    @Test(arguments: [
        "script", "style", "iframe", "object", "noscript", "template", "title", "xmp", "noembed",
        "noframes", "plaintext", "svg", "math",
    ])
    func removesElementAndContent(_ name: String) {
        #expect(sanitize("a<\(name)>gone <b>too</b></\(name)>b") == "ab")
        #expect(sanitize("a<\(name.uppercased()) x=\"1\">gone</\(name.uppercased()) >b") == "ab")
        // Unclosed, the element runs to the end, as it would in a browser.
        #expect(sanitize("a<\(name)>gone <b>too</b>") == "a")
    }

    @Test func removesEmbedWhichHasNoContent() {
        #expect(sanitize("a<embed src=\"x.swf\">b") == "ab")
    }

    @Test(arguments: [
        "form", "button", "font", "option", "optgroup", "center", "marquee", "blink", "video",
        "audio", "canvas", "body", "html", "head", "article", "nav", "header", "footer", "main", "aside", "dialog",
        "custom-element", "x", "frameset", "applet", "map", "col", "colgroup",
    ])
    func dropsTagsAndKeepsText(_ name: String) {
        #expect(sanitize("a<\(name) class=\"c\">kept <b>bold</b></\(name)>b") == "akept <b>bold</b>b")
    }

    @Test(arguments: ["link", "meta", "base", "area", "param", "track", "frame", "isindex", "keygen", "bgsound"])
    func dropsVoidElements(_ name: String) {
        #expect(sanitize("a<\(name) href=\"x\" content=\"y\">b") == "ab")
    }

    @Test func rawTextEndsOnlyAtItsOwnEndTag() {
        #expect(sanitize("<script>a</style>b<!-- </scriptx> --></script >c") == "c")
        #expect(sanitize("<style>a</script>b</STYLE\n>c") == "c")
        #expect(sanitize("<textarea><script>x</script></textarea>c") == "<textarea>&lt;script&gt;x&lt;/script&gt;</textarea>c")
        #expect(sanitize("<script>x</script/>c") == "c")
        // The end tag's own attributes are read with their quotes.
        #expect(sanitize("<script>x</script a=\">\">c") == "c")
        #expect(sanitize("<title>a<b>c</b>") == "")
    }

    @Test func nestedRemovedElementsAreCounted() {
        #expect(sanitize("<svg><svg><b>x</b></svg><b>y</b></svg>z") == "z")
        #expect(sanitize("<svg><p title=\"</svg>\">hidden</p></svg>z") == "z")
        #expect(sanitize("<svg/>z") == "z")
        #expect(sanitize("<svg><circle/><svg/></svg>z") == "z")
        #expect(sanitize("<object><object></object>x</object>z") == "z")
        #expect(sanitize("<math><mi>x</mi></math>z") == "z")
        #expect(sanitize("<svg><style>a</svg>b</style>hidden</svg>z") == "z")
        // `/>` closes nothing outside SVG and MathML.
        #expect(sanitize("<template/>hidden</template>z") == "z")
    }

    @Test func removesCommentsAndDeclarations() {
        #expect(sanitize("a<!-- c -->b") == "ab")
        #expect(sanitize("a<!-- <b>c</b> -- > --!>b") == "ab")
        #expect(sanitize("a<!---->b<!-->c<!--->d") == "abcd")
        #expect(sanitize("a<!DOCTYPE html>b") == "ab")
        #expect(sanitize("a<?php echo 1 ?>b") == "ab")
        #expect(sanitize("a<![CDATA[ <b>c</b> > ]]>b") == "ab")
        #expect(sanitize("a</>b</ x>c") == "abc")
        #expect(sanitize("a<!x>b") == "ab")
    }

    @Test func unterminatedMarkupIsText() {
        #expect(sanitize("a<!-- never closed") == "a&lt;!-- never closed")
        #expect(sanitize("a<!-- never <b>closed</b>") == "a&lt;!-- never <b>closed</b>")
        #expect(sanitize("a<b") == "a&lt;b")
        #expect(sanitize("a<img src=\"x") == "a&lt;img src=\"x")
        #expect(sanitize("a<img src=\"x\" alt=") == "a&lt;img src=\"x\" alt=")
        #expect(sanitize("a</b") == "a&lt;/b")
        #expect(sanitize("a<![CDATA[ never") == "a&lt;![CDATA[ never")
        #expect(sanitize("a<?php never") == "a&lt;?php never")
        // The quote never closes, so there is no tag; what follows is read afresh.
        #expect(sanitize("<a title=\"x><b>y</b>") == "&lt;a title=\"x&gt;<b>y</b>")
    }

    @Test func malformedTagsAreDropped() {
        #expect(sanitize("<img \"\"\"><b>x</b>") == "<b>x</b>")
        #expect(sanitize("<b <i>x</i>") == "x")
        #expect(sanitize("<a =foo href=\"x\">y</a>") == "y")
        #expect(sanitize("<img src=a\"b>") == "")
        #expect(sanitize("<img src=`a.png`>") == "")
        #expect(sanitize("<img src=a<b>") == "")
        // Name characters a browser accepts; the tag is one unknown element.
        #expect(sanitize("<scr<script>ipt>x") == "ipt&gt;x")
        #expect(sanitize("<b\u{0B}x>y</b>") == "y")
    }

    @Test func outputIsBalanced() {
        #expect(sanitize("</div>a</p></b>") == "a")
        #expect(sanitize("<div><b>x") == "<div><b>x</b></div>")
        #expect(sanitize("<b><i>x</b>y</i>z") == "<b><i>x</i></b>yz")
        #expect(sanitize("</br></img></input>") == "")
        #expect(sanitize("<ul><li>one<li>two</ul>") == "<ul><li>one</li><li>two</li></ul>")
        #expect(sanitize("<p>a<p>b") == "<p>a</p><p>b</p>")
        #expect(sanitize("<p>a<div>b</div>") == "<p>a</p><div>b</div>")
        #expect(sanitize("<dl><dt>a<dd>b<dt>c</dl>") == "<dl><dt>a</dt><dd>b</dd><dt>c</dt></dl>")
        #expect(
            sanitize("<table><tr><td>a<td>b<tr><th>c</table>")
                == "<table><tr><td>a</td><td>b</td></tr><tr><th>c</th></tr></table>")
        #expect(sanitize("<ul><li>a<ul><li>b</ul></ul>") == "<ul><li>a<ul><li>b</li></ul></li></ul>")
        // A dropped element's end tag cannot close an element that was kept.
        #expect(sanitize("<div><form></div></form>x") == "<div></div>x")
    }

    /// GitHub's rule, so that a document cannot close a list or table the
    /// page wraps it in.
    @Test func listItemsAndTablePartsNeedTheirContainer() {
        #expect(sanitize("<li>a</li>") == "a")
        #expect(sanitize("<li id=\"x\">a</li><a href=\"#x\">b</a>") == "a<a href=\"#x\">b</a>")
        #expect(sanitize("<ul><li>a</li></ul><li>b</li>") == "<ul><li>a</li></ul>b")
        #expect(sanitize("<ol><li>a</li></ol>") == "<ol><li>a</li></ol>")
        #expect(sanitize("<ul><div><li>a</li></div></ul>") == "<ul><div><li>a</li></div></ul>")
        for part in ["tr", "td", "th", "thead", "tbody", "tfoot"] {
            #expect(sanitize("</\(part)><\(part)>a</\(part)>b") == "ab")
        }
        #expect(sanitize("<table><tr><td>a</td></tr></table><tr><td>b</td></tr>") == "<table><tr><td>a</td></tr></table>b")
        #expect(sanitize("</td></tr></table><b>out</b>") == "<b>out</b>")
    }

    /// Remembering that one tag never ended must not condemn a later tag
    /// that does. Here the first tag fails inside the `'` value, and the
    /// second passes through the same bytes inside a `"` value and ends.
    @Test func aFailedTagDoesNotCondemnOneThatEnds() {
        #expect(sanitize("<a title=\"<b title=\" y='\">") == "&lt;a title=\"<b title=\" y=&#39;\"></b>")
        #expect(sanitize("<a title='<b title=' y=\"'>") == "&lt;a title='<b title=\" y=&quot;\"></b>")
        for input in ["<a t=\"<b t=\" y='\">", "<a t='<b t=' y=\"'>", "<a '<b title=\"x'>y</b>", "<a <b <i>x</i> \""] {
            #expect(sanitize(input) == HTMLSanitizer.sanitize(input, rememberingFailures: false))
        }
    }

    @Test func nullBytesAreRemoved() {
        #expect(sanitize("a\0b") == "ab")
        #expect(sanitize("<scr\0ipt>x</scr\0ipt>y") == "y")
        #expect(sanitize("<b\0>x</b>") == "<b>x</b>")
        #expect(sanitize("<img src=\"a\0.png\" o\0nerror=\"x\">") == "<img src=\"a.png\">")
    }
}

// MARK: - Attributes

@Suite struct HTMLSanitizerAttributeTests {
    @Test func dropsEventHandlersAndStyle() {
        #expect(sanitize("<b onclick=\"x\" ONMOUSEOVER=x onfoo style=\"color:red\" title=\"t\">y</b>") == "<b title=\"t\">y</b>")
        #expect(sanitize("<img src=\"a.png\" onerror=\"x\" onload=x>") == "<img src=\"a.png\">")
        #expect(sanitize("<img/src=\"a.png\"/onerror=\"x\">") == "<img src=\"a.png\">")
        #expect(sanitize("<img\tsrc=\"a.png\"\nonerror\n=\n\"x\"\u{0C}onload=x>") == "<img src=\"a.png\">")
        #expect(sanitize("<img src=\"a.png\"onerror=\"x\">") == "<img src=\"a.png\">")
    }

    /// The allowlist already keeps these out; this is the second lock, which
    /// has to hold on its own if someone adds to the allowlist.
    @Test func forbiddenAttributesAreRefusedWhateverTheAllowlistSays() {
        for name in ["onclick", "onerror", "on", "onanythingatall", "style", "srcdoc", "formaction"] {
            #expect(SanitizerPolicy.isForbidden(attribute: name))
        }
        for name in ["title", "open", "href", "nohref"] {
            #expect(!SanitizerPolicy.isForbidden(attribute: name))
        }
        #expect(SanitizerPolicy.globalAttributes.allSatisfy { !SanitizerPolicy.isForbidden(attribute: $0) })
        #expect(SanitizerPolicy.inputAttributes.allSatisfy { !SanitizerPolicy.isForbidden(attribute: $0) })
        for dangerous in ["script", "style", "iframe", "object", "embed", "link", "meta", "base", "form", "svg", "math"] {
            #expect(!SanitizerPolicy.elements.contains(dangerous))
        }
    }

    @Test(arguments: [
        "srcdoc", "formaction", "action", "data", "background", "poster", "xlink:href", "xmlns", "is", "slot",
        "contenteditable", "draggable", "autofocus", "hidden", "data-x", "data-sourceposx", "ping", "download",
        "integrity", "http-equiv", "content", "dynsrc", "lowsrc", "manifest", "nonce", "part", "popover",
        "popovertarget", "form", "attributename", "href",
    ])
    func dropsAttribute(_ name: String) {
        #expect(sanitize("<span \(name)=\"v\" title=\"t\">x</span>") == "<span title=\"t\">x</span>")
    }

    @Test func urlAttributesAreBoundToTheirElements() {
        #expect(sanitize("<div href=\"x\" src=\"y\" cite=\"z\" srcset=\"w\" longdesc=\"v\">x</div>") == "<div>x</div>")
        #expect(sanitize("<a src=\"y\" cite=\"z\">x</a>") == "<a>x</a>")
        #expect(sanitize("<img href=\"x\" cite=\"z\">") == "<img>")
        #expect(sanitize("<span itemscope itemtype=\"t\" sizes=\"s\">x</span>") == "<span>x</span>")
    }

    @Test func keepsTheFirstOfDuplicateAttributes() {
        #expect(sanitize("<a href=\"http://one\" href=\"http://two\" HREF=\"http://three\">x</a>") == "<a href=\"http://one\">x</a>")
        #expect(sanitize("<a href=\"javascript:x\" href=\"http://two\">x</a>") == "<a>x</a>")
        #expect(sanitize("<b title=\"a\" title=\"b\">x</b>") == "<b title=\"a\">x</b>")
    }

    @Test func escapesAttributeValues() {
        #expect(
            sanitize("<b title='<script>\"x\" `y` & &z &amp; &#39; &#x27; &copy; a'>t</b>")
                == "<b title=\"&lt;script&gt;&quot;x&quot; &#96;y&#96; &amp; &amp;z &amp; &#39; &#x27; &copy; a\">t</b>")
        #expect(sanitize("<b title=\"it's\">t</b>") == "<b title=\"it&#39;s\">t</b>")
        #expect(sanitize("<b title=\"a&b=c&#x;&#;&;&\">t</b>") == "<b title=\"a&amp;b=c&amp;#x;&amp;#;&amp;;&amp;\">t</b>")
        #expect(sanitize("<a href=\"x\" title='\"onmouseover=\"alert(1)'>t</a>") == "<a href=\"x\" title=\"&quot;onmouseover=&quot;alert(1)\">t</a>")
    }

    @Test(arguments: [
        "javascript:alert(1)", "JaVaScRiPt:alert(1)", " javascript:alert(1)", "java\tscript:alert(1)",
        "java\nscript:alert(1)", "java\rscript:alert(1)", "\u{01}javascript:alert(1)", "java\u{7F}script:alert(1)",
        "jav&#x09;ascript:alert(1)", "jav&#x0A;ascript:alert(1)", "jav&#13;ascript:alert(1)",
        "&#106;avascript:alert(1)", "&#x6A;avascript:alert(1)", "&#X6a;avascript:alert(1)", "&#106avascript:alert(1)",
        "&#0000106;avascript:alert(1)", "javascript&#58;alert(1)", "javascript&#x3A;alert(1)", "javascript&#x3a(alert)(1)", "javascript&#58(alert)(1)",
        "javascript&colon;alert(1)", "java&Tab;script:alert(1)", "java&NewLine;script:alert(1)",
        "javascript&unknown;alert(1)", "&jfr;avascript:alert(1)", "vbscript:msgbox(1)", "VBScript:msgbox(1)",
        "data:text/html,<script>alert(1)</script>", "data:text/html;base64,PHNjcmlwdD4=", "DATA:,x",
        "file:///etc/passwd", "ftp://example.com/x", "gloss://theme/x", "blob:x", "about:blank", "tel:+1",
        "github-mac://x", "feed:javascript:alert(1)", "view-source:javascript:alert(1)", "jar:javascript:alert(1)!/",
        "x:alert(1)", ":alert(1)", "java script:alert(1)", "java&#0;script:alert(1)",
        "javascript:alert(1)//http://example.com", "java\u{00A0}script:x", "ｊavascript:x", "&#x110000;javascript:x",
        "&#99999999999999999999;javascript:x", "%6Aavascript:alert(1)",
    ])
    func rejectsURL(_ url: String) {
        let quoted = url.replacingOccurrences(of: "\"", with: "&quot;")
        #expect(sanitize("<a href=\"\(quoted)\">x</a>") == "<a>x</a>")
        #expect(sanitize("<img src=\"\(quoted)\">") == "<img>")
        #expect(sanitize("<img longdesc=\"\(quoted)\">") == "<img>")
        #expect(sanitize("<q cite=\"\(quoted)\">x</q>") == "<q>x</q>")
        #expect(sanitize("<img srcset=\"\(quoted)\">") == "<img>")
        #expect(sanitize("<img srcset=\"a.png 1x, \(quoted) 2x\">") == "<img>")
    }

    @Test func schemesDependOnTheAttribute() {
        #expect(sanitize("<a href=\"mailto:a@b.c\">x</a>") == "<a href=\"mailto:a@b.c\">x</a>")
        #expect(sanitize("<a href=\"MAILTO:a@b.c\">x</a>") == "<a href=\"MAILTO:a@b.c\">x</a>")
        #expect(sanitize("<img src=\"mailto:a@b.c\">") == "<img>")
        #expect(sanitize("<q cite=\"mailto:a@b.c\">x</q>") == "<q>x</q>")
        #expect(sanitize("<img srcset=\"mailto:a@b.c\">") == "<img>")
    }

    @Test(arguments: [
        "http://example.com/a:b", "https://example.com/?q=javascript:x", "HtTpS://example.com", "a/b:c", "./a:b",
        "?a:b", "#a:b", "/abs/path", "//host/path", "a.png", "", "a b.png", "x?a=1&amp;b=2", "R&amp;D/notes.md",
        "h&#116;tp://example.com", "http&#58;//example.com&#58;80/", " https://example.com ", "x/caf&eacute;.md",
        "javascript&#x3aalert(1)",
    ])
    func acceptsURL(_ url: String) {
        // The last is not a script URL to a browser either: `&#x3aa` is one
        // reference, to U+03AA.
        let link = sanitize("<a href=\"\(url)\">x</a>")
        let image = sanitize("<img src=\"\(url)\">")
        #expect(link.hasPrefix("<a href=\""))
        #expect(image.hasPrefix("<img src=\""))
        #expect(sanitize(link) == link)
        #expect(sanitize(image) == image)
    }

    /// The sanitizer knows a handful of named references. Before the first
    /// `/`, `?` or `#` of a relative URL, one it does not know could be a
    /// colon, so the URL is refused: a false alarm for `&eacute;`, by design.
    @Test func refusesUnknownReferenceWhereASchemeCouldBe() {
        #expect(sanitize("<a href=\"caf&eacute;/x.md\">x</a>") == "<a>x</a>")
        #expect(sanitize("<a href=\"x&colon;y\">x</a>") == "<a>x</a>")
        #expect(sanitize("<a href=\"caf&eacute/x.md\">x</a>") == "<a href=\"caf&amp;eacute/x.md\">x</a>")
        #expect(sanitize("<a href=\"x/caf&eacute;.md\">x</a>") == "<a href=\"x/caf&eacute;.md\">x</a>")
    }

    @Test func sourceSetIsCheckedCandidateByCandidate() {
        #expect(sanitize("<img srcset=\"a.png 1x, https://e.com/b.png 2x\">") == "<img srcset=\"a.png 1x, https://e.com/b.png 2x\">")
        #expect(sanitize("<img srcset=\"a.png&#44; javascript:x\">") == "<img>")
        #expect(sanitize("<img srcset=\"a.png&comma;javascript:x\">") == "<img>")
        #expect(sanitize("<img srcset=\"a.png,javascript:x\">") == "<img>")
        #expect(sanitize("<img srcset=\"a.png&unknown; 1x\">") == "<img>")
        #expect(sanitize("<source srcset=\"data:image/png;base64,AA\">") == "<source>")
    }

    @Test func classKeepsOnlyKnownValues() {
        #expect(sanitize("<code class=\"language-swift evil\">x</code>") == "<code class=\"language-swift\">x</code>")
        #expect(sanitize("<code class=\"evil\">x</code>") == "<code>x</code>")
        #expect(sanitize("<div class=\"language-swift footnotes markdown-body\">x</div>") == "<div>x</div>")
        #expect(sanitize("<section class=\" x  footnotes\ty \">x</section>") == "<section class=\"footnotes\">x</section>")
        #expect(sanitize("<sup class=\"footnote-ref footnote-backref\">x</sup>") == "<sup class=\"footnote-ref\">x</sup>")
        #expect(sanitize("<a class=\"footnote-backref footnote-ref\">x</a>") == "<a class=\"footnote-backref\">x</a>")
        #expect(sanitize("<ol class=\"contains-task-list task-list-item\"><li class=\"task-list-item contains-task-list\">x</li></ol>")
            == "<ol class=\"contains-task-list\"><li class=\"task-list-item\">x</li></ol>")
        #expect(sanitize("<span class>x</span>") == "<span>x</span>")
    }

    @Test func taskListCheckboxesAreKept() {
        #expect(sanitize("<input type=\"checkbox\" disabled=\"\" checked=\"\" />") == "<input type=\"checkbox\" disabled=\"\" checked=\"\" />")
        #expect(sanitize("<input type=CHECKBOX disabled>") == "<input type=\"CHECKBOX\" disabled>")
    }

    @Test(arguments: [
        "text", "search", "number", "range", "date", "time", "datetime-local", "month", "week", "email", "url",
        "tel", "color", "checkbox", "radio",
    ])
    func formInputsAreKept(_ type: String) {
        let html = "<input type=\"\(type)\" name=\"user-content-a\" value=\"v\" placeholder=\"p\">"
        #expect(sanitize(html) == html)
        expectHarmless(html)
    }

    @Test func aMissingTypeIsATextBox() {
        #expect(sanitize("<input name=\"user-content-a\">") == "<input name=\"user-content-a\">")
    }

    /// A document must not be able to ask for a secret, reach a file, carry
    /// hidden data or act on the page.
    @Test(arguments: ["password", "file", "hidden", "image", "submit", "reset", "button", "checkbox ", "pass&#119;ord", "", "x"])
    func refusesOtherInputTypes(_ type: String) {
        #expect(sanitize("a<input type=\"\(type)\" value=\"v\">b") == "ab")
        #expect(sanitize("a<input type=\"text\" type=\"\(type)\">b") == "a<input type=\"text\">b")
        #expect(sanitize("a<input type=\"\(type)\" type=\"text\">b") == "ab")
        expectHarmless("a<input type=\"\(type)\" value=\"v\">b")
    }

    @Test func inputsKeepOnlyHarmlessAttributes() {
        #expect(
            sanitize("<input type=\"checkbox\" disabled name=\"n\" id=\"i\" value=\"v\" form=\"f\" title=\"t\" autofocus autocomplete=\"on\" list=\"l\" src=\"x\" formaction=\"x\" onfocus=\"x\" class=\"x task-list-item-checkbox\">")
                == "<input type=\"checkbox\" disabled name=\"user-content-n\" id=\"user-content-i\" value=\"v\" title=\"t\" class=\"task-list-item-checkbox\">")
        #expect(
            sanitize("<input type=\"number\" min=\"1\" max=\"9\" step=\"2\" readonly>")
                == "<input type=\"number\" min=\"1\" max=\"9\" step=\"2\" readonly>")
        // Range limits mean nothing elsewhere.
        #expect(sanitize("<p min=\"1\" placeholder=\"p\">x</p>") == "<p>x</p>")
    }

    @Test func textareaKeepsItsTextAndNothingElse() {
        #expect(sanitize("<textarea name=\"notes\" rows=\"3\" placeholder=\"Notes\">a &amp; b</textarea>")
            == "<textarea name=\"user-content-notes\" rows=\"3\" placeholder=\"Notes\">a &amp; b</textarea>")
        // Markup inside is text, so it can neither run nor end the box early.
        #expect(sanitize("<textarea><b>x</b></textarea >y") == "<textarea>&lt;b&gt;x&lt;/b&gt;</textarea>y")
        #expect(sanitize("<textarea></textareax><img src=x onerror=alert(1)></textarea>z")
            == "<textarea>&lt;/textareax&gt;&lt;img src=x onerror=alert(1)&gt;</textarea>z")
        #expect(sanitize("<TEXTAREA>x</TEXTAREA>") == "<textarea>x</textarea>")
        // Unclosed, it runs to the end, as in a browser, and is closed.
        #expect(sanitize("a<textarea>b <i>c") == "a<textarea>b &lt;i&gt;c</textarea>")
        // Inside removed content, or malformed, it goes with its content.
        #expect(sanitize("<svg><textarea>x</textarea></svg>z") == "z")
        #expect(sanitize("<textarea \"x\">gone</textarea>z") == "z")
        #expect(sanitize("<textarea onfocus=\"x\" autofocus form=\"f\">t</textarea>") == "<textarea>t</textarea>")
        for html in ["<textarea></textarea><script>x</script>", "<textarea><textarea>x</textarea>", "<textarea>&lt;/textarea&gt;<b>x</b>"] {
            expectHarmless(html)
        }
    }

    @Test func selectKeepsItsOptions() {
        let html = "<select name=\"user-content-s\" multiple><optgroup label=\"G\"><option value=\"1\">One</option><option selected>Two</option></optgroup></select>"
        #expect(sanitize(html) == html)
        // An option ends the one before it, as in a browser.
        #expect(sanitize("<select><option>a<option>b</select>") == "<select><option>a</option><option>b</option></select>")
        #expect(sanitize("<option>loose</option>") == "loose")
        expectHarmless("<select><option>a<optgroup><option>b</select></option>")
    }

    @Test func labelsFollowTheirControlIntoTheNamespace() {
        #expect(sanitize("<label for=\"a\">A</label><input id=\"a\">")
            == "<label for=\"user-content-a\">A</label><input id=\"user-content-a\">")
        #expect(sanitize("<fieldset><legend>L</legend><label><input type=\"radio\" name=\"r\" value=\"1\"> one</label></fieldset>")
            == "<fieldset><legend>L</legend><label><input type=\"radio\" name=\"user-content-r\" value=\"1\"> one</label></fieldset>")
        // `for` means nothing elsewhere.
        #expect(sanitize("<span for=\"a\">x</span>") == "<span>x</span>")
    }

    @Test func sourcePositionMustHaveItsShape() {
        #expect(sanitize("<p data-sourcepos=\"1:1-12:345\">x</p>") == "<p data-sourcepos=\"1:1-12:345\">x</p>")
        for bad in ["", "1:1", "1:1-2", "1:1-2:", "a:1-2:3", "1:1-2:3 ", "1:1-2:3;x", "-1:1-2:3", "1:1-2:3-4:5"] {
            #expect(sanitize("<p data-sourcepos=\"\(bad)\">x</p>") == "<p>x</p>")
        }
        #expect(sanitize("<p data-sourcepos>x</p>") == "<p>x</p>")
    }
}

// MARK: - id, name and in-page links

@Suite struct HTMLSanitizerNamespaceTests {
    @Test func prefixesIdAndName() {
        #expect(sanitize("<span id=\"app\">x</span>") == "<span id=\"user-content-app\">x</span>")
        #expect(sanitize("<a name=\"top\">x</a>") == "<a name=\"user-content-top\">x</a>")
        #expect(sanitize("<a NAME=location ID=document>x</a>") == "<a name=\"user-content-location\" id=\"user-content-document\">x</a>")
        #expect(sanitize("<h2 id=\"user-content-intro\">x</h2>") == "<h2 id=\"user-content-intro\">x</h2>")
        #expect(sanitize("<span id=\"User-Content-x\">x</span>") == "<span id=\"user-content-User-Content-x\">x</span>")
        #expect(sanitize("<span id=\"\" name>x</span>") == "<span>x</span>")
    }

    @Test func footnoteIdsAreExemptOnlyWhereCmarkWritesThem() {
        #expect(sanitize("<ol><li id=\"fn-1\">x</li></ol>") == "<ol><li id=\"fn-1\">x</li></ol>")
        #expect(sanitize("<a id=\"fnref-1\">x</a>") == "<a id=\"fnref-1\">x</a>")
        #expect(sanitize("<a id=\"fn-1\">x</a>") == "<a id=\"user-content-fn-1\">x</a>")
        #expect(sanitize("<ul><li id=\"fnref-1\">x</li></ul>") == "<ul><li id=\"user-content-fnref-1\">x</li></ul>")
        #expect(sanitize("<div id=\"fn-1\">x</div>") == "<div id=\"user-content-fn-1\">x</div>")
        #expect(sanitize("<ul><li name=\"fn-1\">x</li></ul>") == "<ul><li name=\"user-content-fn-1\">x</li></ul>")
        #expect(sanitize("<a name=\"fnref-1\">x</a>") == "<a name=\"user-content-fnref-1\">x</a>")
        #expect(sanitize("<ul><li id=\"fn\">x</li></ul>") == "<ul><li id=\"user-content-fn\">x</li></ul>")
        #expect(sanitize("<ul><li id=\"FN-1\">x</li></ul>") == "<ul><li id=\"user-content-FN-1\">x</li></ul>")
    }

    @Test func inPageLinksFollowTargetsTheDocumentDefines() {
        #expect(sanitize("<a href=\"#app\">x</a><span id=\"app\">y</span>") == "<a href=\"#user-content-app\">x</a><span id=\"user-content-app\">y</span>")
        // The target may come first, be a `name`, or already carry the prefix.
        #expect(sanitize("<a name=\"top\"></a><a href=\"#top\">x</a>") == "<a name=\"user-content-top\"></a><a href=\"#user-content-top\">x</a>")
        #expect(sanitize("<a href=\"#z\">x</a><b id=\"user-content-z\">y</b>") == "<a href=\"#user-content-z\">x</a><b id=\"user-content-z\">y</b>")
        #expect(sanitize("<a href=\"#user-content-app\">x</a><b id=\"app\">y</b>") == "<a href=\"#user-content-app\">x</a><b id=\"user-content-app\">y</b>")
        #expect(sanitize("<a title=\"#t\" href=\"#a&amp;b\" rel=\"#t\">x</a><b id=\"a&amp;b\">y</b><b id=\"t\">z</b>")
            == "<a title=\"#t\" href=\"#user-content-a&amp;b\" rel=\"#t\">x</a><b id=\"user-content-a&amp;b\">y</b><b id=\"user-content-t\">z</b>")
        // cmark-gfm percent-escapes a link's fragment; an id is not escaped.
        #expect(sanitize("<a href=\"#caf%C3%A9\">x</a><b id=\"café\">y</b>") == "<a href=\"#user-content-caf%C3%A9\">x</a><b id=\"user-content-café\">y</b>")
        #expect(sanitize("<a href=\"#a%20b\">x</a><b id=\"a b\">y</b>") == "<a href=\"#user-content-a%20b\">x</a><b id=\"user-content-a b\">y</b>")
        // Different spellings of one character meet once both are written out.
        #expect(sanitize("<a href=\"#it's\">x</a><b id=\"it&#39;s\">y</b>") == "<a href=\"#user-content-it&#39;s\">x</a><b id=\"user-content-it&#39;s\">y</b>")
        #expect(sanitize("<a href='#\"q\"'>x</a><b id='\"q\"'>y</b>") == "<a href=\"#user-content-&quot;q&quot;\">x</a><b id=\"user-content-&quot;q&quot;\">y</b>")
    }

    /// A link to something the document did not define is aimed at an id
    /// added after sanitizing (a heading's), and must not be moved.
    @Test func otherInPageLinksAreLeftAlone() {
        for href in ["#installation", "#", "#top", "#user-content-app", "#fn-1", "#fnref-1", "#caf%C3%A9", "#a&amp;b", "other.md#part", "?q#part"] {
            #expect(sanitize("<a href=\"\(href)\">x</a>") == "<a href=\"\(href)\">x</a>")
        }
        // Only an exact match counts.
        #expect(sanitize("<a href=\"#App\">x</a><b id=\"app\">y</b>") == "<a href=\"#App\">x</a><b id=\"user-content-app\">y</b>")
        #expect(sanitize("<a href=\"#ap\">x</a><b id=\"app\">y</b>") == "<a href=\"#ap\">x</a><b id=\"user-content-app\">y</b>")
        #expect(sanitize("<a href=\"x.md#app\">x</a><b id=\"app\">y</b>") == "<a href=\"x.md#app\">x</a><b id=\"user-content-app\">y</b>")
        // Only `href` on a link is a link.
        #expect(sanitize("<a title=\"#app\" rel=\"#app\">x</a><b id=\"app\">y</b>") == "<a title=\"#app\" rel=\"#app\">x</a><b id=\"user-content-app\">y</b>")
        // A name inside removed content, or on a dropped tag, defines nothing.
        #expect(sanitize("<svg><a id=\"x\"></a></svg><a href=\"#x\">x</a>") == "<a href=\"#x\">x</a>")
        #expect(sanitize("<form id=\"x\"></form><a href=\"#x\">x</a>") == "<a href=\"#x\">x</a>")
        #expect(sanitize("<button id=\"x\"></button><a href=\"#x\">x</a>") == "<a href=\"#x\">x</a>")
    }

    @Test func footnoteLinksAreLeftAlone() {
        // The reference comes before the footnote it points at.
        let footnote = "<a href=\"#fn-1\" id=\"fnref-1\">1</a><ol><li id=\"fn-1\"><a href=\"#fnref-1\">back</a></li></ol>"
        #expect(sanitize(footnote) == footnote)
        // A footnote keeps its links even if the document reuses its name.
        #expect(
            sanitize(footnote + "<b id=\"fn-1\">x</b><b name=\"fnref-1\">y</b>")
                == footnote + "<b id=\"user-content-fn-1\">x</b><b name=\"user-content-fnref-1\">y</b>")
        // Without a footnote of that name, the name is the document's own.
        #expect(sanitize("<a href=\"#fn-key\">x</a><h2 id=\"fn-key\">y</h2>") == "<a href=\"#user-content-fn-key\">x</a><h2 id=\"user-content-fn-key\">y</h2>")
        #expect(sanitize("<a href=\"#fn-1\">x</a><a id=\"fn-1\">y</a>") == "<a href=\"#user-content-fn-1\">x</a><a id=\"user-content-fn-1\">y</a>")
    }

    @Test func namespaceRulesAreIdempotent() {
        for input in [
            "<a href=\"#app\">x</a><span id=\"app\">y</span>", "<a href=\"#it's\">x</a><b id=\"it&#39;s\">y</b>",
            "<a href=\"#it&#39;s\">x</a><b id=\"it's\">y</b>", "<a href=\"#caf%C3%A9\">x</a><b id=\"café\">y</b>",
            "<a href=\"#&%61mp;\">x</a><b id=\"&amp;amp;\">y</b>", "<a href=\"#&%61mp;\">x</a><b id=\"&amp;\">y</b>",
            "<a href=\"#%26amp;\">x</a><b id=\"&\">y</b>", "<a href=\"#%22\">x</a><b id='\"'>y</b>",
            "<a href=\"#%2527\">x</a><b id=\"%27\">y</b><b id=\"'\">z</b>", "<a href=\"#a%\">x</a><b id=\"a%\">y</b>",
            "<a href=\"#fn-1\">x</a><ol><li id=\"fn-1\">y</li></ol><b id=\"fn-1\">z</b>",
            "<a href=\"#x\">1</a><a href=\"#user-content-x\">2</a><b id=\"user-content-x\">y</b><b id=\"x\">z</b>",
            "<a href=\"#x\">1</a><b id=\"x\">y</b><b id=\"user-content-user-content-x\">z</b>",
        ] {
            let once = sanitize(input)
            #expect(sanitize(once) == once, "input: \(input)\nonce: \(once)\ntwice: \(sanitize(once))")
        }
    }
}

// MARK: - Hostile input

@Suite struct HTMLSanitizerHostileTests {
    static let corpus: [String] = [
        // Script elements, plain and disguised.
        "<script>alert(1)</script>",
        "<SCRIPT SRC=http://evil.example/x.js></SCRIPT>",
        "<ScRiPt>alert(1)</sCrIpT>",
        "<scr<script>ipt>alert(1)</scr</script>ipt>",
        "<script/src=//evil.example/x.js></script>",
        "<script\n>alert(1)</script\n>",
        "<script>alert(1)",
        "<<script>alert(1);//<</script>",
        "</script><script>alert(1)</script>",
        "<script>/*</script><img src=x onerror=alert(1)>*/</script>",
        "<script \"\">alert(1)</script>",
        "<script><!--<script></script>alert(1)</script>",
        "<b <script>alert(1)</script>0",
        "<sc\0ript>alert(1)</sc\0ript>",
        // Event handlers.
        "<img src=x onerror=alert(1)>",
        "<img/src=x/onerror=alert(1)>",
        "<img\tsrc=x\tonerror=alert(1)>",
        "<img\nsrc=x\nonerror\n=\nalert(1)>",
        "<img\u{0C}src=x\u{0C}onerror=alert(1)>",
        "<img src=\"x\" ONERROR=\"alert(1)\">",
        "<img src=\"x\"onerror=\"alert(1)\">",
        "<img \"\"\"><script>alert(1)</script>\">",
        "<img src=x onerror=\"alert(1)\" src=javascript:alert(2)>",
        "<img src=x o\0nerror=alert(1)>",
        "<img src=x:alert(1) onerror=eval(src)>",
        "<a href=x onclick=alert(1)//>x</a>",
        "<body onload=alert(1)>",
        "<details open ontoggle=alert(1)>x</details>",
        "<input onfocus=alert(1) autofocus>",
        "<input type=\"image\" src=x onerror=alert(1)>",
        "<input type=checkbox onclick=alert(1)>",
        "<marquee onstart=alert(1)>x</marquee>",
        "<video><source onerror=alert(1)></video>",
        "<audio src=x onerror=alert(1)>",
        "<svg onload=alert(1)>",
        "<svg/onload=alert(1)>",
        "<p onmouseover=alert(1) onmouseout = 'alert(2)' ONCLICK=\"alert(3)\">x</p>",
        "<a href=\"x\" title='\"onmouseover=\"alert(1)'>x</a>",
        "<div =onclick=alert(1) onclick=alert(2)>x</div>",
        // Script URLs.
        "<a href=\"javascript:alert(1)\">x</a>",
        "<a href=javascript:alert(1)>x</a>",
        "<a href='javascript:alert(1)'>x</a>",
        "<a href=\"JaVaScRiPt:alert(1)\">x</a>",
        "<a href=\"  javascript:alert(1)\">x</a>",
        "<a href=\"jav\tascript:alert(1)\">x</a>",
        "<a href=\"jav&#x09;ascript:alert(1)\">x</a>",
        "<a href=\"jav&#x0A;ascript:alert(1)\">x</a>",
        "<a href=\" &#14; javascript:alert(1)\">x</a>",
        "<a href=\"\u{01}javascript:alert(1)\">x</a>",
        "<a href=\"&#106;&#97;&#118;&#97;&#115;&#99;&#114;&#105;&#112;&#116;&#58;alert(1)\">x</a>",
        "<a href=\"&#x6A&#x61&#x76&#x61&#x73&#x63&#x72&#x69&#x70&#x74&#x3A;alert(1)\">x</a>",
        "<a href=\"&#0000106avascript:alert(1)\">x</a>",
        "<a href=\"javascript&colon;alert(1)\">x</a>",
        "<a href=\"java&Tab;script&NewLine;:alert(1)\">x</a>",
        "<a href=\"javascript&unknown;alert(1)\">x</a>",
        "<a href=\"vbscript:msgbox(1)\">x</a>",
        "<a href=\"data:text/html;base64,PHNjcmlwdD5hbGVydCgxKTwvc2NyaXB0Pg==\">x</a>",
        "<a href=\"feed:javascript:alert(1)\">x</a>",
        "<a href=\"javascript:alert(1)\" href=\"http://example.com\">x</a>",
        "<a href=\"http://example.com\" href=\"javascript:alert(1)\">x</a>",
        "<img src=\"javascript:alert(1)\">",
        "<img src=`javascript:alert(1)`>",
        "<img src=\"data:image/svg+xml,<svg onload=alert(1)>\">",
        "<img srcset=\"x.png&#44; javascript:alert(1)\">",
        "<picture><source srcset=\"javascript:alert(1) 1x, data:image/png;base64,AAAA 2x\"><img src=x></picture>",
        "<blockquote cite=\"javascript:alert(1)\">x</blockquote>",
        "<table background=\"javascript:alert(1)\"><tr><td>x</td></tr></table>",
        // Elements that load or run things.
        "<iframe src=\"javascript:alert(1)\"></iframe>",
        "<iframe srcdoc=\"<script>alert(1)</script>\"></iframe>",
        "<object data=\"javascript:alert(1)\"></object>",
        "<embed src=\"javascript:alert(1)\">",
        "<svg><script>alert(1)</script></svg>",
        "<svg><a xlink:href=\"javascript:alert(1)\"><text>x</text></a></svg>",
        "<svg><animate onbegin=alert(1) attributeName=x dur=1s>",
        "<svg></svg><img src=x onerror=alert(1)>",
        "<math><mi xlink:href=\"javascript:alert(1)\">x</mi></math>",
        "<math><annotation-xml encoding=\"text/html\"><script>alert(1)</script></annotation-xml></math>",
        "<style>@import 'javascript:alert(1)';</style>",
        "<div style=\"background:url(javascript:alert(1))\">x</div>",
        "<link rel=stylesheet href=\"javascript:alert(1)\">",
        "<meta http-equiv=\"refresh\" content=\"0;url=javascript:alert(1)\">",
        "<base href=\"javascript:alert(1)//\">",
        "<form action=\"javascript:alert(1)\"><button formaction=\"javascript:alert(2)\">x</button></form>",
        "<isindex action=\"javascript:alert(1)\" type=image>",
        "<template><script>alert(1)</script></template>",
        "<plaintext><script>alert(1)</script>",
        // Markup split across a raw-text, comment or attribute boundary.
        "<noscript><p title=\"</noscript><img src=x onerror=alert(1)>\">",
        "<textarea></textarea><script>alert(1)</script>",
        "<textarea><img title=\"</textarea><img src=x onerror=alert(1)>\">",
        "<title></title><img src=x onerror=alert(1)>",
        "<style><img title=\"</style><img src=x onerror=alert(1)>\">",
        "<xmp><p title=\"</xmp><script>alert(1)</script>\">",
        "<iframe><p title=\"</iframe><script>alert(1)</script>\">",
        "<noembed><p title=\"</noembed><img src=x onerror=alert(1)>\">",
        "<!--<img src=\"--><img src=x onerror=alert(1)//\">",
        "<!--><script>alert(1)</script>-->",
        "<!-- --!><script>alert(1)</script>-->",
        "<![CDATA[><script>alert(1)</script>]]>",
        "<?xml version=\"1.0\"?><script>alert(1)</script>",
        "<!DOCTYPE x [<!ENTITY y \"z\">]><script>alert(1)</script>",
        "<p title=\"</p><script>alert(1)</script>\">x</p>",
        "<p title='><script>alert(1)</script>'>x</p>",
        "<a href=\"javascript:alert(1)\"\n<b>x</b>",
        // Never finished.
        "<img src=\"x\" onerror = \"alert(1)\"",
        "<a href=\"javascript:alert(1)",
        "<!-- <script>alert(1)</script>",
        "<img src=x onerror=alert(1)//",
        "<script",
        // Clobbering and page structure.
        "<a id=\"location\" name=\"body\">x</a><form id=\"document\"><input name=\"cookie\"></form>",
        "</article></body><div id=\"app\" class=\"markdown-body\">x</div>",
        "</div></div></div><div align=\"center\">x",
    ]

    @Test func corpusIsLargeAndDistinct() {
        #expect(Self.corpus.count >= 100)
        #expect(Set(Self.corpus).count == Self.corpus.count)
    }

    @Test(arguments: corpus) func isHarmless(_ input: String) {
        expectHarmless(input)
    }

    /// The same vectors where a document would put them: inside other
    /// markup, and after a tag that is never closed.
    @Test(arguments: corpus) func isHarmlessInContext(_ input: String) {
        expectHarmless("<div align=\"center\"><p>before \(input) after</p></div>")
        expectHarmless("<details><summary>\(input)</summary>\(input)")
        expectHarmless("<b title=\"\(input)\">x</b>")
        expectHarmless("<b title='\(input)'>x</b>")
    }

    @Test func knownOutputs() {
        #expect(sanitize("<script>alert(1)</script>") == "")
        #expect(sanitize("<scr<script>ipt>alert(1)</scr</script>ipt>") == "ipt&gt;alert(1)ipt&gt;")
        #expect(sanitize("<img src=x onerror=alert(1)>") == "<img src=\"x\">")
        #expect(sanitize("<img \"\"\"><script>alert(1)</script>\">") == "\"&gt;")
        #expect(sanitize("<noscript><p title=\"</noscript><img src=x onerror=alert(1)>\">") == "<img src=\"x\">\"&gt;")
        #expect(sanitize("<style><img title=\"</style><img src=x onerror=alert(1)>\">") == "<img src=\"x\">\"&gt;")
        // The quote ends up inside an unquoted value, which makes the tag malformed.
        #expect(sanitize("<!--<img src=\"--><img src=x onerror=alert(1)//\">") == "")
        #expect(sanitize("<!--<img src=\"--><img src=x onerror=alert(1)>\">") == "<img src=\"x\">\"&gt;")
        #expect(sanitize("<p title=\"</p><script>alert(1)</script>\">x</p>") == "<p title=\"&lt;/p&gt;&lt;script&gt;alert(1)&lt;/script&gt;\">x</p>")
        #expect(sanitize("<a href=\"jav&#x09;ascript:alert(1)\">x</a>") == "<a>x</a>")
        #expect(sanitize("<a id=\"location\" name=\"body\">x</a>") == "<a id=\"user-content-location\" name=\"user-content-body\">x</a>")
        #expect(sanitize("</article></body><div id=\"app\" class=\"markdown-body\">x</div>") == "<div id=\"user-content-app\">x</div>")
    }

    @Test func survivesLargeAndDeepInput() {
        let deep = String(repeating: "<div>", count: 20_000) + "x"
        #expect(sanitize(deep).hasSuffix(String(repeating: "</div>", count: 20_000)))
        let wide = String(repeating: "<", count: 50_000)
        #expect(sanitize(wide) == String(repeating: "&lt;", count: 50_000))
        let attributes = "<b " + String(repeating: "a=1 ", count: 20_000) + ">x</b>"
        #expect(sanitize(attributes) == "<b>x</b>")
        expectHarmless(String(repeating: "<script>", count: 5_000))
    }

    /// Markup that never ends is retried from every `<`. Each of these takes
    /// time quadratic in its length unless the tokenizer remembers what it
    /// has already found to fail; at this size that is minutes, not
    /// milliseconds.
    @Test(.timeLimit(.minutes(1))) func unterminatedMarkupIsNotRereadFromEveryStart() {
        let count = 60_000
        // Every tag fails whichever quote it is in when it reaches the tail.
        let quotes = String(repeating: "<a b=\"x\" c='", count: count) + "'\" x='\">\""
        #expect(sanitize(quotes).hasPrefix("&lt;a b=\"x\" c='&lt;a"))
        let names = String(repeating: "<a", count: count) + " x='>"
        #expect(sanitize(names).hasPrefix("&lt;a&lt;a"))
        let values = "<a " + String(repeating: "b=<a ", count: count) + "'"
        #expect(sanitize(values).hasPrefix("&lt;a b=&lt;a"))
        let comments = String(repeating: "<!--x", count: count) + ">"
        #expect(sanitize(comments).hasPrefix("&lt;!--x&lt;!--x"))
        let sections = String(repeating: "<![CDATA[", count: count) + "]]"
        #expect(sanitize(sections).hasPrefix("&lt;![CDATA[&lt;!"))
        let declarations = String(repeating: "<?x", count: count)
        #expect(sanitize(declarations).hasPrefix("&lt;?x&lt;?x"))
        // A deep stack and as many end tags that match nothing in it.
        let stray = String(repeating: "<div>", count: count) + String(repeating: "</span>", count: count)
        #expect(sanitize(stray).hasSuffix("</div></div>"))
        for input in [quotes, names, comments, stray] {
            let once = sanitize(input)
            #expect(sanitize(once) == once)
        }
    }

    /// Random markup, heavy on the characters that change the tokenizer's
    /// state. Remembering failed tags must not change any output, and every
    /// output must be harmless.
    @Test func randomMarkupIsHarmlessAndUnaffectedByRememberingFailures() {
        let pieces = [
            "<", "<", ">", ">", "a", "b", " ", " ", "\"", "'", "=", "/", "`", "\n", "!", "?", "-", "x", "&", ";",
            "<a ", "<b", "</b>", "</", "href", "title", "onclick", "id", "#", ":", "javascript:", "http://e.com",
            "<!--", "-->", "--!>", "<![CDATA[", "]]>", "<!", "<?", "<script>", "</script>", "<script", "<svg>",
            "</svg>", "<svg/>", "<title>", "</title>", "<img src=", "<input type=checkbox disabled", "<ol><li id=fn-1>", "<table>", "<td>",
            "<p>", "<div>", "</div>", "<br/>", "&#58;", "&colon;", "\0", "<a href=\"#", "<b id=\"", "\">", "%27", "%26", "amp;",
            "user-content-", "fn-1",
        ]
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next(_ bound: Int) -> Int {
            // A fixed sequence (SplitMix64), so a failure can be reproduced.
            seed &+= 0x9E37_79B9_7F4A_7C15
            var z = seed
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Int((z ^ (z >> 31)) % UInt64(bound))
        }
        for _ in 0..<20_000 {
            var input = ""
            for _ in 0...next(40) { input += pieces[next(pieces.count)] }
            let output = sanitize(input)
            #expect(output == HTMLSanitizer.sanitize(input, rememberingFailures: false), "input: \(input.debugDescription)")
            expectHarmless(input)
        }
    }

    /// Every prefix of every vector: a document can end anywhere.
    @Test func everyTruncationIsHarmless() {
        for input in Self.corpus {
            let scalars = Array(input.unicodeScalars)
            for length in 0...scalars.count {
                var prefix = String.UnicodeScalarView()
                prefix.append(contentsOf: scalars[..<length])
                expectHarmless(String(prefix))
            }
        }
    }
}
